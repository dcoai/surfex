defmodule Surfex.ExUnitFormatter do
  @moduledoc """
  An ExUnit formatter that records test evidence (`Surfex.Evidence`): for each test that
  ran, whether it passed, at its exact version, with the versions of the code it calls.

  Add it beside the usual formatter, in `test/test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])

  At the start of the suite it scans the project as `mix surfex.status` does: the tests
  `tests:` names in `.surfex.exs`, and the code. A finished test is matched to its scanned
  record by file and line, so a test a comprehension generates counts for the record that
  defines it. When a record's test ran more than once in a run (one per case), it failed
  if any case failed. Skipped and excluded tests, and tests outside `tests:`, record
  nothing. When the suite finishes, the run's records are appended to
  `Surfex.Evidence.path/1` under `_build`: scratch data, never committed.

  It never touches the relation log. Evidence justifies confirmations only when someone
  asks for them (`mix surfex.confirm --evidence`).
  """

  use GenServer

  alias Surfex.{Evidence, Scan}
  alias Surfex.Status.Config

  @impl GenServer
  def init(opts) do
    root = Keyword.get(opts, :surfex_root, File.cwd!())

    {:ok,
     %{
       root: root,
       path: Keyword.get(opts, :surfex_evidence, Evidence.path(root)),
       index: nil,
       code: %{},
       finished: []
     }}
  end

  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    config = Config.read!(Path.join(state.root, ".surfex.exs"))

    globs =
      Keyword.get(config, :tests) ||
        raise ArgumentError,
              "Surfex.ExUnitFormatter needs tests: in .surfex.exs, to know the tests"

    tests = Scan.ExUnit.records(state.root, globs)
    code = for s <- Scan.code(Config.items(config, state.root)), into: %{}, do: {s.id, s.hash}
    index = Enum.group_by(tests, &Path.expand(&1.location.file, state.root))
    {:noreply, %{state | index: index, code: code}}
  end

  def handle_cast(
        {:test_finished, %ExUnit.Test{state: result, tags: tags}},
        %{index: index} = state
      )
      when index != nil do
    with {:ok, outcome} <- outcome(result),
         %Scan{} = scan <- find(index, tags) do
      {:noreply, %{state | finished: [{scan, outcome} | state.finished]}}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:suite_finished, _times}, %{index: index} = state) when index != nil do
    Evidence.append(state.path, records(state))
    {:noreply, %{state | finished: []}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # ── Pieces ──────────────────────────────────────────────────────────────

  defp outcome(nil), do: {:ok, :passed}
  defp outcome({:failed, _}), do: {:ok, :failed}
  defp outcome(_skipped_excluded_or_invalid), do: :none

  # The scanned test whose lines hold the line ExUnit tags the test with.
  defp find(index, %{file: file, line: line}) do
    index
    |> Map.get(Path.expand(file), [])
    |> Enum.find(fn %Scan{location: %{lines: {first, last}}} ->
      line >= first and line <= last
    end)
  end

  defp find(_index, _tags), do: nil

  # One record per scanned test: failed if any of its cases failed.
  defp records(state) do
    run = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    state.finished
    |> Enum.group_by(fn {scan, _} -> scan end, fn {_, outcome} -> outcome end)
    |> Enum.sort_by(fn {scan, _} -> scan.id end)
    |> Enum.with_index()
    |> Enum.map(fn {{scan, outcomes}, seq} ->
      %{
        test: scan.id,
        test_hash: scan.hash,
        result: if(:failed in outcomes, do: :failed, else: :passed),
        at: at,
        run: run,
        seq: seq,
        code: for(id <- scan.calls, hash = state.code[id], hash != nil, into: %{}, do: {id, hash})
      }
    end)
  end
end
