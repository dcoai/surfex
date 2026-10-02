defmodule Mix.Tasks.Surfex.Info do
  @shortdoc "How Surfex works: a directory, or a topic's page"

  @moduledoc """
  Tells an agent (or anyone) how Surfex works, from the installed version (§21).

      mix surfex.info            # the directory: what Surfex is, the topics, every command
      mix surfex.info process    # one topic's page

  An unknown topic fails, naming the topics. The agent topic is the package's
  `usage-rules.md`, the short page `mix usage_rules.sync` copies into a project's
  `AGENTS.md`, which points back here for the rest.
  """

  use Mix.Task

  @impl Mix.Task
  def run([]), do: Mix.shell().info(Surfex.Info.directory())

  def run([topic]) do
    case Surfex.Info.page(topic) do
      {:ok, page} -> Mix.shell().info(page)
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("usage: mix surfex.info [TOPIC]")
end
