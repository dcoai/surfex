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

  test "new: a scanned id in no relation" do
    status = Status.derive([scan(:code, "M.other/0", "o") | scans()], [relate("s1", "c1")])
    assert [%Scan{id: "M.other/0"}] = status.new
  end

  describe "policy" do
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
    defp hint(id), do: %{scan(:spec, "spec.md##{id}", "h1") | role: :test_hint, within: @spec_id}
    defp test_scan(declares), do: %{scan(:test, "T: a", "t1") | declares: declares}

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

    test "a test verifying a block or hint inside the section counts for it" do
      hint = %{scan(:spec, "spec.md#h", "h1") | role: :test_hint, within: @spec_id}

      entries = [
        rel(:implements, @s, @c),
        rel(:verifies, @t, {:spec, "spec.md#h", "h1"}),
        rel(:tests, @t, @c)
      ]

      assert Status.derive([hint | tri_scans()], entries).triangle == []
    end

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

  test "failing: dangling, orphaned, conflicted or unmet; not new, retired or impacted" do
    refute Status.failing?(Status.derive(scans(), [relate("s1", "c1")]))

    refute Status.failing?(
             Status.derive([scan(:code, "M.x/0", "x") | scans()], [relate("s1", "c1")])
           )

    assert Status.failing?(Status.derive(scans("s1", "c2"), [relate("s1", "c1")]))
  end

  describe "the report" do
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

    test "with no relations, it says so" do
      assert Report.text(Status.derive(scans(), [])) =~ "(no relations)"
    end

    test "the golden is the same whatever order the scans and the log's lines come in" do
      extra = scan(:code, "M.other/0", "o")
      first = relate("s1", "c1")
      second = relate("s1", "c2", parents: [first.id], at: "2026-09-28T11:00:00Z")

      render = fn scans, entries ->
        Surfex.Golden.render(Report.golden(Status.derive(scans, entries)))
      end

      assert render.([extra | scans("s1", "c3")], [first, second]) ==
               render.(Enum.reverse([extra | scans("s1", "c3")]), [second, first])
    end
  end

  describe "configuration" do
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

    @tag :tmp_dir
    test "no spec sections is an error, not a quiet empty status", %{tmp_dir: root} do
      assert_raise ArgumentError, ~r/no spec sections found/, fn ->
        Config.scans([sources: ["spec.md"]], root)
      end
    end
  end
end
