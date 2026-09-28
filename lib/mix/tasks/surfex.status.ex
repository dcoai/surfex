defmodule Mix.Tasks.Surfex.Status do
  @shortdoc "Report the state of every spec↔code relation, and check it"

  @moduledoc """
  Scans the spec and the code, reads the relation log, and reports the state of every
  relation (`Surfex.Status`).

      mix surfex.status                  # text; fails if anything needs attention
      mix surfex.status --format json    # the work list for tools and agents
      mix surfex.status --verify         # also verify the log (edits, removals, truncation)

  It fails on any dangling, orphaned or conflicted relation, on any id the `require:`
  policy in `.surfex.exs` says must be related and isn't, and, with `--verify`, on any
  problem with the log. A project scanner is project code, so the task compiles first
  when `.surfex.exs` names one.
  """

  use Mix.Task

  alias Surfex.{Gate, Log, Status}
  alias Surfex.Status.{Config, Report}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [format: :string, verify: :boolean, config: :string])

    root = File.cwd!()
    config = Gate.config!(Path.join(root, opts[:config] || ".surfex.exs"))

    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    # Verified before loading: a tampered log gets its report, not the first decode error.
    problems = if opts[:verify], do: Log.verify(root), else: []

    if problems != [],
      do: Mix.raise("the relation log does not verify:\n" <> Enum.join(problems, "\n"))

    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []
    status = Status.derive(Config.scans(config, root), entries, Config.require!(config))

    case opts[:format] || "text" do
      "json" -> Mix.shell().info(Report.json(status))
      "text" -> Mix.shell().info(Report.text(status))
      other -> Mix.raise("--format must be text or json, got #{inspect(other)}")
    end

    if Status.failing?(status), do: Mix.raise("relations need attention (see above)")
  end
end
