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

  It fails on any dangling, orphaned or conflicted relation, on any id the `require:`
  policy in `.surfex.exs` says must be related and isn't, and, with `--verify`, on any
  problem with the log. With `--no-planned` it fails on any planned relation as well, for
  a check that everything planned has been built (a release, say). With `--evidence` it
  fails when a relation confirmed by evidence isn't borne out by the evidence the last
  `mix test` recorded: its test didn't run, failed, or ran against other code. It only
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
          evidence: :boolean
        ]
      )

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    # Verified before loading: a tampered log gets its report, not the first decode error.
    problems = if opts[:verify], do: Log.verify(root), else: []

    if problems != [],
      do: Mix.raise("the relation log does not verify:\n" <> Enum.join(problems, "\n"))

    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    {scans, options} = Config.load(config, root, namespace)
    planned = if opts[:planned] == false, do: :fail, else: :allow

    status =
      Status.derive(
        scans,
        entries,
        Config.require!(config),
        [planned: planned] ++ options ++ evidence(opts, root)
      )

    case opts[:format] || "text" do
      "json" -> Mix.shell().info(Report.json(status))
      "text" -> Mix.shell().info(Report.text(status))
      other -> Mix.raise("--format must be text or json, got #{inspect(other)}")
    end

    if Status.failing?(status), do: Mix.raise("relations need attention (see above)")
  end

  # With --evidence, this run's evidence checks every confirmation by evidence. CI runs it
  # right after `mix test`, and records nothing.
  defp evidence(opts, root),
    do:
      if(opts[:evidence] == true,
        do: [evidence: Surfex.Evidence.load(Surfex.Evidence.path(root))],
        else: []
      )
end
