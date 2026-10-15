defmodule Surfex.ClassedStatusTest do
  # #265 (C.2 part 2): what a spec class and a deferral change in the status (§13.6,
  # §15.2, §20.2).
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Item, Scan, Status, Suggest}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @classes [
    {"informative", "asserts nothing a test could fail on"},
    {"architecture", "orientation", headings: ~r/^Architecture$/}
  ]

  @spec_text """
  # Architecture
  <!-- surfex: arch -->

  The module map.

  <!-- surfex: arch-rule -->
  Every write goes through the gate.

  <!-- surfex: table arch-table -->
  | Key | Value |
  |---|---|
  | a | 1 |

  ```test:arch-hint
  the gate refuses a write without a token
  ```

  <!-- surfex: contract module: MyApp.Feed -->
  ```elixir
  @spec feed(t) :: t
  ```

  <!-- surfex: arch-block -->
  A block requirement.
  <!-- /surfex -->

  ## Layers

  Layer text.

  # Background
  <!-- surfex: background -->
  <!-- surfex: class informative -->

  History only.

  # Views
  <!-- surfex: views -->
  <!-- surfex: deferred #12: past v1 -->

  Views later.

  # Gate
  <!-- surfex: gate -->

  Gate prose.

  <!-- surfex: gate-block -->
  <!-- surfex: deferred #13 -->
  The gate block.
  <!-- /surfex -->
  """

  @at "2026-10-14T10:00:00Z"

  defp spec(classes \\ @classes) do
    Markdown.sections(@spec_text, "spec.md",
      spec_classes: Config.spec_classes!([spec_classes: classes], ["spec.md"])
    )
  end

  defp code(id),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "c-#{id}",
      role: :function,
      location: %{file: "lib/m.ex", lines: {1, 2}}
    }

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t-#{id}",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp end_of(%Scan{kind: kind, id: id, hash: hash}), do: %{kind: kind, id: id, hash: hash}

  defp relate(type, a, b),
    do:
      Entry.new!(
        at: @at,
        op: :relate,
        type: type,
        basis: :review,
        by: "t",
        note: "checked",
        ends: [end_of(a), end_of(b)]
      )

  defp retire(%Entry{} = e),
    do:
      Entry.new!(
        at: "2026-10-14T11:00:00Z",
        op: :retire,
        type: e.type,
        note: "narration, not a claim",
        ends: e.ends,
        parents: [e.id]
      )

  defp unit(scans, id), do: Enum.find(scans, &(&1.id == "spec.md##{id}")) || flunk("no #{id}")

  defp derive(scans, entries, require), do: Status.derive(scans, entries, require)

  defp unmet(status), do: status.unmet |> Enum.map(& &1.scan.id) |> Enum.sort()

  @tag verifies: ["classed-claims-stay", "classed-units"]
  test "a class excuses a section's own text, never a named claim inside it" do
    scans = spec()
    status = derive(scans, [], spec: [:verifies])

    # Classed by pattern, with claims inside: a container. With none: excused.
    assert Status.verdict(status, "spec.md#arch") == :through_claims
    assert Status.verdict(status, "spec.md#background") == :excused
    assert unit(scans, "arch").class.by == :pattern

    claims =
      ~w(arch-rule arch-table/a arch-hint MyApp.Feed.feed/1 arch-block Architecture/Layers)
      |> Enum.map(&"spec.md##{&1}")

    for claim <- claims, do: assert(Status.verdict(status, claim) == :unverified)
    assert claims -- unmet(status) == []
    refute "spec.md#arch" in unmet(status)
    refute "spec.md#background" in unmet(status)

    # A claim inside answers for itself once a test verifies it.
    t = test_scan("T: rule", ["arch-rule"])

    verified =
      derive(
        scans ++ [t],
        [relate(:verifies, t, unit(scans, "arch-rule"))],
        spec: [:verifies]
      )

    assert Status.verdict(verified, "spec.md#arch-rule") == :verified
    refute "spec.md#arch-rule" in unmet(verified)

    assert Enum.map(status.excused, & &1.unit) == ["spec.md#arch", "spec.md#background"]

    assert %{claims: inside} = Enum.find(status.excused, &(&1.unit == "spec.md#arch"))
    assert "spec.md#arch-rule" in inside

    text = Report.text(status)
    assert text =~ "excused by class: 2 (1 with claims inside) · deferred: 2"
    json = JSON.decode!(Report.json(status))

    assert [%{"unit" => "spec.md#arch", "by" => "pattern"}, %{"class" => "informative"}] =
             json["excused"]
  end

  @tag verifies: ["contradicted-relations", "classed-units"]
  test "a relation to an excused section is contradicted and fails until settled" do
    scans = spec()
    x = code("MyApp.X.f/1")
    y = code("MyApp.Y.g/1")
    t = test_scan("T: background", ["background"])
    d = test_scan("T: declares", ["background"])
    world = scans ++ [x, y, t, d]
    background = unit(scans, "background")

    entries = [
      relate(:implements, x, background),
      relate(:implements, y, unit(scans, "arch")),
      relate(:verifies, t, background)
    ]

    status = derive(world, entries, [])

    assert status.contradicted == [
             %{type: :declares, from: "T: declares", unit: "spec.md#background"},
             %{type: :implements, from: "MyApp.X.f/1", unit: "spec.md#background"},
             %{type: :verifies, from: "T: background", unit: "spec.md#background"}
           ]

    assert Status.failing?(status)

    assert Report.text(status) =~
             "implements  code MyApp.X.f/1 → spec spec.md#background, which its class excuses"

    assert length(JSON.decode!(Report.json(status))["contradicted"]) == 3

    # Retiring the relations, and dropping the tags that declare the section, clears it.
    retired = entries ++ [retire(Enum.at(entries, 0)), retire(Enum.at(entries, 2))]
    settled = derive(scans ++ [x, y], retired, [])
    assert settled.contradicted == []

    # Removing the class clears it too.
    unclassed = Enum.map(world, &if(&1.id == background.id, do: %{&1 | class: nil}, else: &1))
    assert derive(unclassed, entries, []).contradicted == []
  end

  @tag verifies: ["deferred-units", "classed-units"]
  test "a deferred section and block are listed, not judged, and earn nothing" do
    scans = spec()
    x = code("MyApp.V.view/1")
    implements = relate(:implements, x, unit(scans, "views"))
    status = derive(scans ++ [x], [implements], spec: [:verifies])

    assert Status.verdict(status, "spec.md#views") == :deferred
    assert Status.verdict(status, "spec.md#gate-block") == :deferred

    assert [
             %{unit: "spec.md#gate-block", ref: "#13", reason: nil},
             %{unit: "spec.md#views", ref: "#12", reason: "past v1"}
           ] = status.deferred

    refute "spec.md#views" in unmet(status)
    refute "spec.md#gate-block" in unmet(status)
    assert "spec.md#gate" in unmet(status)

    [relation] = Enum.filter(status.relations, &(&1.type == :implements))
    assert Status.earning(status, relation) == {:unearned, :unverified}
    assert [%{"ref" => "#12"} | _] = Enum.reverse(JSON.decode!(Report.json(status))["deferred"])
  end

  @tag :tmp_dir
  @tag verifies: ["classed-citations", "classed-suggestions"]
  test "a classed section's citations propose no implements, and are still checked", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "spec.md"), """
    # Map
    <!-- surfex: class informative -->

    `Wren.send/3` sends, and `Wren.gone/0` is no more.

    # Sending

    `Wren.send/3` sends.
    """)

    items = [
      %Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "00000001"}
    ]

    config = [sources: ["spec.md"], spec_classes: [{"informative", "orientation"}]]
    profile = Config.profile!(config, "Wren")

    spec =
      Markdown.records(root, ["spec.md"], [],
        spec_classes: Config.spec_classes!(config, ["spec.md"])
      )

    t = test_scan("T: map", ["Map"])
    scans = spec ++ Scan.code(items) ++ [t]

    pairs = fn s -> s.implements |> Enum.map(&{&1.spec.id, &1.code.id}) |> Enum.sort() end
    verifies = fn s -> Enum.map(s.verifies, & &1.to.id) end

    classed = Suggest.all(profile, items, scans, [], root)
    assert pairs.(classed) == [{"spec.md#Sending", "Wren.send/3"}]
    assert verifies.(classed) == []

    # The same citation unclassed is suggested.
    unclassed = Enum.map(scans, &%{&1 | class: nil})
    plain = Suggest.all(profile, items, unclassed, [], root)
    assert {"spec.md#Map", "Wren.send/3"} in pairs.(plain)
    assert verifies.(plain) == ["spec.md#Map"]

    # Still checked: the broken citation in the classed text is reported.
    broken = Config.broken_citations(config, items, root, "Wren")
    assert Enum.any?(broken, &(&1.section =~ "Map" and &1.span =~ "gone"))
  end

  @tag verifies: ["classed-goldens", "classed-record"]
  test "the status golden lists excusals by unit, counted, and moves only with them" do
    scans = spec()
    render = fn scans -> Surfex.Golden.render(Report.golden(derive(scans, [], []))) end
    golden = render.(scans)

    assert golden =~ "## excused"
    assert golden =~ "| `spec spec.md#arch` | `architecture` | pattern |"
    assert golden =~ "| `spec spec.md#background` | `informative` | marker |"
    assert golden =~ "## deferred"
    assert golden =~ "| `spec spec.md#gate-block` | #13 |"
    assert golden =~ "excused 2"
    assert golden =~ "deferred 2"

    # In id order whatever the scan order.
    assert render.(Enum.reverse(scans)) == golden

    # Changes only when a class does: dropping one class drops its row and count.
    unclassed =
      Enum.map(scans, &if(&1.id == "spec.md#background", do: %{&1 | class: nil}, else: &1))

    changed = render.(unclassed)
    refute changed =~ "spec.md#background` | `informative`"
    assert changed =~ "excused 1"

    # A spec with neither renders as before: no tables, no counts.
    plain = Enum.map(scans, &%{&1 | class: nil, deferred: nil})
    refute render.(plain) =~ "## excused"
    refute render.(plain) =~ "excused 0"

    header =
      derive(scans, [], [])
      |> Completeness.report()
      |> Completeness.golden("COMPLETENESS.md")
      |> Surfex.Golden.render()

    assert header =~ "excused by class 1"
    assert header =~ "deferred 2"
  end

  @tag verifies: ["guide-classes", "guide-unverified-text"]
  test "the guide says how to treat text the spec doesn't verify" do
    guide = File.read!(Path.expand("../../guides/writing-specs.md", __DIR__))
    [_, section] = String.split(guide, "### Text the spec doesn't verify", parts: 2)
    [section | _] = String.split(section, "\n## 9.", parts: 2)

    assert guide =~ "## 8. Code the spec doesn't describe"
    assert section =~ "A class never hides a named claim"
    assert section =~ "check"
    assert section =~ "deferred"
    assert section =~ "spec_classes:"
  end

  @tag verifies: ["classed-completeness", "classed-score"]
  test "excused and deferred units are out of the score, counted on their own lines" do
    scans = spec()
    report = Completeness.report(derive(scans, [], []))

    assert report.excused == ["spec.md#background"]

    assert report.deferred == [
             %{unit: "spec.md#gate-block", ref: "#13"},
             %{unit: "spec.md#views", ref: "#12"}
           ]

    ids = Enum.map(report.incomplete, & &1.id)
    refute "spec.md#background" in ids or "spec.md#views" in ids
    assert "spec.md#arch-rule" in ids

    text = Completeness.text(report)
    assert text =~ "  excused by class: 1 spec units, out of the score\n"
    assert text =~ "  deferred: 2 spec units (#12, #13), out of the score\n"
    json = JSON.decode!(Completeness.json(report))
    assert json["excused"] == ["spec.md#background"] and length(json["deferred"]) == 2

    # Unclassed and undeferred, the same units are counted.
    before =
      Completeness.report(derive(Enum.map(scans, &%{&1 | class: nil, deferred: nil}), [], []))

    assert before.excused == [] and before.deferred == []
    assert "spec.md#background" in Enum.map(before.incomplete, & &1.id)
    assert before.scores.spec.total > report.scores.spec.total
    refute Completeness.text(before) =~ "excused by class"
  end
end
