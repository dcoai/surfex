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
  """

  alias Surfex.Log.Entry

  @dir ".surfex"
  @open "surfex.log"
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
    root
    |> segments()
    |> Enum.flat_map(fn {_n, path} -> path |> entry_lines() |> Enum.map(&Entry.decode!/1) end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.at, &1.id})
  end

  @doc """
  Everything wrong with the log, one message each, or `[]`:

    * a line that is not a valid entry, or whose id does not match its content (an edit)
    * a parent that no entry has (a removed line)
    * a segment whose header does not match the segment before it (truncation, or two
      branches that both started a segment: `rechain/1` fixes the latter)
  """
  @spec verify(String.t()) :: [String.t()]
  def verify(root) do
    segments = segments(root)

    {entries, broken} =
      segments
      |> Enum.flat_map(fn {_n, path} -> Enum.map(entry_lines(path), &{path, &1}) end)
      |> Enum.reduce({[], []}, fn {path, line}, {ok, bad} ->
        case Entry.decode(line) do
          {:ok, entry} -> {[entry | ok], bad}
          {:error, why} -> {ok, ["#{Path.basename(path)}: #{why}" | bad]}
        end
      end)

    ids = MapSet.new(entries, & &1.id)

    orphans =
      for e <- entries,
          p <- e.parents,
          not MapSet.member?(ids, p),
          uniq: true,
          do:
            "entry #{short(e.id)} names parent #{short(p)}, which no segment has (a removed line?)"

    Enum.reverse(broken) ++ orphans ++ chain_problems(segments)
  end

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

  defp chain_hash(path) do
    path
    |> entry_lines()
    |> Enum.map(fn line -> line |> Entry.json() |> Map.fetch!("id") end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp chain_problems(segments) do
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

      {problems ++ problem, chain_hash(path)}
    end)
    |> elem(0)
  end

  defp short(id), do: String.slice(id, 0, 12)
end
