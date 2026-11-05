defmodule Surfex.ClassedTableTest do
  # #291, #362: a table of what's deferred or isn't a goal is the opposite of a list of claims,
  # but marking it is the only way to cite a row. A class on the table's own marker keeps the
  # rows citable and out of the score.
  use ExUnit.Case, async: true
  @moduletag verifies: "table-class"

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @classes [{"plan", "records a plan; asserts nothing a test could fail on"}]

  defp text(marker, pin) do
    """
    # Later
    <!-- surfex: later -->

    #{marker}
    | Item | Why |
    |---|---|
    | views | past v1 |
    | sync | past v1 |

    # View abstraction
    <!-- surfex: views -->
    <!-- surfex: deferred spec.md#plan/views#{pin}: past v1 -->

    Views, later.
    """
  end

  defp sections(marker, pin) do
    Markdown.sections(text(marker, pin), "spec.md",
      spec_classes: Config.spec_classes!([spec_classes: @classes], ["spec.md"])
    )
  end

  # The deferral pins the row at the version its author judged (§13.13).
  defp scans(marker) do
    row = marker |> sections("") |> Enum.find(&(&1.id == "spec.md#plan/views"))
    sections(marker, "@#{row.hash}")
  end

  defp classed, do: scans("<!-- surfex: table plan class: plan -->")
  defp plain, do: scans("<!-- surfex: table plan -->")

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t-#{id}",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  test "a classed table's rows are units, excused rather than claims, and out of the score" do
    status = Status.derive(classed(), [], [])

    for id <- ~w(plan plan/views plan/sync) do
      assert Status.verdict(status, "spec.md##{id}") == :excused
    end

    assert [%{name: "plan", by: :marker}] =
             Enum.filter(status.excused, &(&1.unit == "spec.md#plan/views"))

    report = Completeness.report(status)
    assert "spec.md#plan/views" in report.excused

    without = Completeness.report(Status.derive(plain(), [], []))
    assert without.scores.spec.total > report.scores.spec.total
    assert "spec.md#plan/views" in Enum.map(without.incomplete, & &1.id)
    refute "spec.md#plan/views" in Enum.map(report.incomplete, & &1.id)
    refute Status.failing?(status)
  end

  test "a verifies to a classed table's row is contradicted, as for any excused unit" do
    status = Status.derive(classed() ++ [test_scan("T: views", ["plan/views"])], [], [])

    assert [%{type: :declares, from: "T: views", unit: "spec.md#plan/views"}] =
             status.contradicted

    assert Status.failing?(status)
    assert Report.text(status) =~ "spec.md#plan/views"
  end

  test "a deferral citing a classed table's row still defers its unit" do
    status = Status.derive(classed(), [], [])

    assert [%{unit: "spec.md#views", ref: "spec.md#plan/views"}] = status.deferred
    assert [] = status.stale_deferrals
    assert %{id: "spec.md#plan/views"} = Enum.find(classed(), &(&1.id == "spec.md#plan/views"))
  end

  test "classing a table changes no unit's version" do
    versions = fn scans -> Map.new(scans, &{&1.id, &1.hash}) end

    assert versions.(classed()) == versions.(plain())
  end

  test "a class the config doesn't declare is a scan error, naming it and its line" do
    error =
      assert_raise ArgumentError, fn -> scans("<!-- surfex: table plan class: nope -->") end

    assert error.message =~ "spec.md:4: class nope isn't declared in spec_classes:"
  end

  test "a class name that breaks the rule is a scan error, with the name to write" do
    error =
      assert_raise ArgumentError, fn -> scans("<!-- surfex: table plan class: my plan -->") end

    assert error.message =~ "`my plan` is not a class name"
    assert error.message =~ "write `my-plan`"
  end

  test "a class goes with key: and ignore: in either order, and once" do
    ok = scans("<!-- surfex: table plan class: plan key: Item ignore: Why -->")
    assert Enum.find(ok, &(&1.id == "spec.md#plan/views")).class.name == "plan"

    error =
      assert_raise ArgumentError, fn ->
        scans("<!-- surfex: table plan class: plan class: plan -->")
      end

    assert error.message =~ "table plan's marker gives class: twice"
  end
end
