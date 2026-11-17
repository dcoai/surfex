defmodule Surfex.ExUnitFormatter do
  @moduledoc """
  An ExUnit formatter that records test evidence (`Surfex.Evidence`): for each test that
  ran, whether it passed, at its exact version, with the versions of the code it reaches:
  what it calls, and what that code calls (`Surfex.Scan.reach/1`).

  Add it beside the usual formatter, in `test/test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])

  At the start of the suite it scans the project as `mix surfex.status` does: the tests
  `tests:` names in `.surfex.exs`, and the code. A finished test is matched to its scanned
  record by file and line, so a test a comprehension generates counts for the record that
  defines it. When a record's test ran more than once in a run (one per case), it failed
  if any case failed. An excluded or skipped test is recorded as such, with no code
  versions, so a run that leaves a test out is told apart from one where it didn't run.
  Each record carries how long the test's cases took, in microseconds (`duration`), and a
  failed one what its first failing case showed (`failure`, `t:Surfex.Evidence.failure/0`).
  Invalid tests, and tests outside `tests:`, record nothing. When the suite finishes, the run's records are appended to
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
       reach: %{},
       seed: nil,
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

    scans = Scan.code(Config.items(config, state.root))

    tests =
      Scan.ExUnit.records(
        state.root,
        globs,
        scans,
        Config.call_scanners(config),
        Config.routes(config, state.root)
      )

    code = for s <- scans, into: %{}, do: {s.id, s.hash}
    index = Enum.group_by(tests, &Path.expand(&1.location.file, state.root))
    seed = ExUnit.configuration()[:seed]

    {:noreply, %{state | index: index, code: code, reach: Scan.reach(tests ++ scans), seed: seed}}
  end

  def handle_cast(
        {:test_finished, %ExUnit.Test{state: result, tags: tags, time: time}},
        %{index: index} = state
      )
      when index != nil do
    with {:ok, outcome} <- outcome(result),
         %Scan{} = scan <- find(index, tags) do
      failure = failure(result, tags, state)
      {:noreply, %{state | finished: [{scan, {outcome, time, failure}} | state.finished]}}
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
  defp outcome({:excluded, _}), do: {:ok, :excluded}
  defp outcome({:skipped, _}), do: {:ok, :skipped}
  defp outcome(_invalid), do: :none

  # The scanned test whose lines hold the line ExUnit tags the test with.
  defp find(index, %{file: file, line: line}) do
    index
    |> Map.get(Path.expand(file), [])
    |> Enum.find(fn %Scan{location: %{lines: {first, last}}} ->
      line >= first and line <= last
    end)
  end

  defp find(_index, _tags), do: nil

  # What a failed case showed: its first failure's kind, message line and place in the test
  # file, with the run's seed and a digest that leaves the message out (§17, #406).
  defp failure({:failed, [{kind, reason, stacktrace} | _]}, tags, state) do
    {kind, exception} = kind(kind, reason)
    location = location(stacktrace, tags, kind, state.root)

    %{
      kind: kind,
      line: first_line(kind, reason),
      location: location,
      seed: state.seed,
      digest:
        :crypto.hash(:sha256, Enum.join([kind, exception, location], "\n"))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    }
  end

  defp failure(_result, _tags, _state), do: nil

  # The failure's kind, and the exception's module where it raised one.
  defp kind(:error, %ExUnit.AssertionError{}), do: {"assertion", "ExUnit.AssertionError"}
  defp kind(:error, %ExUnit.TimeoutError{}), do: {"timeout", "ExUnit.TimeoutError"}
  defp kind(:error, %module{}), do: {"error", inspect(module)}
  defp kind(:error, _erlang_error), do: {"error", ""}
  defp kind(:throw, _value), do: {"throw", ""}
  # An exit of the test process, or of a process linked to it ({:EXIT, pid}).
  defp kind(_exit, _reason), do: {"exit", ""}

  # Where it failed: the deepest frame in the test's own file, as `file:line` relative to the
  # project. A timeout's stack is wherever the test happened to wait, and an exit's is the
  # exit's, so both are placed at the test itself.
  defp location(stacktrace, tags, kind, root) do
    test_file = Path.expand(tags.file)

    frame =
      kind in ["assertion", "error", "throw"] and
        Enum.find_value(stacktrace, fn
          {_m, _f, _a, info} ->
            file = info[:file]
            if file && Path.expand(to_string(file), root) == test_file, do: info[:line]

          _ ->
            nil
        end)

    "#{Path.relative_to(test_file, root)}:#{frame || tags.line}"
  end

  defp first_line(kind, reason) do
    text =
      case {kind, reason} do
        {"assertion", %ExUnit.AssertionError{message: message}} -> message
        {k, %{__exception__: true} = e} when k in ["timeout", "error"] -> Exception.message(e)
        _ -> inspect(reason, limit: 10)
      end

    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  # A test's result over its cases: failed if any failed, passed if any ran; otherwise
  # excluded or skipped, as its cases were.
  defp result(outcomes) do
    cond do
      :failed in outcomes -> :failed
      :passed in outcomes -> :passed
      :excluded in outcomes -> :excluded
      true -> :skipped
    end
  end

  # One record per scanned test: failed if any of its cases failed.
  defp records(state) do
    run = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    state.finished
    |> Enum.group_by(fn {scan, _} -> scan end, fn {_, ran} -> ran end)
    |> Enum.sort_by(fn {scan, _} -> scan.id end)
    |> Enum.with_index()
    |> Enum.map(fn {{scan, cases}, seq} ->
      result = result(for {outcome, _, _} <- cases, do: outcome)
      # The first failing case, in the order the cases finished.
      failure = cases |> Enum.reverse() |> Enum.find_value(fn {_, _, f} -> f end)

      # A test that didn't run was run against no code; one that ran, against everything it
      # reaches.
      code =
        if result in [:passed, :failed],
          do: for(id <- Map.get(state.reach, scan.id, []), into: %{}, do: {id, state.code[id]}),
          else: %{}

      %{
        test: scan.id,
        test_hash: scan.hash,
        result: result,
        at: at,
        run: run,
        seq: seq,
        code: code,
        duration: Enum.sum(for {_, time, _} <- cases, do: time)
      }
      |> then(&if failure, do: Map.put(&1, :failure, failure), else: &1)
    end)
  end
end
