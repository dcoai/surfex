defmodule Surfex.MigrateReportReadsTest do
  # #289, #375: reports of over a thousand lines, most of them repeats, for projects with many
  # sections or hints. What's worth reading is the ranking and what differs.
  use ExUnit.Case, async: true
  @moduletag verifies: "migrate-report-reads"

  alias Surfex.{Migrate, Status}
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Report

  defp width(codes, now, after_, outcome, callers \\ []),
    do: %{codes: codes, now: now, after: after_, outcome: outcome, callers: callers}

  defp section(id, widths, extra \\ %{}) do
    Map.merge(
      %{
        section: id,
        kind: :units,
        relations: 20,
        after: 10,
        marking: 0,
        implements: length(widths),
        single: 0,
        several: 0,
        none: 0,
        migrating: 0,
        widening: Enum.count(widths, &(&1.after > &1.now)),
        contained: [],
        contained_direct: [],
        contained_deeper: 0,
        widths: widths
      },
      extra
    )
  end

  defp report(sections) do
    %{
      sections: sections,
      population: %{
        units: %{sections: length(sections), implements: 3},
        prose: %{sections: 0, implements: 0},
        contained: %{sections: 0}
      }
    }
  end

  test "with no section named, one line per section comes first, then the detail" do
    lines =
      [section("spec.md#worst", [width(["M.a/0"], 20, 10, :single)]), section("spec.md#next", [])]
      |> report()
      |> Migrate.text()

    assert first =
             Enum.find_index(lines, &String.starts_with?(&1, "spec.md#worst (claims are units)"))

    assert Enum.at(lines, first + 1) =~ "spec.md#next (claims are units)"
    assert Enum.member?(lines, "spec.md#worst:")
    assert Enum.member?(lines, "  M.a/0: 20 now → 10 after (single)")
    assert Enum.find_index(lines, &(&1 == "spec.md#worst:")) > first + 1
  end

  test "a section named has no ranking to give: its line, then its detail" do
    assert [
             "spec.md#one (claims are units): " <> _,
             "  M.a/0: 20 now → 10 after (single)"
           ] =
             [section("spec.md#one", [width(["M.a/0"], 20, 10, :single)])]
             |> report()
             |> Migrate.text(named: true)
  end

  test "items that read the same collapse to one line, and --items shows them all" do
    same = for n <- 1..12, do: width(["M.f#{n}/0"], 153, 153, :none)
    named = &Migrate.text(report([section("spec.md#s", same)]), [named: true] ++ &1)

    assert ["spec.md#s" <> _, "  12 items: 153 now → 153 after (none)"] = named.([])
    assert length(named.(items: true)) == 13

    # One that differs keeps them apart, and one item is never "1 items".
    differs = [width(["M.a/0"], 5, 2, :single), width(["M.b/0"], 5, 3, :single)]

    assert [_, "  M.a/0: 5 now → 2 after (single)", "  M.b/0: 5 now → 3 after (single)"] =
             Migrate.text(report([section("spec.md#s", differs)]), named: true)

    assert [_, "  M.a/0: 5 now → 2 after (single)"] =
             Migrate.text(report([section("spec.md#s", tl(Enum.reverse(differs)))]), named: true)
  end

  test "a widening move is flagged where it's listed and counted on its section's line" do
    lines =
      Migrate.text(report([section("spec.md#s", [width(["M.a/0"], 13, 14, :several)])]),
        named: true
      )

    assert [head, item] = lines
    assert head =~ "· 1 widen"

    assert item ==
             "  M.a/0: 13 now → 14 after (several, widens: the claims it could go to hold more)"
  end

  test "a contained line names the direct claims and counts the rest" do
    lines =
      [
        section("spec.md#ch", [], %{
          contained: ~w(a b c),
          contained_direct: ["spec.md#a"],
          contained_deeper: 2
        })
      ]
      |> report()
      |> Migrate.text(named: true)

    assert "  contained: spec.md#a + 2 in subsections verified inside, its own text isn't" in lines
  end

  test "status and the report's data hold the direct claims and the deeper count" do
    text = """
    # Chapter
    <!-- surfex: chapter -->

    Chapter prose.

    ```test:direct
    a direct hint
    ```

    ## Part
    <!-- surfex: part -->

    ```test:deep-one
    one
    ```

    ```test:deep-two
    two
    ```
    """

    spec = Markdown.sections(text, "spec.md")
    id = &"spec.md##{&1}"

    tagged =
      for {t, unit} <- [{"T: d", "direct"}, {"T: 1", "deep-one"}, {"T: 2", "deep-two"}] do
        %Surfex.Scan{
          kind: :test,
          id: t,
          hash: "h-#{t}",
          declares: [{:verifies, id.(unit)}],
          location: %{file: "test/a_test.exs", lines: {1, 2}}
        }
      end

    entries =
      for %{id: t, hash: h, declares: [{:verifies, unit}]} <- tagged do
        hint = Enum.find(spec, &(&1.id == unit))

        Surfex.Log.Entry.new!(
          at: "2026-11-06T10:00:00Z",
          op: :relate,
          type: :verifies,
          basis: :review,
          note: "checked",
          ends: [%{kind: :test, id: t, hash: h}, %{kind: :spec, id: unit, hash: hint.hash}]
        )
      end

    status = Status.derive(spec ++ tagged, entries, [], [])

    assert %{inside: inside, direct: [direct], deeper: 2} =
             Enum.find(status.contained, &(&1.unit == id.("chapter")))

    assert length(inside) == 3
    assert direct == id.("direct")
    assert Report.text(status) =~ "verified inside: spec.md#direct + 2 in subsections"

    assert %{sections: [%{contained_direct: [^direct], contained_deeper: 2}]} =
             Migrate.report(spec ++ tagged, entries, [id.("chapter")])

    [json] =
      (spec ++ tagged)
      |> Migrate.report(entries, [id.("chapter")])
      |> Migrate.json()
      |> JSON.decode!()
      |> Map.fetch!("sections")

    assert json["contained_deeper"] == 2 and json["widening"] == 0
  end
end
