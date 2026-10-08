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

  test "an empty batch is refused" do
    assert {:error, "no relations in the batch"} = Record.parse_batch("# nothing\n\n", 3)
  end
end
