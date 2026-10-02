defmodule Mix.Tasks.Surfex.Completeness do
  @shortdoc "Report how much of the spec, the tests and the code is covered"

  @moduledoc """
  Prints the completeness report (`Surfex.Completeness`, §20): a score per kind (spec
  units, tests, code) and overall, and every incomplete item with what it lacks and where.

      mix surfex.completeness                  # text
      mix surfex.completeness --format json    # the work list for an agent

  It fails when the overall score is below `completeness: [min: N]` in `.surfex.exs`.
  """

  use Mix.Task

  alias Surfex.Completeness
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [format: :string, config: :string])
    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    min = Config.completeness!(config)
    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    report = Completeness.report(Config.status(config, root, namespace, []))

    case opts[:format] || "text" do
      "text" -> Mix.shell().info(Completeness.text(report))
      "json" -> Mix.shell().info(Completeness.json(report))
      other -> Mix.raise("--format must be text or json, got #{inspect(other)}")
    end

    if Completeness.below?(report, min),
      do: Mix.raise("completeness #{report.scores.overall.percent}% is below the minimum, #{min}")
  end
end
