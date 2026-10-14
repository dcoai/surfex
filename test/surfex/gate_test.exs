defmodule Surfex.GateTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "gate-drift"
  @moduletag :tmp_dir

  alias Surfex.Gate

  @old "| Item | Version |\n|---|---|\n| `a` | `1` |\n| `b` | `1` |\n"

  @tag verifies: ["gate-drift", "gate-drift-rows", "gate"]
  test "identical texts don't drift; changed, added and gone rows are named" do
    assert Gate.drift(@old, @old) == nil

    new = "| Item | Version |\n|---|---|\n| `a` | `2` |\n| `c` | `1` |\n"
    message = Gate.drift(@old, new)
    assert message =~ "Changed:\n  a — Version 1 → 2\n"
    assert message =~ "Added:\n  c\n"
    assert message =~ "Gone:\n  b\n"
  end

  @tag verifies: ["gate-drift", "gate-drift-rows", "gate"]
  test "without Item, a row is keyed by its first column when that is unique, and compared whole" do
    old = "| Name | Note |\n|---|---|\n| `a` | x |\n| `b` | y |\n"
    new = "| Name | Note |\n|---|---|\n| `a` | x |\n| `b` | z |\n"
    message = Gate.drift(old, new)
    assert message =~ "Changed:\n  b — Note y → z\n"
    refute message =~ "  a\n"
  end

  # #199: Surfex.Golden writes an item holding `|` or a backtick as a longer-fenced span with
  # `\|`; the drift names the item by its text.
  @tag verifies: ["gate-drift", "gate-drift-rows"]
  test "a row is named by its item's text, read back from the code span" do
    old = "| Item | Version |\n|---|---|\n| `` a\\|` `` | `1` |\n| ``` b`` ``` | `1` |\n"
    new = "| Item | Version |\n|---|---|\n| `` a\\|` `` | `2` |\n"
    message = Gate.drift(old, new)
    assert message =~ "Changed:\n  a|` — Version 1 → 2\n"
    assert message =~ "Gone:\n  b``\n"
  end

  test "a change outside every row says the prose or a stats line changed" do
    assert Gate.drift("# A\nold\n" <> @old, "# A\nnew\n" <> @old) =~ "No row changed"
  end

  # #215: a relation table's rows share their first cell (the from-end), so a row keyed by
  # it collapsed into its neighbours and a hand-edited state read as a prose change.
  @drift_relations """
  # R.md
  Every relation.

  **3 relations** · current 3 · retired 0

  ## excuses

  | End | Other end | State | Changed |
  |---|---|---|---|
  | `class x` | `code A.f/1` | `:current` | — |
  | `class x` | `code A.g/1` | `:current` | — |

  ## implements

  | End | Other end | State | Changed |
  |---|---|---|---|
  | `class x` | `code A.f/1` | `:current` | — |
  """

  @tag verifies: ["gate-drift", "gate-drift-rows", "gate"]
  test "a hand-edited cell of a row sharing its first cell is named, old and new" do
    edited =
      String.replace(@drift_relations, "`code A.g/1` | `:current`", "`code A.g/1` | `:retired`")

    message = Gate.drift(@drift_relations, edited)

    assert message =~ "Changed:\n  excuses: class x · code A.g/1 — State :current → :retired\n"
    refute message =~ "No row changed"
    refute message =~ "A.f/1"
  end

  @tag verifies: ["gate-drift", "gate-drift-rows"]
  test "the same row in two tables is two rows: one going is named under its heading" do
    gone = String.replace(@drift_relations, "## implements\n", "## refines\n")
    message = Gate.drift(@drift_relations, gone)
    assert message =~ "Added:\n  refines: class x\n"
    assert message =~ "Gone:\n  implements: class x\n"
  end

  test "a stats-line edit alone changes no row" do
    stats = String.replace(@drift_relations, "current 3 · retired 0", "current 2 · retired 1")

    assert Gate.drift(@drift_relations, stats) =~
             "out of date.\n\nNo row changed: the prose or a stats line did.\n"
  end

  @tag verifies: ["gate-drift", "gate-drift-rows", "gate"]
  test "an escaped \\| stays inside its cell, padded or not" do
    old = "| Item | Note |\n|---|---|\n| `a \\| b` | x |\n|`c\\|d`|y|\n"
    new = "| Item | Note |\n|---|---|\n| `a \\| b` | z |\n|`c\\|d`|w|\n"
    message = Gate.drift(old, new)
    assert message =~ "Changed:\n  a | b — Note x → z\n  c|d — Note y → w\n"
  end

  @tag verifies: ["gate-drift", "gate-drift-rows"]
  test "identical rows are told apart by their occurrence" do
    old = "| Name | Note |\n|---|---|\n| a | x |\n| a | x |\n"
    new = "| Name | Note |\n|---|---|\n| a | x |\n"
    assert Gate.drift(old, new) =~ "Gone:\n  a · x (2)\n"
  end

  @tag verifies: ["gate-drift", "gate"]
  test "run writes, then checks: a missing file and a drift fail, naming what regenerates", %{
    tmp_dir: root
  } do
    path = Path.join(root, "G.md")
    assert [missing] = Gate.run(path, @old, "mix g", false)
    assert missing =~ "G.md does not exist. Run `mix g --write`."

    assert Gate.run(path, @old, "mix g", true) == []
    assert Gate.run(path, @old, "mix g", false) == []

    assert [drift] =
             Gate.run(path, String.replace(@old, "`1` |\n| `b`", "`2` |\n| `b`"), "mix g", false)

    assert drift =~ "G.md: out of date."
    assert drift =~ "Regenerate with `mix g --write`"
  end

  @tag verifies: ["gate-drift", "gate"]
  test "config!/1 evaluates a data file to a keyword list, or raises naming it", %{tmp_dir: root} do
    good = Path.join(root, "good.exs")
    File.write!(good, "[sources: [\"spec.md\"]]")
    assert Gate.config!(good) == [sources: ["spec.md"]]

    bad = Path.join(root, "bad.exs")
    File.write!(bad, "%{}")
    assert_raise ArgumentError, ~r/must evaluate to a keyword list/, fn -> Gate.config!(bad) end

    assert_raise ArgumentError, ~r/does not exist/, fn ->
      Gate.config!(Path.join(root, "none.exs"))
    end
  end
end
