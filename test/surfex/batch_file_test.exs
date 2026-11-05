defmodule Surfex.BatchFileTest do
  # #147: a batch file is tab-separated, one relation per line, so ids may hold spaces and
  # colons (a test's id does). Blank lines and # comments are skipped.
  use ExUnit.Case, async: true
  @moduletag verifies: "batch-distinct-notes"

  alias Surfex.Record

  test "lines are read with their numbers, in the fields the command takes" do
    text = """
    # confirm these after #391's row change
    MyApp.CartTest: rejects a closed cart\tspec.md#closed\tverifies\tasserts the closed-cart refusal

    M.f/1\tM.g/2\tdepends_on\tf calls g for the total
    """

    assert {:ok,
            [
              %{
                line: 2,
                fields: ["MyApp.CartTest: rejects a closed cart", "spec.md#closed", "verifies"],
                note: "asserts the closed-cart refusal"
              },
              %{
                line: 4,
                fields: ["M.f/1", "M.g/2", "depends_on"],
                note: "f calls g for the total"
              }
            ]} = Record.parse_batch(text, 4)
  end

  test "a line with the wrong number of fields is refused, naming it" do
    assert {:error, "line 2: expected 4 tab-separated fields, got 2"} =
             Record.parse_batch("a\tb\tverifies\tnote\nonly two\tfields\n", 4)
  end

  describe "a batch of claims (#350): the note is optional" do
    @describetag verifies: "batch-claims"

    test "a line may leave the note out, or leave it empty, and has none" do
      text = "a\tb\tdepends_on\nc\td\tdepends_on\t\ne\tf\trefines\tf restates e\n"

      assert {:ok,
              [
                %{line: 1, fields: ["a", "b", "depends_on"], note: nil},
                %{line: 2, fields: ["c", "d", "depends_on"], note: nil},
                %{line: 3, fields: ["e", "f", "refines"], note: "f restates e"}
              ]} = Record.parse_batch(text, 4, note: :optional)
    end

    test "any other number of fields is refused, naming the line and what it takes" do
      for line <- ["a\tb", "a\tb\tdepends_on\tnote\tmore"] do
        assert {:error, "line 2: expected 3 or 4 tab-separated fields, got " <> _} =
                 Record.parse_batch("a\tb\tdepends_on\n" <> line <> "\n", 4, note: :optional)
      end
    end

    test "a judgement's note stays required: without the option a missing one is refused" do
      for line <- ["a\tb\tdepends_on\n", "a\tb\tdepends_on\t\n"] do
        assert {:error, "line 1: expected 4 tab-separated fields, got 3"} =
                 Record.parse_batch(line, 4)
      end
    end
  end

  test "an empty batch is refused" do
    assert {:error, "no relations in the batch"} = Record.parse_batch("# nothing\n\n", 3)
  end
end
