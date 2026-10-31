defmodule Surfex.UnitVersionsTest do
  # #338: every relation to a spec unit records its version, so a release that versions
  # the same text differently dangles every such relation on the upgrade (§23.3). #305
  # re-versioned every marked table, and #317 every row of an `ignore:` table, while
  # neither meant to; no test noticed, because none pinned a version.
  #
  # The literals below are the versions surfex 0.10.0 gives this text. They were computed
  # by running `Surfex.Scan.Markdown.sections(text, "spec.md")` with `mix run` in a
  # checkout of the v0.10.0 tag, printing each unit's role, id and hash. Never update one
  # to make this test pass: a different version is either a bug or an intended change to
  # the version rule, which comes in a minor release with an upgrade step (§23.3), and then
  # the literal is recomputed under that release and the reason written here.
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown

  @text """
  # Spec

  ## Plain

  A plain section: its version covers this body,
  across two lines.

  ## Tables

  Text before the table.

  <!-- surfex: table modes -->
  | Mode | Meaning | Since |
  |------|---------|-------|
  | `:normal` | the default | 0.1 |
  | *fast* | skips checks | 0.2 |

  <!-- surfex: table measured key: Name ignore: [Measured] -->
  |Name|Claim|Measured|
  |---|---|---|
  | alpha | holds | 12 |
  |beta|holds too|7|

  Text after the tables.

  ## Finer units

  <!-- surfex: retry -->
  A marked block: a failed call is retried three times.
  <!-- /surfex -->

  ```test:retry-hint
  a failed call is retried three times, then raises
  ```

  <!-- surfex: one-rule -->
  - A named rule, with
    a nested line.

  <!-- surfex: contract module: MyApp.Feed -->
  ```elixir
  # Fetches the feed.
  @spec fetch(String.t()) :: {:ok, term} | :error
  ```
  """

  # Under surfex 0.10.0, `{role, id, version}` of every unit of @text, in order.
  @released [
    {:section, "spec.md#Spec", "e3b0c442"},
    {:section, "spec.md#Spec/Plain", "30bf2380"},
    {:section, "spec.md#Spec/Tables", "1068e34a"},
    {:table, "spec.md#modes", "5c109abc"},
    {:row, "spec.md#modes/:normal", "5eac7710"},
    {:row, "spec.md#modes/fast", "52b51713"},
    {:table, "spec.md#measured", "e23d11c1"},
    {:row, "spec.md#measured/alpha", "f59ba3c0"},
    {:row, "spec.md#measured/beta", "af10f976"},
    {:section, "spec.md#Spec/Finer units", "47f0a6b4"},
    {:block, "spec.md#retry", "73299cc7"},
    {:test_hint, "spec.md#retry-hint", "69f53c3d"},
    {:rule, "spec.md#one-rule", "b428bc56"},
    {:contract, "spec.md#MyApp.Feed.fetch/1", "f9991ef9"}
  ]

  defp units_versions(text),
    do: for(s <- Markdown.sections(text, "spec.md"), do: {s.role, s.id, s.hash})

  describe "spec unit versions" do
    @describetag verifies: ["unit-versions-stable", "unit-versions-hold"]

    test "every unit has the version the last release gave it" do
      assert units_versions(@text) == @released
    end
  end
end
