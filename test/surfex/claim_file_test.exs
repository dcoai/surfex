defmodule Surfex.ClaimFileTest do
  # #350, #352: a file of claims has an optional note, and each line stands alone, so one
  # with the wrong number of fields is refused without holding back the others.
  use ExUnit.Case, async: true
  @moduletag verifies: "batch-claims"

  alias Surfex.Record

  test "a line may leave the note out, or leave it empty, and has none" do
    text = "a\tb\tdepends_on\nc\td\tdepends_on\t\ne\tf\trefines\tf restates e\n"

    assert {:ok,
            [
              %{line: 1, fields: ["a", "b", "depends_on"], note: nil},
              %{line: 2, fields: ["c", "d", "depends_on"], note: nil},
              %{line: 3, fields: ["e", "f", "refines"], note: "f restates e"}
            ], []} = Record.parse_claims(text)
  end

  test "every line with another number of fields is refused, and the rest are kept" do
    text = "a\tb\n# a comment\nc\td\tdepends_on\n\ne\tf\tdepends_on\tnote\tmore\n"

    assert {:ok, [%{line: 3, fields: ["c", "d", "depends_on"]}],
            [
              %{line: 1, why: "expected 3 or 4 tab-separated fields, got 2"},
              %{line: 5, why: "expected 3 or 4 tab-separated fields, got 5"}
            ]} = Record.parse_claims(text)
  end

  test "a file of only refused lines is not an empty one, and an empty one is refused" do
    assert {:ok, [], [%{line: 1}]} = Record.parse_claims("only one field\n")
    assert {:error, "no relations in the batch"} = Record.parse_claims("# nothing\n\n")
  end
end
