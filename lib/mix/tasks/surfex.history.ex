defmodule Mix.Tasks.Surfex.History do
  @shortdoc "Every relation an id has had, from the log alone"

  @moduledoc """
  Lists every log entry touching an id, oldest first (`Surfex.Record.history/2`): what it
  was related to, at which versions, when, by whom, and why. It reads only the log, so it
  answers from any checkout, however the git history was rewritten.

      mix surfex.history MyApp.Cart.add/2
  """

  use Mix.Task

  alias Surfex.Log
  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {_opts, ids} = R.parse(args)

    id =
      case ids do
        [id] -> id
        _ -> Mix.raise("give one id")
      end

    case Surfex.Record.history(Log.load(File.cwd!()), id) do
      [] ->
        Mix.shell().info("no entries touch #{id}")

      entries ->
        for e <- entries do
          by = if e.by, do: " by #{e.by}", else: ""
          Mix.shell().info("#{e.at}#{by}: #{R.describe(e)}")
        end
    end
  end
end
