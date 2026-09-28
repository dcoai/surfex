defmodule Surfex.Status.Config do
  @moduledoc """
  What `mix surfex.status` reads from `.surfex.exs`: where the spec is, how to scan the
  code, and the `require:` policy. The keys are the trace's own (§9), so one file serves
  both; `require:` is the status's alone.

    * `:sources` — globs of the markdown spec files (required)
    * `:scanner`, `:scanner_opts` — the code scanner (`:elixir` by default)
    * `:require` — `[kind: [type, …]]`, validated against the known kinds and types
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @doc "The `require:` policy, validated. Raises `ArgumentError` naming what is wrong."
  @spec require!(keyword) :: keyword
  def require!(config) do
    policy = Keyword.get(config, :require, [])

    unless Keyword.keyword?(policy),
      do:
        raise(
          ArgumentError,
          "require: must be a keyword list of kind: [type, …], got #{inspect(policy)}"
        )

    for {kind, types} <- policy do
      unless kind in Entry.kinds(),
        do: raise(ArgumentError, "require: unknown kind #{inspect(kind)}")

      unless is_list(types) and types != [] and Enum.all?(types, &(&1 in Entry.types())),
        do:
          raise(
            ArgumentError,
            "require: #{kind} needs a non-empty list of #{inspect(Entry.types())}"
          )
    end

    policy
  end

  @doc """
  Every scan record under `root`: each markdown section of the `sources`, and each item
  the code scanner finds. Raises when `sources` is missing or matches nothing, since a
  status over no spec would report every relation orphaned without saying why.
  """
  @spec scans(keyword, String.t()) :: [Scan.t()]
  def scans(config, root) do
    sources =
      Keyword.get(config, :sources) ||
        raise(ArgumentError, ".surfex.exs needs sources: (the spec's globs)")

    spec = Scan.Markdown.records(root, sources)

    if spec == [],
      do: raise(ArgumentError, "no spec sections found in #{inspect(sources)} under #{root}")

    spec ++ Scan.code(items(config, root))
  end

  defp items(config, root) do
    opts = Keyword.get(config, :scanner_opts, [])

    case Keyword.get(config, :scanner, :elixir) do
      :elixir -> Surfex.Scanner.Elixir.items(root, opts)
      scanner -> scanner.items(root, opts)
    end
  end
end
