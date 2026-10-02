defmodule Surfex.Info do
  @moduledoc """
  How Surfex works, told by the installed version itself (§21): a directory of under 100
  lines and a page per topic, for an agent meeting Surfex in a project.

  The pages are the package's usage rules, built in at compile time: the directory is
  `usage-rules.md` and each topic is `usage-rules/TOPIC.md` (the layout `usage_rules`
  gathers into a project's `AGENTS.md`, and hexdocs show). The directory lists each topic
  as a ``- `mix surfex.info TOPIC`: summary`` item, and that item is the topic's one
  definition.
  """

  @dir Path.expand("../../usage-rules", __DIR__)
  @index Path.expand("../../usage-rules.md", __DIR__)
  @external_resource @index
  @directory File.read!(@index)

  @topics for [_, topic, summary] <-
                Regex.scan(~r/^- `mix surfex\.info ([a-z]+)`: (.+)$/m, @directory),
              do: {topic, summary}

  @pages Map.new(@topics, fn {topic, _} ->
           path = Path.join(@dir, topic <> ".md")
           @external_resource path
           {topic, File.read!(path)}
         end)

  @doc "The directory: what Surfex is, every topic and every command."
  @spec directory() :: String.t()
  def directory, do: @directory

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
