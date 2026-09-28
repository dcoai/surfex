defmodule Mix.Tasks.Surfex.Log do
  @shortdoc "Create, segment, verify or rechain the relation log"

  @moduledoc """
  Looks after the relation log in `.surfex/` (`Surfex.Log`).

      mix surfex.log --init      # create it, and the union merge in .gitattributes
      mix surfex.log --break     # close the open segment and start a new one
      mix surfex.log --verify    # report every edited line, missing parent or broken chain
      mix surfex.log --rechain   # rewrite segment headers after a merge combined segments

  Entries are recorded by the recording commands, never by hand. This task never edits
  or removes one.
  """

  use Mix.Task

  alias Surfex.Log

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [init: :boolean, break: :boolean, verify: :boolean, rechain: :boolean]
      )

    root = File.cwd!()

    case Enum.filter([:init, :break, :verify, :rechain], &opts[&1]) do
      [:init] ->
        Log.init(root)
        Mix.shell().info("relation log ready in #{Log.dir(root)}")

      [:break] ->
        Log.break(root)
        Mix.shell().info("started a new segment in #{Log.dir(root)}")

      [:verify] ->
        case Log.verify(root) do
          [] -> Mix.shell().info("relation log verified: #{length(Log.load(root))} entries")
          problems -> Mix.raise(Enum.join(problems, "\n"))
        end

      [:rechain] ->
        Log.rechain(root)
        Mix.shell().info("segment headers rewritten")

      _ ->
        Mix.raise("give exactly one of --init, --break, --verify, --rechain")
    end
  end
end
