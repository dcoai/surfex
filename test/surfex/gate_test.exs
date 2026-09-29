defmodule Surfex.GateTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "gate-drift"
  @moduletag :tmp_dir

  alias Surfex.Gate

  @old "| Item | Version |\n|---|---|\n| `a` | `1` |\n| `b` | `1` |\n"

  test "identical texts don't drift; changed, added and gone rows are named" do
    assert Gate.drift(@old, @old) == nil

    new = "| Item | Version |\n|---|---|\n| `a` | `2` |\n| `c` | `1` |\n"
    message = Gate.drift(@old, new)
    assert message =~ "Changed:\n  a\n"
    assert message =~ "Added:\n  c\n"
    assert message =~ "Gone:\n  b\n"
  end

  test "without Item or Version, a row is keyed by its first column and compared whole" do
    old = "| Name | Note |\n|---|---|\n| `a` | x |\n| `b` | y |\n"
    new = "| Name | Note |\n|---|---|\n| `a` | x |\n| `b` | z |\n"
    message = Gate.drift(old, new)
    assert message =~ "Changed:\n  b\n"
    refute message =~ "  a\n"
  end

  test "a change outside every row says the prose or a stats line changed" do
    assert Gate.drift("# A\nold\n" <> @old, "# A\nnew\n" <> @old) =~ "No row changed"
  end

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
