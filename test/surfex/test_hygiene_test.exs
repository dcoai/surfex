defmodule Surfex.TestHygieneTest do
  @moduledoc """
  Rules about the test suite itself, checked on its source.

  The working directory belongs to the whole VM. A test module that runs async and changes
  it moves every test running alongside into its directory: relative paths resolve there,
  ExUnit's `tmp/` directories get created there, and cleanup races them. That made the
  suite fail about once in fifteen runs (#27). A module that must change directory runs
  with `async: false`.
  """
  use ExUnit.Case, async: true

  @tests Path.expand("..", __DIR__)

  test "no async test module changes the working directory" do
    offenders =
      for path <- Path.wildcard(Path.join(@tests, "**/*_test.exs")),
          text = File.read!(path),
          text =~ ~r/use ExUnit\.Case,\s*async: true/,
          text =~ ~r/File\.cd!?\(/,
          path != __ENV__.file,
          do: Path.relative_to(path, @tests)

    assert offenders == []
  end
end
