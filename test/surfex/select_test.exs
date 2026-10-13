defmodule Surfex.SelectTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "test-selection"

  alias Surfex.{Scan, Select}

  defp spec(id, role, within \\ nil),
    do: %Scan{
      kind: :spec,
      id: id,
      hash: "s",
      location: %{file: "spec.md", lines: {1, 2}},
      role: role,
      within: within
    }

  defp test_scan(id, declares, file, line),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t",
      location: %{file: file, lines: {line, line + 2}},
      declares: Enum.map(declares, &{:verifies, &1})
    }

  # A section with a hint and a block inside it, the block with a hint of its own, and a
  # second spec file sharing one bare id.
  defp world do
    [
      spec("spec.md#carts", :section),
      spec("spec.md#cart-add", :test_hint, "spec.md#carts"),
      spec("spec.md#rule", :block, "spec.md#carts"),
      spec("spec.md#rule-hint", :test_hint, "spec.md#rule"),
      spec("spec.md#twin", :test_hint, "spec.md#carts"),
      spec("other.md#twin", :test_hint),
      test_scan("T: listed", ["cart-add", "carts"], "test/t_test.exs", 10),
      test_scan("T: one", ["cart-add"], "test/t_test.exs", 4),
      test_scan("T: deep", ["rule-hint"], "test/u_test.exs", 7),
      test_scan("T: none", [], "test/u_test.exs", 20)
    ]
  end

  defp ids({:ok, tests}), do: Enum.map(tests, & &1.id)

  test "the tests declaring a unit, a list's members included, by bare or full id" do
    # `--only verifies:carts` selects neither: `T: listed` is tagged with a list of two.
    assert ids(Select.tests(world(), ["carts"])) == ["T: listed"]
    assert ids(Select.tests(world(), ["spec.md#cart-add"])) == ["T: one", "T: listed"]
    # Several units: each test once, in file and line order.
    assert ids(Select.tests(world(), ["cart-add", "carts", "rule-hint"])) ==
             ["T: one", "T: listed", "T: deep"]
  end

  test "--within adds the tests of the units inside, along the within chain" do
    assert ids(Select.tests(world(), ["carts"], within: true)) ==
             ["T: one", "T: listed", "T: deep"]

    assert ids(Select.tests(world(), ["rule"], within: true)) == ["T: deep"]
  end

  test "an unknown, ambiguous or undeclared unit is an error, every one named" do
    assert {:error, "nope is no spec unit"} = Select.tests(world(), ["nope"])

    assert {:error, "twin is more than one spec unit: other.md#twin, spec.md#twin"} =
             Select.tests(world(), ["twin"])

    assert {:error, "no test declares spec.md#rule"} = Select.tests(world(), ["rule"])

    assert {:error, "nope is no spec unit; no test declares spec.md#rule"} =
             Select.tests(world(), ["carts", "nope", "rule"])

    # Nothing inside it is declared either.
    assert {:error, "no test declares spec.md#twin or a unit inside it"} =
             Select.tests(world(), ["spec.md#twin"], within: true)
  end

  test "args/1: each test's file and first line, once" do
    {:ok, tests} = Select.tests(world(), ["carts"], within: true)
    assert Select.args(tests) == ["test/t_test.exs:4", "test/t_test.exs:10", "test/u_test.exs:7"]

    # Tests generated in one comprehension share their line: one location runs them all.
    twins = [
      test_scan("T: a", ["x"], "test/t_test.exs", 3),
      test_scan("T: b", ["x"], "test/t_test.exs", 3)
    ]

    assert Select.args(twins) == ["test/t_test.exs:3"]
  end
end
