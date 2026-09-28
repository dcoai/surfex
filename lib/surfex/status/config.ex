defmodule Surfex.Status.Config do
  @moduledoc """
  What `mix surfex.status` reads from `.surfex.exs`: where the spec is, how to scan the
  code, and the `require:` policy. The keys are the trace's own (§9), so one file serves
  both; `require:` is the status's alone.

    * `:sources` — globs of the markdown spec files (required)
    * `:scanner`, `:scanner_opts` — the code scanner (`:elixir` by default)
    * `:require` — `[key: [type, …]]`: a key is a kind (`:spec`, `:code`, `:test`, …) or
      a spec role (`:section`, `:block`, `:test_hint`), validated with the types
    * `:tests` — globs of ExUnit test files, scanned for tests (`Surfex.Scan.ExUnit`)
      when present
    * `:triangle` — `:report` (the default) or `:fail`: whether gaps in the spec/test/code
      triangle fail the check or are only reported
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @roles [:section, :block, :test_hint]

  @doc """
  The options `Surfex.Status.derive/4` takes from `.surfex.exs`: `triangle:`, validated.
  Raises `ArgumentError` naming what is wrong.
  """
  @spec options!(keyword) :: keyword
  def options!(config) do
    triangle = Keyword.get(config, :triangle, :report)

    unless triangle in [:report, :fail],
      do: raise(ArgumentError, "triangle: must be :report or :fail, got #{inspect(triangle)}")

    coverage =
      if Keyword.has_key?(config, :classes),
        do: [coverage: Surfex.Profile.coverage!(config)],
        else: []

    [triangle: triangle] ++ coverage
  end

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
      unless kind in Entry.kinds() or kind in @roles,
        do: raise(ArgumentError, "require: #{inspect(kind)} is neither a kind nor a spec role")

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

    spec ++ Scan.code(items(config, root)) ++ tests(config, root) ++ classes(config)
  end

  # Classes (`classes:` and `rules:`, the trace's own keys) are scanned when a project has
  # any: each is a record excusals relate to (`Surfex.Scan.Classes`).
  defp classes(config),
    do: if(Keyword.has_key?(config, :classes), do: Scan.Classes.records(config), else: [])

  # No `tests:` means no test scanning. Globs that match nothing raise, as `sources:` do: a
  # misspelt glob would otherwise report every test relation orphaned.
  defp tests(config, root) do
    case Keyword.get(config, :tests) do
      nil ->
        []

      globs ->
        files = Enum.flat_map(globs, &Path.wildcard(Path.join(root, &1)))

        if files == [],
          do: raise(ArgumentError, "tests: #{inspect(globs)} matches no file under #{root}")

        Scan.ExUnit.records(root, globs)
    end
  end

  defp items(config, root) do
    opts = Keyword.get(config, :scanner_opts, [])

    case Keyword.get(config, :scanner, :elixir) do
      :elixir -> Surfex.Scanner.Elixir.items(root, opts)
      scanner -> scanner.items(root, opts)
    end
  end
end
