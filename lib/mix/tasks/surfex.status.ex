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

  It fails on any dangling, orphaned or conflicted relation, on any id the `require:`
  policy in `.surfex.exs` says must be related and isn't, and, with `--verify`, on any
  problem with the log. With `--no-planned` it fails on any planned relation as well, for
  a check that everything planned has been built (a release, say). With `--evidence` it
  fails when a relation confirmed by evidence isn't borne out by the evidence the last
  `mix test` recorded: its test didn't run, failed, or ran against other code. With
  `--merge PATH` (once per file, implying `--evidence`) it checks the claims against several
  CI jobs' evidence files together: a disproof in any fails, and so does a claim no job
  ran. It only
  reads: nothing is recorded, so CI can run it after `mix test`. A project scanner is
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
          baseline: :boolean
        ]
      )

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    # Verified before loading: a tampered log gets its report, not the first decode error.
    problems = if opts[:verify], do: Log.verify(root), else: []

    if problems != [],
      do: Mix.raise("the relation log does not verify:\n" <> Enum.join(problems, "\n"))

    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    planned = if opts[:planned] == false, do: :fail, else: :allow
    marks = if opts[:marks] == false, do: :fail, else: :allow
    baseline = if opts[:baseline] == false, do: :fail, else: :allow

    status =
      Config.status(
        config,
        root,
        namespace,
        [planned: planned, marks: marks, baseline: baseline, validated: opts[:validated] == true] ++
          evidence(opts, root)
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
