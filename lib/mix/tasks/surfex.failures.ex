defmodule Mix.Tasks.Surfex.Failures do
  @shortdoc "Each test's failure history and what changed at each flip"

  @moduledoc """
  Each test's pass/fail history, from `.surfex/transitions.log` (§17): every run where
  its result flipped, with a **class** saying what differed from the run with the
  opposite result before it, and the judgements recorded on it.

      mix surfex.failures                 # every test that ever failed
      mix surfex.failures "test:MyApp.CartTest: totals"
      mix surfex.failures --json          # the same, for a tool or an agent

  The classes are mechanical, and they're evidence for a judgement, not one:

  - `nondeterministic`: the test and every piece of code it reaches were at the same
    versions on both sides of the flip, shown without rerunning anything. It's a flake,
    or a change no version holds: a file the test reads, the environment, or code the
    scanner doesn't reach.
  - `test changed` / `code changed`: the test's version differed, or the named code's.
  - `recurred`: a failure with the same digest came back after a fail→pass that changed
    the test or its code: a fix that didn't hold.
  - `new`: a first flip with nothing to compare against (the evidence went with a clean
    build); `unknown` the same, after earlier flips.

  A renamed test's history follows it: an id no longer scanned whose last version is
  exactly one scanned test's version is that test's history (§14).

  Record a judgement on a test's latest transition, or the one `--at` names:

      mix surfex.failures --judge "test:MyApp.CartTest: totals" \\
        --note "flake: the cart ETS table was shared; fixed by a table per test"

  A judgement is its own committed line (`.surfex/failure_judgements.log`) and never edits
  a transition. The task is advisory: it never fails on what it finds.
  """

  use Mix.Task

  alias Surfex.{Failures, Transitions}
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @switches [json: :boolean, judge: :string, at: :string]

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, @switches)
    root = File.cwd!()
    transitions = Transitions.load(root)
    renames = Failures.renames(transitions, scanned_tests(root, opts))

    case opts[:judge] do
      nil -> report(root, transitions, renames, ids, opts)
      test -> judge(root, transitions, renames, strip(test), opts)
    end
  end

  defp judge(root, transitions, renames, test, opts) do
    meta = R.meta(root, opts)
    unless meta[:note], do: Mix.raise("--judge needs --note: what was judged")

    case Failures.judge(root, transitions, renames, test, opts[:at], meta) do
      {:ok, j} -> Mix.shell().info("recorded judgement on #{j.test} at #{j.at}: #{j.note}")
      {:error, why} -> Mix.raise(why)
    end
  end

  defp report(root, transitions, renames, ids, opts) do
    wanted = MapSet.new(ids, &(&1 |> strip() |> then(fn id -> Map.get(renames, id, id) end)))

    histories =
      transitions
      |> Failures.histories(Failures.judgements(root), renames)
      |> Enum.filter(&(ids == [] or MapSet.member?(wanted, &1.test)))

    if opts[:json],
      do: Mix.shell().info(Surfex.JSON.encode(%{tests: Enum.map(histories, &json/1)})),
      else: text(histories)
  end

  defp text([]), do: Mix.shell().info("no test has failed: .surfex/transitions.log has no flips")

  defp text(histories) do
    failing = Enum.filter(histories, &(&1.state == :failed))
    Mix.shell().info("Failing now: #{length(failing)} of #{length(histories)} with a history\n")

    for h <- histories do
      renamed = if h.renamed_from == [], do: "", else: " (was #{Enum.join(h.renamed_from, ", ")})"
      Mix.shell().info("#{h.test}#{renamed}: #{h.state}, #{length(h.flips)} flips")

      for f <- h.flips do
        Mix.shell().info("  #{f.at}  #{f.from}→#{f.to}  #{class(f)}#{at_commit(f)}")
        detail(f)

        for j <- f.judgements,
            do: Mix.shell().info("      judged #{j.judged_at}#{by(j)}: #{j.note}")
      end
    end
  end

  defp class(%{class: :code_changed, changed: %{code: code}}),
    do: "code changed: #{Enum.join(Enum.take(code, 5), ", ")}#{more(code)}"

  defp class(%{class: class}), do: class |> Atom.to_string() |> String.replace("_", " ")

  defp more(code) when length(code) > 5, do: " (+#{length(code) - 5})"
  defp more(_code), do: ""

  defp at_commit(%{commit: nil}), do: ""
  defp at_commit(%{commit: commit}), do: "  #{String.slice(commit, 0, 10)}"

  defp detail(%{failure: f}),
    do:
      Mix.shell().info(
        "      #{f.kind} at #{f.location}, seed #{f.seed}, digest #{f.digest}: #{f.line}"
      )

  defp detail(%{to: :passed, failed_runs: n}) when is_integer(n),
    do: Mix.shell().info("      after #{n} failed runs")

  defp detail(_flip), do: :ok

  defp by(%{by: nil}), do: ""
  defp by(%{by: by}), do: " by #{by}"

  defp json(h) do
    %{
      test: h.test,
      state: h.state,
      renamed_from: h.renamed_from,
      flips:
        for f <- h.flips do
          f
          |> Map.update!(:changed, fn
            nil -> nil
            c -> %{test: c.test, code: c.code}
          end)
          |> Map.update!(:judgements, fn js ->
            Enum.map(js, &Map.take(&1, [:by, :judged_at, :note]))
          end)
        end
    }
  end

  defp strip("test:" <> id), do: id
  defp strip(id), do: id

  # Each scanned test's id and version, for following renames.
  defp scanned_tests(root, opts) do
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    for %Surfex.Scan{kind: :test, id: id, hash: hash} <- Config.scans(config, root),
        into: %{},
        do: {id, hash}
  end
end
