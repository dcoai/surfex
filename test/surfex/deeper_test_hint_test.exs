defmodule Surfex.DeeperTestHintTest do
  # #290, #378: a tool crediting shallow evidence more cheaply than deep evidence teaches shallow
  # tests. A review should at least say when there's a deeper one.
  use ExUnit.Case, async: true
  @moduletag verifies: "review-deeper-test"

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry

  @unit "spec.md#rpt"
  @at "2026-11-06T10:00:00Z"

  defp spec,
    do: %Scan{
      kind: :spec,
      id: @unit,
      hash: "s",
      role: :section,
      location: %{file: "spec.md", lines: {1, 2}}
    }

  defp code(id, lines, calls \\ []),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "c-#{id}",
      role: :function,
      calls: calls,
      location: %{file: "lib/m.ex", lines: lines}
    }

  defp test_scan(id, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t-#{id}",
      calls: calls,
      declares: [{:verifies, @unit}],
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp rel(type, {ak, a, ah}, {bk, b, bh}),
    do:
      Entry.new!(
        at: @at,
        op: :relate,
        type: type,
        basis: :review,
        note: "checked",
        ends: [%{kind: ak, id: a, hash: ah}, %{kind: bk, id: b, hash: bh}]
      )

  defp world(tests) do
    codes = [
      code("M.run/1", {1, 2}, ["M.a/0", "M.b/0", "M.c/0"]),
      code("M.a/0", {3, 4}),
      code("M.b/0", {5, 6}),
      code("M.c/0", {7, 8})
    ]

    scans = [spec() | codes] ++ tests

    implements =
      for c <- codes, do: rel(:implements, {:code, c.id, c.hash}, {:spec, @unit, "s"})

    verifies =
      for t <- tests, do: rel(:verifies, {:test, t.id, t.hash}, {:spec, @unit, "s"})

    Status.derive(scans, implements ++ verifies, [], [])
  end

  test "names the test reaching the most, how many more, and through what" do
    status =
      world([
        test_scan("T: shallow", ["M.a/0"]),
        test_scan("T: middling", ["M.a/0", "M.b/0"]),
        test_scan("T: deep", ["M.run/1"])
      ])

    assert %{test: "T: deep", more: 3, through: "M.run/1"} =
             Status.deeper_test(status, "T: shallow", @unit)

    assert Status.deeper_test_text(%{test: "T: deep", more: 3, through: "M.run/1"}, @unit) ==
             "T: deep also verifies #{@unit} and reaches 3 more of its code (through M.run/1)"
  end

  test "says nothing when no other test verifying the unit reaches more" do
    status = world([test_scan("T: deep", ["M.run/1"]), test_scan("T: shallow", ["M.a/0"])])

    assert Status.deeper_test(status, "T: deep", @unit) == nil

    alone = world([test_scan("T: only", ["M.a/0"])])
    assert Status.deeper_test(alone, "T: only", @unit) == nil

    # Reaching the same amount of different code is no deeper.
    same = world([test_scan("T: a", ["M.a/0"]), test_scan("T: b", ["M.b/0"])])
    assert Status.deeper_test(same, "T: a", @unit) == nil
  end

  test "code outside the unit doesn't count toward deeper" do
    extra = code("M.other/0", {9, 10})
    t1 = test_scan("T: on the unit", ["M.a/0", "M.b/0"])
    t2 = test_scan("T: elsewhere", ["M.a/0", "M.other/0"])

    scans = [spec(), code("M.a/0", {3, 4}), code("M.b/0", {5, 6}), extra, t1, t2]

    entries =
      for(
        c <- ["M.a/0", "M.b/0"],
        do: rel(:implements, {:code, c, "c-#{c}"}, {:spec, @unit, "s"})
      ) ++
        for t <- [t1, t2], do: rel(:verifies, {:test, t.id, t.hash}, {:spec, @unit, "s"})

    status = Status.derive(scans, entries, [], [])

    assert Status.deeper_test(status, "T: elsewhere", @unit) == %{
             test: "T: on the unit",
             more: 1,
             through: "M.b/0"
           }

    assert Status.deeper_test(status, "T: on the unit", @unit) == nil
  end
end
