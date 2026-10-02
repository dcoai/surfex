defmodule Surfex.PublishedContentTest do
  @moduledoc """
  Surfex is published publicly, and what it publishes is its own: tooling, and tests that
  belong to it or are generalised for any project (#12). Another project's material
  (its code, its fixtures, its private spec text, even its name as a source of test data)
  does not belong in this repository.

  This guards the cases that have happened: a consumer's fixture captured into surfex's
  tests, and a consumer's module names used as a test's data (#112). Add a name here when
  another consumer's material must never appear.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Built at runtime so that this file does not match itself.
  @forbidden [Enum.join(["ho", "ma"])]

  # The projects that adopt surfex (#112). RELATIONS.md is left out: it is rendered from
  # the relation log, which is append-only and still names a test from before the rename.
  @adopters [Enum.join(["met", "resis"]), Enum.join(["dep", "dep"])]

  @published ~w(lib/**/* guides/**/* test/**/* spec.md README.md CHANGELOG.md RELEASING.md mix.exs .surfex.exs RELATIONS.md)

  @tag verifies: "policies"
  test "no published file carries another project's material" do
    files =
      @published
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1), match_dot: true))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&String.contains?(&1, "/tmp/"))

    assert length(files) > 20

    offending =
      for file <- files,
          text = String.downcase(File.read!(file)),
          word <- @forbidden ++ adopters(file),
          String.contains?(text, word),
          do: "#{Path.relative_to(file, @root)} mentions #{inspect(word)}"

    assert offending == []
  end

  # #83: a scripted edit once wrote its own source into spec.md. Prose never holds a pipe
  # into a call, a sigil heredoc or a heredoc's close; the guides show Elixir only in fences.
  @markdown ~w(spec.md README.md CHANGELOG.md RELEASING.md guides/**/*.md)
  @residue [~r/^\s*\|> /, ~r/~S("""|''')/, ~r/"""\)/]

  @tag verifies: "policies"
  test "no published Markdown carries script residue outside a fence" do
    files = Enum.flat_map(@markdown, &Path.wildcard(Path.join(@root, &1)))
    assert length(files) > 4

    offending =
      for file <- files,
          {line, n} <- unfenced(File.read!(file)),
          Enum.any?(@residue, &Regex.match?(&1, line)),
          do: "#{Path.relative_to(file, @root)}:#{n}: #{line}"

    assert offending == []
  end

  defp adopters(file), do: if(Path.basename(file) == "RELATIONS.md", do: [], else: @adopters)

  # The lines outside fenced blocks, with their numbers.
  defp unfenced(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(false, fn {line, n}, fenced ->
      if String.match?(line, ~r/^\s*(```|~~~)/),
        do: {nil, not fenced},
        else: {if(fenced, do: nil, else: {line, n}), fenced}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end
end
