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

  @tag verifies: "policies"
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

  # #341: test_helper.exs digests the project's own .surfex/ before the suite and fails the
  # run if this names anything after it.
  @tag :tmp_dir
  @tag verifies: ["policies", "suite-leaves-own-log"]
  test "a change to the project's own .surfex/ during the suite is named", %{tmp_dir: root} do
    alias Surfex.Test.OwnLog

    dir = Path.join(root, ".surfex")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "surfex.log"), "one\n")
    File.write!(Path.join(dir, "surfex_1.log"), "closed\n")
    before = OwnLog.digest(dir)

    assert OwnLog.changes(before, OwnLog.digest(dir)) == []

    File.write!(Path.join(dir, "surfex.log"), "two\n", [:append])
    File.rm!(Path.join(dir, "surfex_1.log"))
    File.write!(Path.join(dir, "surfex_2.log"), "new\n")

    assert OwnLog.changes(before, OwnLog.digest(dir)) == [
             "surfex.log changed",
             "surfex_1.log went missing",
             "surfex_2.log appeared"
           ]
  end
end
