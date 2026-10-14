defmodule Mix.Tasks.Surfex.Status do
  @shortdoc "Report the state of every spec↔code relation, and check it"

  @moduledoc """
  Scans the spec and the code, reads the relation log, and reports the state of every
  relation (`Surfex.Status`).

      mix surfex.status                  # text; fails if anything needs attention
      mix surfex.status --format json    # the work list for tools and agents
      mix surfex.status --verify         # also verify the log (edits, removals, truncation)
      mix surfex.status --no-planned     # also fail on planned relations: everything built
      mix surfex.status --evidence       # also check confirmations by evidence against the last run
      mix surfex.status --merge A --merge B   # check them against several CI jobs' evidence together
      mix surfex.status --validated      # also fail on relations nothing has validated (§18)
      mix surfex.status --no-deviations  # also fail on declared deviations: a release's check
      mix surfex.status --issues         # also ask the tracker whether each deferral's issue is open

  It fails on any dangling, orphaned or conflicted relation, on any id the `require:`
  policy in `.surfex.exs` says must be related and isn't, and, with `--verify`, on any
  problem with the log. With `--no-planned` it fails on any planned relation as well, for
  a check that everything planned has been built (a release, say). A unit a test declares
  the code deviates from (`@tag deviation: "#119"`) is listed, and its proposed relations
  don't fail; with `--no-deviations` any deviation fails, and a deviation test that passed
  in the evidence always does (`Surfex.Status`). With `--evidence` it
  fails when a relation confirmed by evidence isn't borne out by the evidence the last
  `mix test` recorded: its test didn't run, failed, or ran against other code. It also
  fails on any `verifies` or `tests` relation whose test failed, whatever validated it: a
  review relies on the run to say whether its test passes. With
  `--merge PATH` (once per file, implying `--evidence`) it checks the claims against several
  CI jobs' evidence files together: a disproof in any fails, and so does a claim no job
  ran. It only
  reads: nothing is recorded, so CI can run it after `mix test`. With `--issues` it runs
  the command `issues:` in `.surfex.exs` declares once per issue the spec's deferrals
  name (`Surfex.Issues`), so under `claim_grain: true` a deferral whose issue is closed,
  or that the tracker can't answer, fails; a command that exits non-zero stops the task
  with its output. The states are never stored (§13.7). A project scanner is
  project code, so the task compiles first when `.surfex.exs` names one.
  """

  use Mix.Task

  alias Surfex.{Log, Status}
  alias Surfex.Status.{Config, Report}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          format: :string,
          verify: :boolean,
          config: :string,
          planned: :boolean,
          evidence: :boolean,
          merge: :keep,
          validated: :boolean,
          marks: :boolean,
          baseline: :boolean,
          deviations: :boolean,
          issues: :boolean
        ]
      )

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    # Verified before loading: a tampered log gets its report, not the first decode error.
    problems = if opts[:verify], do: Log.verify(root), else: []

    if problems != [],
      do: Mix.raise("the relation log does not verify:\n" <> Enum.join(problems, "\n"))

    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    planned = if opts[:planned] == false, do: :fail, else: :allow
    marks = if opts[:marks] == false, do: :fail, else: :allow
    baseline = if opts[:baseline] == false, do: :fail, else: :allow
    deviations = if opts[:deviations] == false, do: :fail, else: :allow

    status =
      Config.status(
        config,
        root,
        namespace,
        [
          planned: planned,
          marks: marks,
          baseline: baseline,
          deviations: deviations,
          validated: opts[:validated] == true
        ] ++
          evidence(opts, root) ++ issues(opts, config, root)
      )

    case opts[:format] || "text" do
      "json" -> Mix.shell().info(Report.json(status))
      "text" -> Mix.shell().info(Report.text(status))
      other -> Mix.raise("--format must be text or json, got #{inspect(other)}")
    end

    if Status.failing?(status), do: Mix.raise("relations need attention (see above)")

    # A floor the maintainer set on the completeness score (§20).
    min = Config.completeness!(config)
    report = Surfex.Completeness.report(status)

    if Surfex.Completeness.below?(report, min),
      do:
        Mix.raise(
          "completeness #{report.scores.overall.percent}% is below the minimum, #{min}: " <>
            "mix surfex.completeness lists what's missing"
        )
  end

  # With --issues, the tracker is asked for each deferral's issue, through the project's
  # declared command, once the spec is scanned (§13.7).
  defp issues(opts, config, root) do
    if opts[:issues] == true do
      resolver =
        Config.issues!(config) ||
          Mix.raise("--issues needs issues: in .surfex.exs, the command that asks the tracker")

      [
        issues: fn refs ->
          case Surfex.Issues.states(resolver, refs, root) do
            {:ok, states} -> states
            {:error, {ref, output}} -> Mix.raise("asking the tracker about #{ref}: #{output}")
          end
        end
      ]
    else
      []
    end
  end

  # With --evidence, this run's evidence checks every confirmation by evidence. CI runs it
  # right after `mix test`, and records nothing.
  # With --merge, a final job reads each job's evidence file instead (§17): only those,
  # and a named file that isn't there fails rather than reading as an empty run.
  defp evidence(opts, root) do
    case Keyword.get_values(opts, :merge) do
      [] ->
        if opts[:evidence] == true,
          do: [evidence: Surfex.Evidence.load(Surfex.Evidence.path(root))],
          else: []

      paths ->
        for path <- paths,
            not File.exists?(path),
            do: Mix.raise("--merge: no evidence file at #{path}")

        [evidence: {:merged, Enum.map(paths, &Surfex.Evidence.load/1)}]
    end
  end
end
