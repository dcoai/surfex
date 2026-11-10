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
      path
      |> read()
      |> String.split("\n", trim: true)
      |> decode_shared()
      |> Enum.sort_by(&{&1.at, &1.run, &1.seq})
    else
      []
    end
  end

  # The file's bytes, read without the file server: `File.read!/1` passes them through it,
  # and an idle file server holds the last binary it read, the whole file, until it next
  # collects garbage, which may be never.
  defp read(path) do
    {:ok, fd} = :file.open(path, [:read, :raw, :binary])
    bytes = read_all(fd, [])
    :ok = :file.close(fd)
    bytes
  end

  defp read_all(fd, acc) do
    case :file.read(fd, 64 * 1024 * 1024) do
      {:ok, bytes} -> read_all(fd, [acc | bytes])
      :eof -> IO.iodata_to_binary(acc)
    end
  end

  # Lines per piece of work.
  @chunk 1000

  # The records of `lines`, in order. A long-lived file repeats a few values across its runs:
  # apu's 911k records hold 18k distinct code maps and 6k test versions. Sharing doesn't
  # survive a message, and the repeats are across runs, not within a piece of the file, so
  # the pieces number each distinct value in one table they share and return only the
  # numbers; each value is then copied out of the table once, and every record holds that
  # one copy.
  defp decode_shared(lines) do
    table =
      :ets.new(:surfex_evidence_values, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    pieces =
      lines
      |> Enum.chunk_every(@chunk)
      |> Surfex.Parallel.map(&decode_piece(&1, table))

    values = :ets.foldl(fn {value, n}, acc -> Map.put(acc, n, value) end, %{}, table)
    :ets.delete(table)

    # A piece reports its first line that isn't a record rather than raising in its task,
    # so the error reads as it did when the file was decoded line by line.
    case Enum.find(pieces, &match?({:error, _}, &1)) do
      {:error, why} -> raise ArgumentError, why
      nil -> :ok
    end

    for {:ok, piece} <- pieces, {test, test_hash, result, at, run, seq, code} <- piece do
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
  defp decode_piece(lines, table) do
    number = &number(table, &1)

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

  # The value's number in `table`, numbering it if it has none; when two pieces number the
  # same value at once, the first insert stands and both read it. A value is copied off the
  # file's bytes as it goes in, which an ETS table would otherwise keep alive.
  defp number(table, value) do
    case :ets.lookup_element(table, value, 2, nil) do
      nil ->
        :ets.insert_new(table, {copy(value), :erlang.unique_integer()})
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
