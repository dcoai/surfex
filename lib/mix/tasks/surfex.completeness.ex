defmodule Mix.Tasks.Surfex.Completeness do
  @shortdoc "Report how much of the spec, the tests and the code is covered"

  @moduledoc """
  Prints the completeness report (`Surfex.Completeness`, §20): a score per kind (spec
  units, tests, code) and overall, and every incomplete item with what it lacks and where.

      mix surfex.completeness                  # text
      mix surfex.completeness --summary        # the score lines only, for a gate step
      mix surfex.completeness --format json    # the work list for an agent

  It fails when the overall score is below `completeness: [min: N]` in `.surfex.exs`, with
  or without `--summary`. `--summary` is a text form: with `--format json` it is refused.
  """

  use Mix.Task

  alias Surfex.Completeness
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [format: :string, config: :string, summary: :boolean])

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    min = Config.completeness!(config)
    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    report = Completeness.report(Config.status(config, root, namespace, []))

    case {opts[:format] || "text", opts[:summary] || false} do
      {"text", false} -> Mix.shell().info(Completeness.text(report))
      {"text", true} -> Mix.shell().info(Completeness.summary(report))
      {"json", false} -> Mix.shell().info(Completeness.json(report))
      {"json", true} -> Mix.raise("--summary is the text form's scores; drop it or --format json")
      {other, _} -> Mix.raise("--format must be text or json, got #{inspect(other)}")
    end

    if Completeness.below?(report, min),
      do: Mix.raise("completeness #{report.scores.overall.percent}% is below the minimum, #{min}")
  end
end
