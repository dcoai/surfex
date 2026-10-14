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

  # #224: the deviation tests, whatever they declare, in file and line order.
  @tag verifies: ["test-deviations", "test-selection"]
  test "deviations/1: every test declaring a deviation; none is an error" do
    deviant = fn id, file, line, ref ->
      %{test_scan(id, ["cart-add"], file, line) | deviation: ref}
    end

    tagged = [
      deviant.("T: late", "test/u_test.exs", 3, "#2"),
      deviant.("T: early", "test/t_test.exs", 30, "#1")
      | world()
    ]

    assert {:ok, tests} = Select.deviations(tagged)
    assert Enum.map(tests, & &1.id) == ["T: early", "T: late"]
    assert Select.deviations(world()) == {:error, "no test declares a deviation"}
  end

  # #224: ExUnit includes a skipped test only by its reason, and a FILE:LINE location
  # would replace every include, so each test goes by --only location: and each reason
  # by --include skip:, and a reason another test in their files shares is refused.
  @tag verifies: ["test-deviations", "test-selection"]
  test "deviation_args/1: files, a location each, a skip reason each; a shared reason refused" do
    deviant = fn id, line, skip ->
      %{test_scan(id, ["cart-add"], "test/t_test.exs", line) | deviation: "#1", skip: skip}
    end

    one = deviant.("T: one deviates", 3, "known deviation (#1)")
    two = deviant.("T: two deviate", 9, "true")
    unskipped = deviant.("T: not skipped", 15, nil)

    assert Select.deviation_args([one, two, unskipped]) == [
             "test/t_test.exs",
             "--only",
             "location:test/t_test.exs:3",
             "--only",
             "location:test/t_test.exs:9",
             "--only",
             "location:test/t_test.exs:15",
             "--include",
             "skip:known deviation (#1)",
             "--include",
             "skip:true"
           ]

    # The filters agree with ExUnit's own: the deviation runs; a test at another line, or
    # skipped for another reason, doesn't.
    include = [{:skip, "known deviation (#1)"}, {:location, {"test/t_test.exs", 3}}]
    tags = &Map.merge(%{file: "/p/test/t_test.exs", line: &1, describe_line: nil, test: true}, &2)
    suite = [%ExUnit.Test{name: :one, tags: tags.(3, %{})}]
    filter = &ExUnit.Filters.eval(include, [:test], &1, suite)

    assert filter.(tags.(3, %{skip: "known deviation (#1)"})) == :ok
    assert {:skipped, "parked"} = filter.(tags.(3, %{skip: "parked"}))
    assert {:excluded, _} = filter.(tags.(30, %{}))

    # Another test in their files skipped for a deviation's reason would run too: refused.
    parked = %{test_scan("T: parked", [], "test/t_test.exs", 30) | skip: "known deviation (#1)"}
    assert {:error, message} = Select.deviations([one, parked | world()])

    assert message =~
             ~s[T: parked is skipped for the reason "known deviation (#1)" as T: one deviates is]

    # The same reason in a file the run doesn't load is no conflict.
    elsewhere = %{parked | location: %{file: "test/u_test.exs", lines: {1, 2}}}
    assert {:ok, [_]} = Select.deviations([one, elsewhere | world()])

    # A reason computed at compile time can't be included by.
    assert {:error, message} = Select.deviations([%{one | skip: :unreadable} | world()])
    assert message =~ "T: one deviates's skip: isn't a literal"
  end
end
