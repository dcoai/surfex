defmodule Surfex.Log do
  @moduledoc """
  The relation log: every judgement ever recorded about how the spec and the code relate,
  append-only, in `.surfex/`.

  **Nothing is ever edited or removed.** Entries are the record of how things came to
  relate, so any question about history is answered from the log alone, without walking
  back through git.

  ## Files

    * `surfex.log` — the open segment, where entries are appended
    * `surfex_1.log`, `surfex_2.log`, … — closed segments, made by `break/1`

  Every file starts with a header line, `{"segment": N, "previous": HASH}`, where `HASH` is
  the SHA-256 of the previous segment's sorted entry ids (`null` for the first). The chain
  catches a segment that was truncated or replaced. Headers are not judgements, so
  `rechain/1` may rewrite them. It is needed only when two branches both started a segment
  and a merge combined them.

  `init/1` adds `.surfex/*.log merge=union` to `.gitattributes`, so git merges concurrent
  appends by keeping both sides' lines. That is always right here: loading drops
  duplicates and orders entries by time, whatever order the lines arrive in.

  ## Checkpoints

  `load/1` keeps a checkpoint of each segment's decoded entries in `.surfex/cache/`, which
  git ignores, keyed on the segment's exact bytes. A segment that still starts with those
  bytes has only its later lines decoded. Any other change to it is decoded in full.
  `verify/1` and `check/1` never use a checkpoint: they always read every line.
  """

  alias Surfex.Log.Entry

  @dir ".surfex"
  @open "surfex.log"
  @checkpoint "log.checkpoint"
  @attributes "#{@dir}/*.log merge=union"

  @doc "The log directory under a project root."
  @spec dir(String.t()) :: String.t()
  def dir(root), do: Path.join(root, @dir)

  @doc """
  Creates the log under `root`, if absent: the directory, an empty open segment, and the
  union merge in `.gitattributes`. Idempotent.
  """
  @spec init(String.t()) :: :ok
  def init(root) do
    dir = dir(root)
    File.mkdir_p!(dir)
    open = Path.join(dir, @open)
    unless File.exists?(open), do: File.write!(open, header(1, nil) <> "\n")

    attributes = Path.join(root, ".gitattributes")
    existing = if File.exists?(attributes), do: File.read!(attributes), else: ""

    unless String.contains?(existing, @attributes) do
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(attributes, existing <> separator <> @attributes <> "\n")
    end

    :ok
  end

  @doc "Appends entries to the open segment. The log must exist (`init/1`)."
  @spec append(String.t(), [Entry.t()]) :: :ok
  def append(root, entries) do
    open = Path.join(dir(root), @open)

    unless File.exists?(open),
      do: raise(ArgumentError, "no relation log at #{dir(root)}: run `mix surfex.log --init`")

    File.write!(open, Enum.map(entries, &[Entry.encode(&1), "\n"]), [:append])
    :ok
  end

  @doc """
  Every entry in every segment: duplicates (the same id) dropped, ordered by `at` and
  then `id`, so every checkout derives the same order. Raises on a line that is not a
  valid entry, including one whose id no longer matches its content.
  """
  @spec load(String.t()) :: [Entry.t()]
  def load(root) do
    files = root |> segments() |> Enum.map(fn {_n, path} -> {path, File.read!(path)} end)

    # What the checkpoint (spec §12.2) covers was decoded by an earlier load from these
    # same bytes; only the lines after it are decoded.
    {covered, known} = checkpointed(root, files)

    decoded =
      files
      |> Enum.zip(covered)
      |> Enum.flat_map(fn {{_path, content}, from} ->
        content
        |> binary_part(from, byte_size(content) - from)
        |> String.split("\n", trim: true)
        |> Enum.reject(&header?/1)
      end)
      # Decoded in parallel without raising; the first bad line raises here, as decode! would.
      |> Surfex.Parallel.chunked(500, &Entry.decode/1)
      |> Enum.map(fn
        {:ok, entry} -> entry
        {:error, why} -> raise ArgumentError, why
      end)

    tail = decoded |> Enum.uniq_by(& &1.id) |> Enum.sort_by(&{&1.at, &1.id})
    entries = merge(known || [], tail)

    # Rewriting the checkpoint costs about what decoding the whole log does, so a run after
    # a small append decodes the few lines after it rather than rewriting it. It's rewritten
    # once the lines it doesn't cover pass an eighth of those it does.
    total = files |> Enum.map(fn {_, content} -> byte_size(content) end) |> Enum.sum()
    uncovered = total - Enum.sum(covered)

    if (known == nil or uncovered * 8 > total - uncovered) and
         Enum.all?(files, fn {_, content} -> String.ends_with?(content, "\n") end),
       do: checkpoint(root, files, entries)

    entries
  end

  # Two lists in load order merged into one, an entry in both kept once: entries with the
  # same id have the same `at`, so they meet side by side.
  defp merge(known, []), do: known
  defp merge([], tail), do: tail

  defp merge([a | as] = known, [b | bs] = tail) do
    case {{a.at, a.id}, {b.at, b.id}} do
      {same, same} -> [a | merge(as, bs)]
      {ka, kb} when ka < kb -> [a | merge(as, tail)]
      _ -> [b | merge(known, bs)]
    end
  end

  # {bytes covered in each file, the loaded entries of those bytes}. The checkpoint
  # applies when every segment it was made from still starts with exactly the bytes it
  # covered, in the same order, with new segments only after them; otherwise it covers
  # nothing ({zeros, nil}) and every line is decoded.
  defp checkpointed(root, files) do
    none = {Enum.map(files, fn _ -> 0 end), nil}

    with {:ok, {made, entries}} <- Surfex.Cache.read(root, @checkpoint, checkpoint_fingerprint()),
         true <- length(made) <= length(files),
         covered = covered(made, files),
         true <- Enum.all?(covered) do
      {covered ++ List.duplicate(0, length(files) - length(made)), entries}
    else
      _ -> none
    end
  end

  # For each segment the checkpoint was made from, the bytes it covers in the file now, or
  # false when the file no longer starts with them.
  defp covered(made, files) do
    made
    |> Enum.zip(files)
    |> Enum.map(fn {{name, size, sum}, {path, content}} ->
      name == Path.basename(path) and size <= byte_size(content) and
        :crypto.hash(:sha256, binary_part(content, 0, size)) == sum and size
    end)
  end

  defp checkpoint(root, files, entries) do
    made =
      Enum.map(files, fn {path, content} ->
        {Path.basename(path), byte_size(content), :crypto.hash(:sha256, content)}
      end)

    Surfex.Cache.write(root, @checkpoint, checkpoint_fingerprint(), {made, entries})
  end

  defp checkpoint_fingerprint, do: Surfex.Cache.fingerprint([Entry, __MODULE__])

  @doc """
  Everything wrong with the log, one message each, or `[]`:

    * a line that is not a valid entry, or whose id does not match its content (an edit)
    * a parent that no entry has (a removed line)
    * a segment whose header does not match the segment before it (truncation, or two
      branches that both started a segment: `rechain/1` fixes the latter)
  """
  @spec verify(String.t()) :: [String.t()]
  def verify(root), do: root |> check() |> elem(1)

  @doc """
  `verify/1`'s problems and `load/1`'s entries from one reading of the log, for a caller
  that needs both: decoding every line twice was most of `mix surfex.status --verify`'s
  extra time. The entries are those that decode, as `load/1` orders them.
  """
  @spec check(String.t()) :: {[Entry.t()], [String.t()]}
  def check(root) do
    segments = segments(root)

    # Each segment's ids come from this one decode, for its chain hash (#386): reading them
    # again from the file decoded every line twice. A line that doesn't decode still chains
    # by the id it carries, as `chain_hash/1` reads it.
    {entries, broken, ids_by_path} =
      segments
      |> Enum.flat_map(fn {_n, path} -> Enum.map(numbered_lines(path), &{path, &1}) end)
      |> Surfex.Parallel.chunked(500, fn {path, {line, n}} ->
        case Entry.decode(line) do
          {:ok, entry} -> {path, n, {:ok, entry}}
          {:error, why} -> {path, n, {:error, why, line}}
        end
      end)
      |> Enum.reduce({[], [], %{}}, fn
        {path, _n, {:ok, entry}}, {ok, bad, ids} ->
          {[entry | ok], bad, add_ids(ids, path, [entry.id])}

        {path, n, {:error, why, line}}, {ok, bad, ids} ->
          {ok, ["#{Path.basename(path)}:#{n}: #{why}" | bad], add_ids(ids, path, stored_id(line))}
      end)

    ids = MapSet.new(entries, & &1.id)

    orphans =
      for e <- entries,
          p <- e.parents,
          not MapSet.member?(ids, p),
          uniq: true,
          do:
            "entry #{short(e.id)} names parent #{short(p)}, which no segment has (a removed line?)"

    loaded = entries |> Enum.uniq_by(& &1.id) |> Enum.sort_by(&{&1.at, &1.id})
    {loaded, Enum.reverse(broken) ++ orphans ++ chain_problems(segments, ids_by_path)}
  end

  defp add_ids(ids, path, new), do: Map.update(ids, path, new, &(new ++ &1))

  @doc "Closes the open segment as the next `surfex_N.log` and starts a new open segment."
  @spec break(String.t()) :: :ok
  def break(root) do
    dir = dir(root)
    closed = segments(root) |> Enum.count(fn {n, _} -> n != :open end)
    target = Path.join(dir, "surfex_#{closed + 1}.log")
    File.rename!(Path.join(dir, @open), target)
    File.write!(Path.join(dir, @open), header(closed + 2, chain_hash(target)) <> "\n")
    :ok
  end

  @doc """
  Rewrites every segment's header to match the segments as they now are. Entries are not
  touched. For after a merge has combined two branches' segments.
  """
  @spec rechain(String.t()) :: :ok
  def rechain(root) do
    root
    |> segments()
    |> Enum.with_index(1)
    |> Enum.reduce(nil, fn {{_n, path}, number}, previous ->
      File.write!(path, [header(number, previous), "\n", Enum.map(entry_lines(path), &[&1, "\n"])])

      chain_hash(path)
    end)

    :ok
  end

  # ── Segments ────────────────────────────────────────────────────────────

  # Closed segments in number order, then the open one.
  defp segments(root) do
    dir = dir(root)

    closed =
      dir
      |> Path.join("surfex_*.log")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case Regex.run(~r/surfex_(\d+)\.log$/, path, capture: :all_but_first) do
          [n] -> [{String.to_integer(n), path}]
          _ -> []
        end
      end)
      |> Enum.sort()

    open = Path.join(dir, @open)
    if File.exists?(open), do: closed ++ [{:open, open}], else: closed
  end

  # Each entry line with its line number in the file, for reporting where a problem is.
  defp numbered_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> line == "" or header?(line) end)
  end

  defp entry_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&header?/1)
  end

  defp header(n, previous),
    do:
      IO.iodata_to_binary([
        ~s({"segment":),
        Integer.to_string(n),
        ~s(,"previous":),
        if(previous, do: :json.encode(previous), else: "null"),
        "}"
      ])

  defp header?(line), do: String.starts_with?(line, ~s({"segment":))

  defp header_of(path) do
    case path |> File.read!() |> String.split("\n", parts: 2) do
      [first | _] -> if header?(first), do: Entry.json(first), else: nil
      _ -> nil
    end
  end

  defp chain_hash(path),
    do: path |> entry_lines() |> Enum.flat_map(&stored_id/1) |> chain_hash_of()

  # A segment's chain hash: its entries' ids, sorted, so line order within it doesn't matter.
  defp chain_hash_of(ids) do
    ids
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The id a line carries, as a list: an entry's, edited or not. A line that is JSON but no
  # entry has none, so it adds nothing to its segment's hash (#387); `check/1` reports it.
  # Text that isn't JSON raises, as `Entry.json/1` does.
  defp stored_id(line) do
    case Entry.json(line) do
      %{"id" => id} when is_binary(id) -> [id]
      _ -> []
    end
  end

  defp chain_problems(segments, ids_by_path) do
    segments
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn {{_n, path}, number}, {problems, previous} ->
      expected = %{"segment" => number, "previous" => previous}

      problem =
        case header_of(path) do
          ^expected ->
            []

          nil ->
            ["#{Path.basename(path)} has no segment header"]

          other ->
            [
              "#{Path.basename(path)}'s header #{inspect(other)} does not match the segments before it (truncated, or combined by a merge: `mix surfex.log --rechain`)"
            ]
        end

      {problems ++ problem, chain_hash_of(Map.get(ids_by_path, path, []))}
    end)
    |> elem(0)
  end

  defp short(id), do: String.slice(id, 0, 12)
end
