# Defined before the test module: async tests start as soon as their module is loaded,
# so a module defined later in this file might not exist yet when they run.
defmodule Surfex.StatusTest.OneScanner do
  @moduledoc false
  # A project scanner, as a project would write one.
  @behaviour Surfex.Scanner

  @impl true
  def items(_root, _opts),
    do: [%Surfex.Item{kind: :function, name: "one", file: "one.c", hash: "1"}]
end

defmodule Surfex.StatusTest do
  use ExUnit.Case, async: true

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.Report

  @spec_id "spec.md#Carts/Adding items"
  @code_id "M.add/2"

  defp scan(kind, id, hash),
    do: %Scan{kind: kind, id: id, hash: hash, location: %{file: "f", lines: {1, 2}}}

  defp scans(spec_hash \\ "s1", code_hash \\ "c1"),
    do: [scan(:spec, @spec_id, spec_hash), scan(:code, @code_id, code_hash)]

  defp relate(spec_hash, code_hash, extra \\ []) do
    Entry.new!(
      at: Keyword.get(extra, :at, "2026-09-28T10:00:00Z"),
      op: Keyword.get(extra, :op, :relate),
      type: :implements,
      parents: Keyword.get(extra, :parents, []),
      ends: [
        %{kind: :spec, id: @spec_id, hash: spec_hash},
        %{kind: :code, id: @code_id, hash: code_hash}
      ],
      note: Keyword.get(extra, :note)
    )
  end

  defp only(status), do: hd(status.relations)

  describe "a relation's state comes from its tip" do
    @describetag verifies: "status-states"

    test "current: both ends at the recorded hashes" do
      assert %{state: :current, changed: []} = only(Status.derive(scans(), [relate("s1", "c1")]))
    end

    @tag verifies: "dangling-side"
    test "dangling, naming which end changed" do
      assert %{state: :dangling, changed: [{:code, @code_id}]} =
               only(Status.derive(scans("s1", "c2"), [relate("s1", "c1")]))

      assert %{state: :dangling, changed: [{:spec, @spec_id}]} =
               only(Status.derive(scans("s2", "c1"), [relate("s1", "c1")]))
    end

    test "orphaned: an end is no longer scanned" do
      status = Status.derive([scan(:spec, @spec_id, "s1")], [relate("s1", "c1")])
      assert %{state: :orphaned, changed: [{:code, @code_id}]} = only(status)
    end

    test "a later confirmation supersedes an earlier one" do
      first = relate("s1", "c1")
      second = relate("s1", "c2", parents: [first.id], at: "2026-09-28T11:00:00Z")

      assert %{state: :current, tips: [^second]} =
               only(Status.derive(scans("s1", "c2"), [first, second]))
    end

    test "retired: the tip retires it" do
      first = relate("s1", "c1")
      retired = relate("s1", "c1", op: :retire, parents: [first.id], at: "2026-09-28T11:00:00Z")
      assert %{state: :retired} = only(Status.derive(scans("s9", "c9"), [first, retired]))
    end

    test "conflicted: two entries sharing a parent, or two roots" do
      base = relate("s1", "c1")
      a = relate("s1", "c2", parents: [base.id], at: "2026-09-28T11:00:00Z", note: "a")
      b = relate("s1", "c2", parents: [base.id], at: "2026-09-28T11:00:01Z", note: "b")

      assert %{state: :conflicted, tips: [^a, ^b]} =
               only(Status.derive(scans("s1", "c2"), [base, a, b]))

      roots = [relate("s1", "c1", note: "one"), relate("s1", "c1", note: "two")]
      assert %{state: :conflicted} = only(Status.derive(scans(), roots))
    end

    test "a resolution naming both tips ends the conflict" do
      base = relate("s1", "c1")
      a = relate("s1", "c2", parents: [base.id], note: "a")
      b = relate("s1", "c2", parents: [base.id], note: "b")
      fix = relate("s1", "c2", parents: [a.id, b.id], at: "2026-09-28T12:00:00Z")

      assert %{state: :current, tips: [^fix]} =
               only(Status.derive(scans("s1", "c2"), [base, a, b, fix]))
    end
  end

  @tag verifies: "status-states"
  test "impacted: an end depends on something not current" do
    helper = scan(:code, "M.helper/1", "h2")

    depends =
      Entry.new!(
        at: "2026-09-28T10:00:00Z",
        op: :relate,
        type: :depends_on,
        ends: [
          %{kind: :code, id: @code_id, hash: "c1"},
          %{kind: :code, id: "M.helper/1", hash: "h1"}
        ]
      )

    status = Status.derive([helper | scans()], [relate("s1", "c1"), depends])
    implements = Enum.find(status.relations, &(&1.type == :implements))
    dependency = Enum.find(status.relations, &(&1.type == :depends_on))

    assert %{state: :current, impacted: true} = implements
    assert %{state: :dangling, impacted: false} = dependency
    # A directed type keeps its ends in the order given: from, then to.
    assert {:depends_on, {:code, @code_id}, {:code, "M.helper/1"}} = dependency.relation
  end

  @tag verifies: "status-states"
  test "new: a scanned id in no relation" do
    status = Status.derive([scan(:code, "M.other/0", "o") | scans()], [relate("s1", "c1")])
    assert [%Scan{id: "M.other/0"}] = status.new
  end

  describe "policy" do
    @describetag verifies: "status-states"

    @tag verifies: ["status-failing"]
    test "an id the policy requires to be related, and isn't, is unmet" do
      extra = scan(:code, "M.other/0", "o")
      status = Status.derive([extra | scans()], [relate("s1", "c1")], code: [:implements])
      assert [%{scan: ^extra, requires: [:implements]}] = status.unmet
      assert Status.failing?(status)
    end

    test "a retired relation doesn't meet it" do
      first = relate("s1", "c1")
      retired = relate("s1", "c1", op: :retire, parents: [first.id], at: "2026-09-28T11:00:00Z")

      assert [_, _] =
               Status.derive(scans(), [first, retired], code: [:implements], spec: [:implements]).unmet
    end
  end

  # #38: tests declare what they verify; a declaration naming nothing fails.
  describe "declarations and role rules" do
    @describetag verifies: "status-states"

    defp hint(id), do: %{scan(:spec, "spec.md##{id}", "h1") | role: :test_hint, within: @spec_id}
    defp test_scan(declares), do: %{scan(:test, "T: a", "t1") | declares: declares}

    @tag verifies: ["status-failing"]
    test "a declaration naming no spec unit, or an ambiguous one, is broken and fails" do
      status = Status.derive([test_scan([{:verifies, "nothing"}]) | scans()], [])
      assert [%{type: :verifies, ref: "nothing", reason: :unknown}] = status.broken
      assert Status.failing?(status)
      assert Report.text(status) =~ ~s(test T: a verifies "nothing": no spec unit has that id)

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})

      assert [%{"id" => "T: a", "ref" => "nothing", "declares" => [%{"type" => "verifies"}]}] =
               json["broken"]

      assert status |> Report.golden() |> Surfex.Golden.render() =~ "## broken"

      fine = Status.derive([hint("h"), test_scan([{:verifies, "h"}]) | scans()], [])
      assert fine.broken == []
    end

    # #66: a claim the test's source no longer makes must not stay current.
    @tag verifies: "undeclared-verifies"
    test "a verifies relation the test no longer declares is undeclared, and fails" do
      verified =
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: :verifies,
          ends: [
            %{kind: :test, id: "T: a", hash: "t1"},
            %{kind: :spec, id: "spec.md#h", hash: "h1"}
          ]
        )

      declared = Status.derive([hint("h"), test_scan([{:verifies, "h"}]) | scans()], [verified])
      assert declared.undeclared == []

      dropped = Status.derive([hint("h"), test_scan([]) | scans()], [verified])
      assert dropped.undeclared == [%{test: "T: a", spec: "spec.md#h"}]
      assert Status.failing?(dropped)
      assert Report.text(dropped) =~ "Undeclared (a test no longer declares what it verifies)"
    end

    test "a role's rule applies to units in that role only, alongside the kind's" do
      require = [test_hint: [:verifies]]
      status = Status.derive([hint("h") | scans()], [], require)
      assert [%{scan: %{id: "spec.md#h"}, requires: [:verifies]}] = status.unmet

      verified =
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: :verifies,
          ends: [
            %{kind: :test, id: "T: a", hash: "t1"},
            %{kind: :spec, id: "spec.md#h", hash: "h1"}
          ]
        )

      assert Status.derive([hint("h"), test_scan([]) | scans()], [verified], require).unmet == []

      # With a kind rule too, each rule it fails is its own entry.
      both = Status.derive([hint("h") | scans()], [], spec: [:implements], test_hint: [:verifies])
      assert [[:implements], [:implements], [:verifies]] = Enum.map(both.unmet, & &1.requires)
    end
  end

  # #38: spec ↔ code (implements), test → spec (verifies), test → code (tests).
  describe "the triangle" do
    @describetag verifies: "triangle-gaps"

    defp rel(type, {ak, aid, ah}, {bk, bid, bh}),
      do:
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: type,
          ends: [%{kind: ak, id: aid, hash: ah}, %{kind: bk, id: bid, hash: bh}]
        )

    @t {:test, "T: a", "t1"}
    @s {:spec, @spec_id, "s1"}
    @c {:code, @code_id, "c1"}
    @other {:code, "M.other/0", "o1"}

    defp tri_scans, do: [scan(:test, "T: a", "t1"), scan(:code, "M.other/0", "o1") | scans()]
    defp gaps(entries, opts \\ []), do: Status.derive(tri_scans(), entries, [], opts).triangle

    test "closed: the test verifies the spec and exercises its code" do
      assert gaps([rel(:implements, @s, @c), rel(:verifies, @t, @s), rel(:tests, @t, @c)]) == []
    end

    @tag verifies: "triangle-gaps"
    test "each open side is named" do
      assert [%{gap: :no_test, spec: @spec_id}] = gaps([rel(:implements, @s, @c)])

      assert [%{gap: :test_misses_code, test: "T: a"}, %{gap: :code_untested, code: @code_id}] =
               gaps([rel(:implements, @s, @c), rel(:verifies, @t, @s), rel(:tests, @t, @other)])
    end

    # #62: a function with a default argument is one code, whatever arity a test calls.
    test "a test calling one arity of a function exercises the arity a section names" do
      two = %{scan(:code, "M.add/2", "c1") | location: %{file: "lib/m.ex", lines: {3, 5}}}
      three = %{two | id: "M.add/3"}
      scans = [scan(:test, "T: a", "t1"), scan(:spec, @spec_id, "s1"), two, three]

      entries = [
        rel(:implements, @s, {:code, "M.add/3", "c1"}),
        rel(:verifies, @t, @s),
        rel(:tests, @t, {:code, "M.add/2", "c1"})
      ]

      assert Status.derive(scans, entries).triangle == []
      assert Scan.definition(two) == Scan.definition(three)
      refute Scan.definition(two) == Scan.definition(%{three | hash: "c2"})
    end

    test "a test verifying a block or hint inside the section counts for it" do
      hint = %{scan(:spec, "spec.md#h", "h1") | role: :test_hint, within: @spec_id}

      entries = [
        rel(:implements, @s, @c),
        rel(:verifies, @t, {:spec, "spec.md#h", "h1"}),
        rel(:tests, @t, @c)
      ]

      assert Status.derive([hint | tri_scans()], entries).triangle == []
    end

    @tag verifies: ["status-failing"]
    test "reported by default, failing with triangle: :fail, and silent without tests" do
      entries = [rel(:implements, @s, @c)]
      refute Status.failing?(Status.derive(tri_scans(), entries))
      assert Status.failing?(Status.derive(tri_scans(), entries, [], triangle: :fail))
      assert Status.derive(scans(), entries).triangle == []

      status = Status.derive(tri_scans(), entries)

      assert Report.text(status) =~
               "Triangle (a spec unit, its tests and its code don't meet):\n  spec #{@spec_id}: no test verifies it"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert [%{"spec" => @spec_id, "gap" => "no_test", "test" => nil}] = json["triangle"]
      assert status |> Report.golden() |> Surfex.Golden.render() =~ "## triangle"
    end
  end

  describe "planned relations" do
    @describetag verifies: "planned-state"

    # The spec section exists; the code it will be implemented by doesn't yet.
    defp plan(extra \\ []) do
      Entry.new!(
        at: Keyword.get(extra, :at, "2026-09-28T10:00:00Z"),
        op: :relate,
        type: :implements,
        parents: Keyword.get(extra, :parents, []),
        ends: [
          %{kind: :spec, id: @spec_id, hash: "s1"},
          %{kind: :code, id: "M.later/1", hash: nil}
        ]
      )
    end

    defp spec_only, do: [scan(:spec, @spec_id, "s1")]

    @tag verifies: ["status-failing"]
    test "planned while the end doesn't exist, not orphaned, and not failing" do
      status = Status.derive(spec_only(), [plan()])
      assert %{state: :planned, changed: [{:code, "M.later/1"}]} = only(status)
      refute Status.failing?(status)
    end

    test "dangling on that end once it exists" do
      status = Status.derive([scan(:code, "M.later/1", "l1") | spec_only()], [plan()])
      assert %{state: :dangling, changed: [{:code, "M.later/1"}]} = only(status)
    end

    test "a spec end recorded at a hash and gone is still orphaned" do
      assert %{state: :orphaned, changed: [{:spec, @spec_id}]} = only(Status.derive([], [plan()]))
    end

    test "it meets the require policy, and its section is unimplemented" do
      status = Status.derive(spec_only(), [plan()], spec: [:implements])
      assert status.unmet == []
      assert [%Scan{id: @spec_id}] = status.unimplemented

      # Implemented by something real as well: no longer unimplemented.
      real = relate("s1", "c1")
      assert Status.derive(scans(), [plan(), real]).unimplemented == []
    end

    @tag verifies: ["status-failing"]
    test "planned: :fail makes it fail, as mix surfex.status --no-planned does" do
      assert Status.failing?(Status.derive(spec_only(), [plan()], [], planned: :fail))
      refute Status.failing?(Status.derive(scans(), [relate("s1", "c1")], [], planned: :fail))

      assert_raise ArgumentError, ~r/planned: must be :allow or :fail/, fn ->
        Status.derive(spec_only(), [plan()], [], planned: :maybe)
      end
    end

    test "the reports show it" do
      status = Status.derive(spec_only(), [plan()])

      assert Report.text(status) =~
               "Planned (an end doesn't exist yet):\n  implements  code M.later/1 ↔ spec #{@spec_id} (planned: M.later/1)"

      assert Report.text(status) =~
               "Unimplemented (every implements relation is planned):\n  spec #{@spec_id}"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert [%{"id" => @spec_id}] = json["unimplemented"]
      [relation] = json["relations"]
      code = Enum.find(relation["ends"], &(&1["kind"] == "code"))
      assert %{"recorded" => nil, "now" => nil, "planned" => true, "changed" => false} = code

      golden = status |> Report.golden() |> Surfex.Golden.render()
      assert golden =~ "planned 1"
      assert golden =~ "## unimplemented"
    end
  end

  # #73: the spec itself needs to change.
  describe "marks" do
    @describetag verifies: "mark-states"

    defp mark(hash, extra \\ []) do
      Entry.new!(
        [
          at: "2026-09-28T10:00:00Z",
          op: :mark,
          type: :needs_update,
          ends: [%{kind: :spec, id: @spec_id, hash: hash}],
          note: "adding is too slow in use",
          by: "tester"
        ] ++ extra
      )
    end

    defp withdraw(mark),
      do:
        Entry.new!(
          at: "2026-09-28T11:00:00Z",
          op: :retire,
          type: :needs_update,
          ends: mark.ends,
          parents: [mark.id],
          note: "unfounded"
        )

    test "open at the marked version, resolved when the unit changes, withdrawn, orphaned" do
      m = mark("s1")

      assert [%{state: :open, unit: @spec_id, id: id, note: "adding is too slow in use"}] =
               Status.derive(scans(), [relate("s1", "c1"), m]).marks

      assert id == m.id
      # The spec changed: the mark is resolved, and no longer reported.
      assert Status.derive(scans("s2", "c1"), [m]).marks == []
      assert Status.derive(scans(), [m, withdraw(m)]).marks == []
      assert [%{state: :orphaned}] = Status.derive([scan(:code, @code_id, "c1")], [m]).marks

      # A mark is not a relation: it adds none, and the unit it names is still new.
      status = Status.derive(scans(), [m])
      assert status.relations == []
      assert Enum.any?(status.new, &(&1.id == @spec_id))
    end

    test "each mark is its own: two on one unit, one withdrawn, leaves the other open" do
      a = mark("s1")
      b = mark("s1", note: "and it reads oddly", at: "2026-09-28T10:30:00Z")
      assert [%{id: id}] = Status.derive(scans(), [a, b, withdraw(a)]).marks
      assert id == b.id
    end

    test "marks don't fail by default; marks: :fail fails on open and orphaned ones" do
      m = mark("s1")
      refute Status.failing?(Status.derive(scans(), [relate("s1", "c1"), m]))
      assert Status.failing?(Status.derive(scans(), [relate("s1", "c1"), m], [], marks: :fail))

      assert Status.failing?(Status.derive([scan(:code, @code_id, "c1")], [m], [], marks: :fail))

      refute Status.failing?(Status.derive(scans("s2", "c1"), [m], [], marks: :fail))

      assert_raise ArgumentError, ~r/marks: must be :allow or :fail/, fn ->
        Status.derive(scans(), [m], [], marks: :loud)
      end
    end

    @tag verifies: "status-report-forms"
    test "all three reports show open marks" do
      status = Status.derive(scans(), [relate("s1", "c1"), mark("s1")])

      assert Report.text(status) =~
               "Marked (the spec needs an update):\n  spec #{@spec_id} (f:1-2): adding is too slow in use (tester, 2026-09-28T10:00:00Z)"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})

      assert [
               %{
                 "unit" => @spec_id,
                 "state" => "open",
                 "note" => "adding is too slow in use",
                 "by" => "tester",
                 "at" => "2026-09-28T10:00:00Z",
                 "location" => %{"file" => "f", "lines" => [1, 2]}
               }
             ] = json["marks"]

      golden = status |> Report.golden() |> Surfex.Golden.render()
      assert golden =~ "## marks"
      assert golden =~ "adding is too slow in use"
      refute golden =~ "2026-09-28"
    end
  end

  @tag verifies: ["status-pure", "status-failing"]
  test "failing: each failing state, and nothing else by default; planned: :fail and validated: true add theirs" do
    ok = relate("s1", "c1")
    fails = &Status.failing?(Status.derive(&1, &2))
    fails_with = &Status.failing?(Status.derive(&1, &2, [], &3))

    # A current relation passes, and so do new, retired and unvalidated ones.
    refute fails.(scans(), [ok])
    refute fails.([scan(:code, "M.x/0", "x") | scans()], [ok])
    retired = relate("s1", "c1", op: :retire, parents: [ok.id], at: "2026-09-28T11:00:00Z")
    refute fails.(scans("s9", "c9"), [ok, retired])

    # Impacted needs a dependency that isn't current, which fails on its own; its flag is
    # checked in its own test.

    # Dangling, orphaned, conflicted and proposed fail.
    assert fails.(scans("s1", "c2"), [ok])
    assert fails.([scan(:spec, @spec_id, "s1")], [ok])
    assert fails.(scans(), [relate("s1", "c1", note: "one"), relate("s1", "c1", note: "two")])

    proposed =
      Entry.new!(at: ok.at, op: :relate, type: :implements, ends: ok.ends, basis: :proposed)

    assert fails.(scans(), [proposed])

    # So does an unmet id, under a require: policy.
    assert Status.failing?(Status.derive(scans(), [], code: [:implements]))

    # A planned relation passes, unless planned: :fail.
    planned =
      Entry.new!(
        at: ok.at,
        op: :relate,
        type: :implements,
        ends: [
          %{kind: :spec, id: @spec_id, hash: "s1"},
          %{kind: :code, id: "M.later/1", hash: nil}
        ]
      )

    refute fails.(scans(), [ok, planned])
    assert fails_with.(scans(), [ok, planned], planned: :fail)

    # A current relation with no validating basis passes, unless validated: true.
    refute fails.(scans(), [ok])
    assert fails_with.(scans(), [ok], validated: true)

    validated =
      Entry.new!(at: ok.at, op: :relate, type: :implements, ends: ok.ends, basis: :review)

    refute fails_with.(scans(), [validated], validated: true)
  end

  describe "the report" do
    @describetag verifies: "status-report-forms"

    test "text names the verdict, the counts, and each relation needing attention" do
      text = Report.text(Status.derive(scans("s1", "c2"), [relate("s1", "c1")]))
      assert text =~ "relation status: FAILING"
      assert text =~ "  implements: dangling 1"

      assert text =~
               "implements  code M.add/2 ↔ spec spec.md#Carts/Adding items (changed: M.add/2 (f:1-2))"
    end

    test "JSON is the work list: recorded and current hashes, which end changed, where" do
      json = Report.json(Status.derive(scans("s1", "c2"), [relate("s1", "c1")])) |> :json.decode()
      assert json["failing"] == true
      assert json["summary"] == %{"implements" => %{"dangling" => 1}}
      [relation] = json["relations"]
      code = Enum.find(relation["ends"], &(&1["kind"] == "code"))

      assert code == %{
               "kind" => "code",
               "id" => "M.add/2",
               "recorded" => "c1",
               "now" => "c2",
               "changed" => true,
               "planned" => false,
               "location" => %{"file" => "f", "lines" => [1, 2]}
             }
    end

    # #47: absent values are JSON null, never the string "nil".
    test "JSON: a gone end's hash and location, and a conflict's recorded hashes, are null" do
      decode = &(&1 |> Report.json() |> :json.decode(:ok, %{null: nil}) |> elem(0))

      orphaned = decode.(Status.derive([scan(:spec, @spec_id, "s1")], [relate("s1", "c1")]))
      [%{"ends" => ends}] = orphaned["relations"]

      assert %{"now" => nil, "location" => nil, "recorded" => "c1"} =
               Enum.find(ends, &(&1["kind"] == "code"))

      a = relate("s1", "c1")
      b = relate("s1", "c2", at: "2026-09-28T11:00:00Z")

      [%{"state" => "conflicted", "ends" => ends}] =
        decode.(Status.derive(scans(), [a, b]))["relations"]

      assert Enum.all?(ends, &(&1["recorded"] == nil))
    end

    test "JSON: no state writes the string \"nil\"" do
      first = relate("s1", "c1")
      retired = relate("s1", "c1", op: :retire, parents: [first.id], at: "2026-09-28T11:00:00Z")

      for {scans, entries} <- [
            {scans(), [first]},
            {scans("s1", "c2"), [first]},
            {[scan(:spec, @spec_id, "s1")], [first]},
            {scans(), [first, relate("s1", "c2", at: "2026-09-28T11:00:00Z")]},
            {scans(), [first, retired]}
          ] do
        refute Report.json(Status.derive(scans, entries)) =~ ~s("nil")
      end
    end

    @tag verifies: "units-by-role"
    test "spec units are counted by role, and a block or hint says what it sits in" do
      block = %{scan(:spec, "spec.md#rule", "b1") | role: :block, within: @spec_id}
      section = %{scan(:spec, @spec_id, "s1") | role: :section}
      status = Status.derive([section, block, scan(:code, @code_id, "c1")], [])

      assert Status.units(status) == %{section: 1, block: 1, test_hint: 0}
      text = Report.text(status)
      assert text =~ "  spec units: sections 1 · blocks 1 · test hints 0\n"
      assert text =~ "spec spec.md#rule (block in #{@spec_id}) (f:1-2)"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert json["units"] == %{"section" => 1, "block" => 1, "test_hint" => 0}

      assert %{"role" => "block", "within" => @spec_id} =
               Enum.find(json["new"], &(&1["id"] == "spec.md#rule"))

      assert %{"role" => nil, "within" => nil} = Enum.find(json["new"], &(&1["kind"] == "code"))

      assert status |> Report.golden() |> Surfex.Golden.render() =~ "2 spec units"
    end

    @tag verifies: ["status-failing"]
    test "broken citations fail, and all three reports show them" do
      citation = %{
        span: "M.gone/0",
        file: "spec.md",
        section: "Carts",
        line: 3,
        status: :unresolved,
        items: []
      }

      status = Status.derive(scans(), [], [], citations: [citation])
      assert Status.failing?(status)
      assert Report.text(status) =~ "spec.md:3 (Carts): `M.gone/0` names nothing the code has"
      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert [%{"span" => "M.gone/0", "status" => "unresolved", "line" => 3}] = json["citations"]
      golden = status |> Report.golden() |> Surfex.Golden.render()
      assert golden =~ "## broken citations"
      # The golden names the section, not the line, so moving text doesn't restamp it.
      refute golden =~ "spec.md:3"
    end

    # #76: a proposed relation fails, so the report must say which; unvalidated ones are
    # counted, and listed where they fail.
    @tag verifies: "status-pure"
    test "proposed relations are listed; unvalidated ones counted, and listed under validated: true" do
      proposed =
        Entry.new!(
          at: "2026-09-28T10:00:00Z",
          op: :relate,
          type: :implements,
          ends: [
            %{kind: :spec, id: @spec_id, hash: "s1"},
            %{kind: :code, id: @code_id, hash: "c1"}
          ],
          basis: :proposed
        )

      text = Report.text(Status.derive(scans(), [proposed]))
      assert text =~ "Proposed (a claim nothing has validated yet)"
      assert text =~ "implements  code M.add/2 ↔ spec spec.md#Carts/Adding items"

      legacy = relate("s1", "c1")
      text = Report.text(Status.derive(scans(), [legacy]))
      assert text =~ "relation status: ok"
      assert text =~ "  unvalidated: 1"
      refute text =~ "Unvalidated ("

      strict = Status.derive(scans(), [legacy], [], validated: true)
      text = Report.text(strict)
      assert text =~ "relation status: FAILING"
      assert text =~ "Unvalidated (current, but nothing has validated it)"
      assert text =~ "implements  code M.add/2 ↔ spec spec.md#Carts/Adding items"

      {json, :ok, _} = strict |> Report.json() |> :json.decode(:ok, %{null: nil})

      assert json["unvalidated"] == [
               %{
                 "type" => "implements",
                 "ends" => [
                   %{"kind" => "code", "id" => @code_id},
                   %{"kind" => "spec", "id" => @spec_id}
                 ]
               }
             ]
    end

    test "with no relations, it says so" do
      assert Report.text(Status.derive(scans(), [])) =~ "(no relations)"
    end

    @tag verifies: "status-pure"
    test "the golden is the same whatever order the scans and the log's lines come in" do
      extra = scan(:code, "M.other/0", "o")
      first = relate("s1", "c1")
      second = relate("s1", "c2", parents: [first.id], at: "2026-09-28T11:00:00Z")

      render = fn scans, entries ->
        Surfex.Golden.render(Report.golden(Status.derive(scans, entries)))
      end

      golden = render.([extra | scans("s1", "c3")], [first, second])
      assert golden == render.(Enum.reverse([extra | scans("s1", "c3")]), [second, first])

      # No hashes and no times: only a change of state changes it.
      for value <- ["s1", "c1", "c2", "c3", "2026-09-28"], do: refute(golden =~ value)
      assert golden =~ "dangling"
      assert %{name: "RELATIONS.md"} = Report.golden(Status.derive(scans(), [first]))
    end
  end

  describe "configuration" do
    @describetag verifies: "status-config-read"

    alias Surfex.Status.Config

    test "require: is validated" do
      assert Config.require!(require: [code: [:implements]]) == [code: [:implements]]

      assert_raise ArgumentError, ~r/:cod is neither a kind nor a spec role/, fn ->
        Config.require!(require: [cod: [:implements]])
      end

      assert_raise ArgumentError, ~r/code needs a non-empty list/, fn ->
        Config.require!(require: [code: [:likes]])
      end
    end

    test "triangle: is :report by default, or :fail, and nothing else" do
      assert Config.options!([]) == [triangle: :report]
      assert Config.options!(triangle: :fail) == [triangle: :fail]

      assert_raise ArgumentError, ~r/triangle: must be :report or :fail/, fn ->
        Config.options!(triangle: :loud)
      end

      # With classes:, the class rules come too, for judging stale excuses.
      classes = [classes: [{"c", "why"}], rules: [%{class: "c", kinds: [:function]}]]
      assert %{rules: [%{class: "c"}]} = Config.options!(classes)[:coverage]
      refute Keyword.has_key?(Config.options!([]), :coverage)
    end

    test "require: takes spec roles as keys" do
      assert Config.require!(require: [test_hint: [:verifies]]) == [test_hint: [:verifies]]
    end

    @tag :tmp_dir
    test "tests: scans the test files it names, and raises when it names none", %{tmp_dir: root} do
      File.write!(Path.join(root, "spec.md"), "# A\n\ntext\n")
      File.mkdir_p!(Path.join(root, "test"))

      File.write!(
        Path.join(root, "test/a_test.exs"),
        "defmodule ATest do\n  test \"a\", do: :ok\nend\n"
      )

      scans =
        Config.scans(
          [sources: ["spec.md"], scanner_opts: [paths: []], tests: ["test/*_test.exs"]],
          root
        )

      assert [%Scan{kind: :test, id: "ATest: a"}] = Enum.filter(scans, &(&1.kind == :test))

      assert_raise ArgumentError, ~r/tests: \["nope\/\*.exs"\] matches no file/, fn ->
        Config.scans([sources: ["spec.md"], tests: ["nope/*.exs"]], root)
      end
    end

    # #68: one answer to which files are the spec, for its sections and its citations.
    @tag :tmp_dir
    @tag verifies: "exclude-both"
    test "a file under exclude: contributes neither sections nor citations", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "spec"))
      File.write!(Path.join(root, "spec/01-cart.md"), "# Cart\n\n`MyApp.Cart.total/0` totals.\n")

      File.write!(
        Path.join(root, "spec/README.md"),
        "# How the spec is organised\n\n`MyApp.Gone` is not cited.\n"
      )

      config = [sources: ["spec/*.md"], exclude: ["spec/README.md"]]
      files = Surfex.Scan.Markdown.files(root, ["spec/*.md"], ["spec/README.md"])
      assert files == ["spec/01-cart.md"]

      ids = for %Scan{kind: :spec, id: id} <- Config.scans(config, root), do: id
      assert ids == ["spec/01-cart.md#Cart"]

      profile = Config.profile!(config, "MyApp")
      assert Surfex.Cite.sources(profile, root) == ["spec/01-cart.md"]

      # Excluding every file is an empty spec, and that stays an error.
      assert_raise ArgumentError, ~r/no spec sections found/, fn ->
        Config.scans([sources: ["spec/*.md"], exclude: ["spec/"]], root)
      end
    end

    @tag :tmp_dir
    test "no spec sections is an error, not a quiet empty status", %{tmp_dir: root} do
      assert_raise ArgumentError, ~r/no spec sections found/, fn ->
        Config.scans([sources: ["spec.md"]], root)
      end

      assert_raise ArgumentError, ~r/sources/, fn -> Config.scans([], root) end
    end
  end

  @tag verifies: "scanner-behaviour"
  test "a project scanner implements Surfex.Scanner; a module that doesn't is refused, named" do
    assert Surfex.Scanner.behaviour_info(:callbacks) == [items: 2]

    assert_raise ArgumentError, ~r/String does not implement Surfex.Scanner/, fn ->
      Surfex.Status.Config.items([scanner: String], ".")
    end

    assert [%Surfex.Item{name: "one"}] =
             Surfex.Status.Config.items([scanner: Surfex.StatusTest.OneScanner], ".")
  end

  describe "reading .surfex.exs" do
    @describetag verifies: "status-config-read"
    @describetag :tmp_dir

    alias Surfex.Status.Config

    @tag verifies: "traces"
    test "read!/1 refuses an unknown key, and a key of the removed trace with the reason",
         %{tmp_dir: root} do
      path = Path.join(root, ".surfex.exs")
      File.write!(path, ~s([sources: ["spec.md"], sorces: []]))
      assert_raise ArgumentError, ~r/unknown keys \[:sorces\]/, fn -> Config.read!(path) end

      File.write!(path, ~s([sources: ["spec.md"], columns: []]))

      assert_raise ArgumentError, ~r/\[:columns\] belonged to the v0.2 trace/, fn ->
        Config.read!(path)
      end

      File.write!(path, ~s([sources: ["spec.md"]]))
      assert Config.read!(path) == [sources: ["spec.md"]]
    end

    test "status/4 derives the status as mix surfex.status does, with the caller's options",
         %{tmp_dir: root} do
      File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)
      File.write!(Path.join(root, "spec.md"), "# Carts\n\n`MyApp.Cart.nothing/0` is gone.\n")
      config = [sources: ["spec.md"], require: [code: [:implements]]]

      status = Config.status(config, root, "MyApp", planned: :fail)
      assert [%{span: "MyApp.Cart.nothing/0"}] = status.citations
      assert Enum.any?(status.unmet, &(&1.scan.id == "MyApp.Cart.add/2"))
      assert status.planned == :fail
      assert status.relations == []
    end

    test "items/2 and load/3 scan the code once; profile!/2 reads under the namespace",
         %{tmp_dir: root} do
      File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)
      File.write!(Path.join(root, "spec.md"), "# Carts\n\n`MyApp.Cart.nothing/0` is gone.\n")
      config = [sources: ["spec.md"]]

      assert "add/2" in Enum.map(Config.items(config, root), & &1.name)
      {scans, options} = Config.load(config, root, "MyApp")
      assert Enum.any?(scans, &(&1.id == "MyApp.Cart.add/2"))
      assert [%{span: "MyApp.Cart.nothing/0", status: :unresolved}] = options[:citations]
      assert Regex.match?(Config.profile!(config, "MyApp").shape, "MyApp.Cart")
    end
  end

  @tag verifies: ["status-states", "status-failing"]
  test "summary/1 counts relations per type and state; tips/2 are the judgements in force" do
    first = relate("s1", "c1")
    second = relate("s1", "c2", parents: [first.id], at: "2026-09-28T11:00:00Z")
    status = Status.derive(scans("s1", "c2"), [first, second])

    assert Status.summary(status) == %{implements: %{current: 1}}
    assert Status.tips([first, second], Entry.relation(first)) == [second]
    refute Status.failing?(status)
  end
end
