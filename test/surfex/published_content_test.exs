defmodule Surfex.PublishedContentTest do
  @moduledoc """
  Surfex is published publicly, and what it publishes is its own: tooling, and tests that
  belong to it or are generalised for any project (#12). Another project's material
  (its code, its fixtures, its private spec text, even its name as a source of test data)
  does not belong in this repository.

  This guards the one case that has happened: a consumer's fixture captured into surfex's
  tests. Add a name here when another consumer's material must never appear.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Built at runtime so that this file does not match itself.
  @forbidden [Enum.join(["ho", "ma"])]

  @published ~w(lib/**/* guides/**/* test/**/* spec.md README.md CHANGELOG.md RELEASING.md mix.exs .surfex.exs RELATIONS.md)

  test "no published file carries another project's material" do
    files =
      @published
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1), match_dot: true))
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&String.contains?(&1, "/tmp/"))

    assert length(files) > 20

    offending =
      for file <- files,
          text = File.read!(file),
          word <- @forbidden,
          String.contains?(String.downcase(text), word),
          do: "#{Path.relative_to(file, @root)} mentions #{inspect(word)}"

    assert offending == []
  end
end
