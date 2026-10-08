defmodule Surfex.Info do
  @moduledoc """
  How Surfex works, told by the installed version itself (§21): a directory of under 100
  lines and a page per topic, for an agent meeting Surfex in a project.

  The pages are Markdown, built in at compile time: the directory is
  `priv/info/index.md`, and each topic is `priv/info/TOPIC.md`, except the agent topic,
  which is the package's `usage-rules.md`: the short page `usage_rules` copies into a
  project's `AGENTS.md`, pointing back here. The directory lists each topic as a
  ``- `mix surfex.info TOPIC`: summary`` item, and that item is the topic's one definition.
  """

  @dir Path.expand("../../priv/info", __DIR__)
  @index Path.join(@dir, "index.md")
  # The agent topic is the package's usage rules (§21).
  @agent Path.expand("../../usage-rules.md", __DIR__)
  @external_resource @index
  @directory File.read!(@index)

  @topics for [_, topic, summary] <-
                Regex.scan(~r/^- `mix surfex\.info ([a-z]+)`: (.+)$/m, @directory),
              do: {topic, summary}

  @pages Map.new(@topics, fn {topic, _} ->
           path = if topic == "agent", do: @agent, else: Path.join(@dir, topic <> ".md")
           @external_resource path
           {topic, File.read!(path)}
         end)

  @doc "The directory: what Surfex is, every topic and every command."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc """
  A note for a project at `root` that keeps no relation log (`.surfex/`), or `nil`. Rendering
  surface goldens with `Surfex.Golden` is a use of surfex, not an adoption of it (§21).
  """
  @spec adoption_note(String.t()) :: String.t() | nil
  def adoption_note(root) do
    if File.dir?(Path.join(root, ".surfex")),
      do: nil,
      else:
        "This project has no relation log (.surfex/). Rendering goldens with Surfex.Golden " <>
          "is a use of surfex, not adoption: `mix surfex.info adoption`, then " <>
          "`mix surfex.log --init`."
  end

  @doc "Each topic with its one-line summary, in the directory's order."
  @spec topics() :: [{String.t(), String.t()}]
  def topics, do: @topics

  @doc "A topic's page, or an error naming the topics there are."
  @spec page(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def page(topic) do
    case Map.fetch(@pages, topic) do
      {:ok, page} ->
        {:ok, page}

      :error ->
        {:error,
         "no topic #{topic}: the topics are #{Enum.map_join(@topics, ", ", &elem(&1, 0))}"}
    end
  end
end
