defmodule Mix.Tasks.Surfex.Draft do
  @shortdoc "Draft the work Surfex found, for the project's own change process"

  @moduledoc """
  Prints a change draft (`Surfex.Change`, §19) for every open mark, unmet id and triangle
  gap, or for the ids given: what's wrong, what it touches, and the steps the process
  implies. It prints and changes nothing:

      mix surfex.draft                       # every open mark, unmet id and gap
      mix surfex.draft spec.md#totals        # that unit's marks, or a draft to change it
      mix surfex.draft --format json         # for tools and agents

  With `--file` each draft goes to the project's `process:` in `.surfex.exs` instead:
  `:print` (the default) prints it, and `{:command, argv}` runs the command once per draft
  with `{title}`, `{body}` and `{file}` substituted, for instance to open an issue in the
  project's tracker. Surfex never hands anything off unless asked.
  """

  use Mix.Task

  alias Surfex.Change
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} =
      OptionParser.parse!(args, strict: [format: :string, file: :boolean, config: :string])

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    process = Config.process!(config)
    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    drafts = Change.drafts(Config.status(config, root, namespace, []), root, ids)

    cond do
      drafts == [] ->
        Mix.shell().info("nothing to draft: no open mark, unmet id or triangle gap")

      opts[:file] ->
        case Change.hand_off(drafts, process, root) do
          {:ok, outputs} -> Enum.each(outputs, &Mix.shell().info(&1))
          {:error, why} -> Mix.raise(why)
        end

      true ->
        case opts[:format] || "markdown" do
          "markdown" -> Enum.each(drafts, &Mix.shell().info(Change.markdown(&1)))
          "json" -> Mix.shell().info(Change.json(drafts))
          other -> Mix.raise("--format must be markdown or json, got #{inspect(other)}")
        end
    end
  end
end
