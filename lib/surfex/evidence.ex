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

  @doc "Every record in the evidence file at `path`, oldest first; `[]` when there is none."
  @spec load(String.t()) :: [t]
  def load(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&decode/1)
      |> Enum.sort_by(&{&1.at, &1.run, &1.seq})
    else
      []
    end
  end

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

    Enum.find_value(runs, fn
      %{result: :failed} = red ->
        runs
        |> Enum.drop_while(&(&1 != red))
        |> Enum.find(&(&1.result == :passed and &1.code != red.code))
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
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp decode(line) do
    map = Surfex.Log.Entry.json(line)

    result =
      case map["result"] do
        "passed" ->
          :passed

        "failed" ->
          :failed

        "excluded" ->
          :excluded

        "skipped" ->
          :skipped

        other ->
          raise ArgumentError,
                "evidence result must be passed, failed, excluded or skipped, got #{inspect(other)}"
      end

    %{
      test: Map.fetch!(map, "test"),
      test_hash: Map.fetch!(map, "test_hash"),
      result: result,
      at: Map.fetch!(map, "at"),
      run: Map.fetch!(map, "run"),
      seq: Map.fetch!(map, "seq"),
      code: Map.fetch!(map, "code")
    }
  end
end
