defmodule Surfex.Evidence do
  @moduledoc """
  Test evidence: what a test run showed, one line per test, recorded by
  `Surfex.ExUnitFormatter` and read here.

  Each record is JSON: the test's id and version (`Surfex.Scan.ExUnit`), whether it passed,
  when, which run, and the versions of the code the test calls at that moment. Evidence is
  **scratch data**: it lives under `_build` and is never committed. What it justifies is
  recorded in the relation log, with the evidence written into the entry's note; the raw
  runs aren't needed afterwards.

  A test version **discriminates** once it has failed against one version of its code and
  later passed against a different one, the test itself unchanged: it has shown it can
  tell broken code from working code. A test changed in any way (its body, helpers,
  setups or cases) is a new version, and must fail and pass again.
  """

  @type t :: %{
          test: String.t(),
          test_hash: String.t(),
          result: :passed | :failed | :excluded | :skipped,
          at: String.t(),
          run: String.t(),
          seq: non_neg_integer,
          code: %{String.t() => String.t()}
        }

  @note "confirmed by evidence"

  # The project's evidence checkpoint in `.surfex/cache/` (`project/1`).
  @checkpoint "evidence.checkpoint"

  # Bytes per read of the evidence file.
  @piece 64 * 1024 * 1024

  @doc """
  Whether a log entry is a claim a test run bears out, the claim CI checks against its own
  run (§17). That is decided by its basis: `:evidence` (red then green) or `:baseline` (a
  trusted test version, §18.1), whatever its note says, so a move, which keeps the basis and
  replaces the note, keeps it checked. Only an entry written before bases existed is
  recognised by its note, which begins `confirmed by evidence`.
  """
  @spec claimed?(Surfex.Log.Entry.t()) :: boolean
  def claimed?(%{basis: basis}) when basis in [:evidence, :baseline], do: true

  def claimed?(%{basis: nil, note: note}),
    do: is_binary(note) and String.starts_with?(note, @note)

  def claimed?(%{basis: _validated_otherwise}), do: false
  def claimed?(%{note: note}), do: is_binary(note) and String.starts_with?(note, @note)

  @doc "How a confirmation by evidence's note begins."
  @spec note() :: String.t()
  def note, do: @note

  @doc "Where a project's evidence lives: `_build/surfex/evidence.jsonl` under `root`."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join([root, "_build", "surfex", "evidence.jsonl"])

  @doc """
  Several runs' evidence as one history, ordered by time (§17): the local run and other
  runs' files, such as CI jobs' artifacts. A test excluded in one run and run in another
  reads as run; whichever run is latest is the latest, wherever it was recorded.
  """
  @spec combined([[t]]) :: [t]
  def combined(runs), do: runs |> Enum.concat() |> Enum.sort_by(&{&1.at, &1.run, &1.seq})

  @doc "Appends records to the evidence file at `path`, creating it."
  @spec append(String.t(), [t]) :: :ok
  def append(path, records) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(records, &[encode(&1), "\n"]), [:append])
  end

  @doc """
  Every record in the evidence file at `path`, oldest first; `[]` when there is none.

  The lines are decoded on every core, and records that hold equal values (a test's id
  and version, a run, a set of code versions) hold one copy of each (§17, #399).
  """
  @spec load(String.t()) :: [t]
  def load(path) do
    if File.exists?(path) do
      {values, numbered} =
        path |> Surfex.Files.read!() |> String.split("\n", trim: true) |> numbered(%{})

      records(values, sorted(numbered, values))
    else
      []
    end
  end

  @doc """
  The project's own evidence (`path/1` under `root`): what `load/1` gives, read through a
  checkpoint in `.surfex/cache/` (§17, #400).

  The file only grows between runs, so the checkpoint keeps the records decoded from the
  bytes it covered, and a read decodes just the lines after them. A file that no longer
  starts with those bytes is decoded in full. The checkpoint is rewritten once the lines it
  doesn't cover pass an eighth of those it does, as the log's is (§12.2).
  """
  @spec project(String.t()) :: [t]
  def project(root) do
    path = path(root)

    if File.exists?(path) do
      {:ok, fd} = :file.open(path, [:read, :raw, :binary])
      # The covered bytes are hashed as they're read and never held: only what follows is.
      {covered, values, known, digest} = checkpointed(root, fd)
      rest = read_all(fd, [])
      :ok = :file.close(fd)

      {values, appended} = rest |> String.split("\n", trim: true) |> numbered(values)
      numbered = merge(known, sorted(appended, values), values)

      if byte_size(rest) * 8 > covered and String.ends_with?(rest, "\n") do
        # A digest state goes on being updated after it's read (`:crypto.hash_final/1`
        # leaves it as it was), so the new checkpoint's covers the whole file.
        sum = digest |> :crypto.hash_update(rest) |> :crypto.hash_final()
        made = {covered + byte_size(rest), sum, values, numbered}
        Surfex.Cache.write(root, @checkpoint, checkpoint_fingerprint(), made)
      end

      records(values, numbered)
    else
      []
    end
  end

  # {bytes covered, their values, their numbered records in order, the digest of those
  # bytes so far}, with `fd` just after them; or, with `fd` at the start, nothing covered,
  # when there is no checkpoint, it's from other code, or the file no longer starts with the
  # bytes it covered.
  defp checkpointed(root, fd) do
    with {:ok, {size, sum, values, numbered}} <-
           Surfex.Cache.read(root, @checkpoint, checkpoint_fingerprint()),
         {:ok, digest} <- digest(fd, size, :crypto.hash_init(:sha256)),
         true <- :crypto.hash_final(digest) == sum do
      {size, values, numbered, digest}
    else
      _ ->
        {:ok, 0} = :file.position(fd, 0)
        {0, %{}, [], :crypto.hash_init(:sha256)}
    end
  end

  # The digest of the next `size` bytes of `fd`, read a piece at a time; :short when the
  # file ends first.
  defp digest(_fd, 0, digest), do: {:ok, digest}

  defp digest(fd, size, digest) do
    case :file.read(fd, min(size, @piece)) do
      {:ok, bytes} -> digest(fd, size - byte_size(bytes), :crypto.hash_update(digest, bytes))
      :eof -> :short
    end
  end

  defp checkpoint_fingerprint, do: Surfex.Cache.fingerprint([__MODULE__])

  # Numbered records in the order `load/1` gives: by time, then run, then place in the run,
  # and in file order where those are equal (a stable sort).
  defp sorted(numbered, values), do: Enum.sort_by(numbered, &order(&1, values))

  defp order({_test, _test_hash, _result, at, run, seq, _code}, values),
    do: {at, Map.fetch!(values, run), seq}

  # Two sorted lists as one, as sorting their concatenation would order it: the checkpoint's
  # records came earlier in the file, so they go first among equals.
  defp merge([], appended, _values), do: appended
  defp merge(known, [], _values), do: known

  defp merge(known, [first | _] = appended, values) do
    # Usually a run is recorded after every run before it, and so follows them all.
    if order(first, values) >= order(List.last(known), values),
      do: known ++ appended,
      else: merge(known, appended, values, [])
  end

  defp merge(known, [], _values, acc), do: Enum.reverse(acc, known)
  defp merge([], appended, _values, acc), do: Enum.reverse(acc, appended)

  defp merge([a | as] = known, [b | bs] = appended, values, acc) do
    if order(b, values) < order(a, values),
      do: merge(known, bs, values, [b | acc]),
      else: merge(as, appended, values, [a | acc])
  end

  defp read_all(fd, acc) do
    case :file.read(fd, @piece) do
      {:ok, bytes} -> read_all(fd, [acc | bytes])
      :eof -> IO.iodata_to_binary(acc)
    end
  end

  # Lines per piece of work.
  @chunk 1000

  # The records of `lines` in file order, numbered: `{values, records}`, each record a tuple
  # whose repeated values (test, version, run, code map) are numbers into `values`, which
  # holds those already numbered plus the new ones.
  #
  # A long-lived file repeats a few values across its runs: apu's 911k records hold 18k
  # distinct code maps and 6k test versions. Sharing doesn't survive a message, and the
  # repeats are across runs, not within a piece of the file, so the pieces number each
  # distinct value in one table they share and return only the numbers. `records/2` then
  # gives every record the one copy of each value.
  defp numbered([], values), do: {values, []}

  defp numbered(lines, values) do
    table =
      :ets.new(:surfex_evidence_values, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(table, Enum.map(values, fn {n, value} -> {value, n} end))
    # After the largest number in use: a lost race leaves a number unused, so they have gaps.
    largest = values |> Map.keys() |> Enum.max(fn -> 0 end)
    next = :atomics.new(1, [])
    :atomics.put(next, 1, largest)

    pieces =
      lines
      |> Enum.chunk_every(@chunk)
      |> Surfex.Parallel.map(&decode_piece(&1, table, next))

    # Only the values numbered here are copied out; those given are kept as they are.
    new = :ets.select(table, [{{:"$1", :"$2"}, [{:>, :"$2", largest}], [{{:"$2", :"$1"}}]}])
    values = Map.merge(values, Map.new(new))
    :ets.delete(table)

    # A piece reports its first line that isn't a record rather than raising in its task,
    # so the error reads as it did when the file was decoded line by line.
    case Enum.find(pieces, &match?({:error, _}, &1)) do
      {:error, why} -> raise ArgumentError, why
      nil -> {values, Enum.flat_map(pieces, fn {:ok, piece} -> piece end)}
    end
  end

  # Each numbered record with its values: equal values are one term in every record.
  defp records(values, numbered) do
    for {test, test_hash, result, at, run, seq, code} <- numbered do
      %{
        test: Map.fetch!(values, test),
        test_hash: Map.fetch!(values, test_hash),
        result: result,
        at: at,
        run: Map.fetch!(values, run),
        seq: seq,
        code: Map.fetch!(values, code)
      }
    end
  end

  # One piece's records, each repeated value as its number in `table`, or the first line's
  # error. `at` is copied off the file's bytes, so no record keeps the whole file alive.
  defp decode_piece(lines, table, next) do
    number = &number(table, next, &1)

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case decode(line) do
        {:ok, r} ->
          record =
            {number.(r.test), number.(r.test_hash), r.result, :binary.copy(r.at), number.(r.run),
             r.seq, number.(r.code)}

          {:cont, {:ok, [record | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  # The value's number in `table`, numbering it from `next` if it has none; when two pieces
  # number the same value at once, the first insert stands and both read it (the other
  # number goes unused). A value is copied off the file's bytes as it goes in, which an ETS
  # table would otherwise keep alive.
  defp number(table, next, value) do
    case :ets.lookup_element(table, value, 2, nil) do
      nil ->
        :ets.insert_new(table, {copy(value), :atomics.add_get(next, 1, 1)})
        :ets.lookup_element(table, value, 2)

      n ->
        n
    end
  end

  defp copy(value) when is_binary(value), do: :binary.copy(value)
  defp copy(value) when is_map(value), do: Map.new(value, fn {k, v} -> {copy(k), copy(v)} end)
  defp copy(value), do: value

  @doc """
  Whether `test_hash`, a version of test `test`, has discriminated: a failure against one
  set of code versions, then a later pass against a different set, with no change to the
  test in between (the records are for that one version).
  """
  @spec discriminating?([t], String.t(), String.t()) :: boolean
  def discriminating?(evidence, test, test_hash),
    do: red_then_green(evidence, test, test_hash) != nil

  @doc """
  The red run and the green run that make `test_hash` discriminate (`discriminating?/3`):
  the first failure, and the first later pass against different code. `nil` when there
  are none.
  """
  @spec red_then_green([t], String.t(), String.t()) :: {t, t} | nil
  def red_then_green(evidence, test, test_hash) do
    runs = for r <- ran(evidence), r.test == test, r.test_hash == test_hash, do: r
    red_green(runs, &(&1 != &2))
  end

  @doc """
  The test versions whose red→green the evidence can't credit (#194): each failed and
  later passed, unchanged itself, against the **same** code versions, and never
  discriminated (`red_then_green/3`). Whatever made it pass is outside the code the test
  reaches: a call the scanner doesn't see, a change outside the scanned code, or a flaky
  test. Keyed by `{test, test_hash}`, with the first such red run and the pass after it.
  """
  @spec uncredited([t]) :: %{{String.t(), String.t()} => {t, t}}
  def uncredited(evidence) do
    for {key, runs} <- Enum.group_by(ran(evidence), &{&1.test, &1.test_hash}),
        red_green(runs, &(&1 != &2)) == nil,
        pair = red_green(runs, &(&1 == &2)),
        pair != nil,
        into: %{},
        do: {key, pair}
  end

  # The first failure among one test version's `runs` and the first later pass whose code
  # versions `compare` to the failure's as asked: differing for a red→green that
  # discriminates, the same for one that can't be credited.
  defp red_green(runs, compare) do
    Enum.find_value(runs, fn
      %{result: :failed} = red ->
        runs
        |> Enum.drop_while(&(&1 != red))
        |> Enum.find(&(&1.result == :passed and compare.(&1.code, red.code)))
        |> case do
          nil -> nil
          green -> {red, green}
        end

      _passed ->
        nil
    end)
  end

  @doc """
  The most recent record of test `test` at version `test_hash` that ran (passed or
  failed), or `nil`. An excluded or skipped record is neither red nor green.
  """
  @spec latest([t], String.t(), String.t()) :: t | nil
  def latest(evidence, test, test_hash) do
    evidence
    |> ran()
    |> Enum.filter(&(&1.test == test and &1.test_hash == test_hash))
    |> List.last()
  end

  defp ran(evidence), do: Enum.filter(evidence, &(&1.result in [:passed, :failed]))

  # ── Lines ───────────────────────────────────────────────────────────────

  defp encode(r) do
    %{
      "test" => r.test,
      "test_hash" => r.test_hash,
      "result" => Atom.to_string(r.result),
      "at" => r.at,
      "run" => r.run,
      "seq" => r.seq,
      "code" => r.code
    }
    |> Surfex.JSON.encode()
  end

  @fields ["test", "test_hash", "at", "run", "seq", "code"]
  @results %{
    "passed" => :passed,
    "failed" => :failed,
    "excluded" => :excluded,
    "skipped" => :skipped
  }

  # A line's record, or why it isn't one. A line that isn't JSON raises, as a log line does.
  defp decode(line) do
    case Surfex.Log.Entry.json(line) do
      %{} = map -> record(map, line)
      _ -> {:error, "not an evidence record: #{String.slice(line, 0, 80)}"}
    end
  end

  defp record(map, line) do
    case {Enum.reject(@fields, &Map.has_key?(map, &1)), Map.fetch(@results, map["result"])} do
      {[], {:ok, result}} ->
        {:ok,
         %{
           test: map["test"],
           test_hash: map["test_hash"],
           result: result,
           at: map["at"],
           run: map["run"],
           seq: map["seq"],
           code: map["code"]
         }}

      {[], :error} ->
        {:error,
         "evidence result must be passed, failed, excluded or skipped, got #{inspect(map["result"])}"}

      {missing, _} ->
        {:error,
         "evidence record has no #{Enum.join(missing, ", ")}: #{String.slice(line, 0, 80)}"}
    end
  end
end
