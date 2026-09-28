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
               "location" => %{"file" => "f", "lines" => [1, 2]}
             }
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

      assert_raise ArgumentError, ~r/unknown kind :cod/, fn ->
        Config.require!(require: [cod: [:implements]])
      end

      assert_raise ArgumentError, ~r/code needs a non-empty list/, fn ->
        Config.require!(require: [code: [:likes]])
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
