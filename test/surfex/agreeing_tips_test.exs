defmodule Surfex.AgreeingTipsTest do
  # #133: tips that record the same judgement without seeing each other agree. They are one
  # judgement to every reader of the status, not a conflict; tips that disagree still are.
  use ExUnit.Case, async: true

  alias Surfex.{Record, Scan, Status}
  alias Surfex.Log.Entry

  @spec_id "spec.md#s"
  @code_id "M.f/0"
  @meta [by: "tester", at: "2026-10-05T12:00:00Z", note: "checked"]

  defp scan(kind, id, hash, extra \\ []),
    do:
      struct!(
        Scan,
        [kind: kind, id: id, hash: hash, location: %{file: "f", lines: {1, 1}}] ++ extra
      )

  defp scans(spec \\ "s1", code \\ "c1"),
    do: [scan(:spec, @spec_id, spec, role: :section), scan(:code, @code_id, code)]

  # One judgement recorded by `by` at minute `n`: the relation at the given versions.
  defp tip(by, n, opts \\ []) do
    Entry.new!(
      at: "2026-10-05T10:0#{n}:00Z",
      by: by,
      note: "#{by}'s note",
      op: Keyword.get(opts, :op, :relate),
      type: Keyword.get(opts, :type, :implements),
      basis: Keyword.get(opts, :basis, :review),
      parents: Keyword.get(opts, :parents, []),
      ends:
        Keyword.get_lazy(opts, :ends, fn ->
          [
            %{kind: :spec, id: @spec_id, hash: Keyword.get(opts, :spec, "s1")},
            %{kind: :code, id: @code_id, hash: Keyword.get(opts, :code, "c1")}
          ]
        end)
    )
  end

  defp agreeing, do: [tip("alice", 1), tip("bob", 2)]
  defp relation(status), do: hd(status.relations)

  describe "agreeing tips" do
    @describetag verifies: "agreeing-tips"

    test "are one judgement: judged as one tip, the smallest id representing them" do
      [a, b] = agreeing()
      r = relation(Status.derive(scans(), [a, b]))

      assert r.state == :current
      assert r.tip.id == Enum.min([a.id, b.id])
      assert Status.representative([a, b]) == r.tip
      assert Enum.sort(Enum.map(r.tips, & &1.id)) == Enum.sort([a.id, b.id])

      # Changed since: they agree on that too, so it dangles rather than conflicts.
      assert %{state: :dangling, changed: [{:code, @code_id}]} =
               relation(Status.derive(scans("s1", "c2"), [a, b]))
    end

    test "disagree on the operation, the versions or the basis: then they conflict" do
      for other <- [
            tip("bob", 2, op: :retire, basis: nil),
            tip("bob", 2, code: "c0"),
            tip("bob", 2, basis: :evidence)
          ] do
        r = relation(Status.derive(scans(), [tip("alice", 1), other]))
        assert r.state == :conflicted
        assert r.tip == nil
      end
    end

    test "every reader of the status sees one judgement: validated, checked, reported" do
      status = Status.derive(scans(), agreeing())
      assert Status.validated?(status, relation(status))
      assert status.unvalidated == []

      # As evidence claims, CI checks them, and reports them unproven when no run did.
      claims = [tip("alice", 1, basis: :evidence), tip("bob", 2, basis: :evidence)]
      unchecked = Status.derive(scans(), claims, [], evidence: [])
      assert [%{relation: {:implements, _, _}}] = unchecked.unproven

      {json, :ok, _} =
        status |> Surfex.Status.Report.json() |> :json.decode(:ok, %{null: nil})

      [rel] = json["relations"]
      assert Enum.all?(rel["ends"], &(&1["recorded"] != nil))
      assert length(rel["tips"]) == 2
    end

    test "confirm and move name every agreeing tip as a parent; resolve has nothing to do" do
      [a, b] = agreeing()
      both = Enum.sort([a.id, b.id])
      assert %Entry{} = Status.representative([a, b])

      {:ok, [retired]} = Record.retire(scans(), [a, b], @spec_id, @code_id, :implements, @meta)
      assert Enum.sort(retired.parents) == both

      # A judgement re-confirmed after a change names both agreeing tips.
      ends = [%{kind: :code, id: @code_id, hash: "c1"}, %{kind: :code, id: "M.g/0", hash: "g1"}]

      deps = [
        tip("alice", 1, type: :depends_on, basis: nil, ends: ends),
        tip("bob", 2, type: :depends_on, basis: nil, ends: ends)
      ]

      changed = [scan(:code, @code_id, "c2"), scan(:code, "M.g/0", "g1"), hd(scans())]

      {:ok, [confirmed]} =
        Record.confirm(changed, deps, @code_id, "M.g/0", :depends_on, @meta)

      assert Enum.sort(confirmed.parents) == Enum.sort(Enum.map(deps, & &1.id))

      renamed = [scan(:spec, "spec.md#t", "s1", role: :section), scan(:code, @code_id, "c1")]
      {:ok, [retired, moved]} = Record.move(renamed, [a, b], @spec_id, "spec.md#t", @meta)
      assert Enum.sort(retired.parents) == both
      assert moved.basis == :review

      assert {:error, "the tips of the implements relation agree: nothing to resolve" <> _} =
               Record.resolve(scans(), [a, b], @spec_id, @code_id, :implements, a.id, @meta)
    end

    test "two people resolving a conflict the same way agree, so it ends" do
      x = tip("alice", 1)
      y = tip("bob", 2, code: "c0")
      assert relation(Status.derive(scans(), [x, y])).state == :conflicted

      resolve = fn by ->
        meta = Keyword.merge(@meta, by: by, at: "2026-10-05T11:00:00Z")

        {:ok, [r]} =
          Record.resolve(scans(), [x, y], @spec_id, @code_id, :implements, x.id, meta)

        r
      end

      r = relation(Status.derive(scans(), [x, y, resolve.("carol"), resolve.("dave")]))
      assert r.state == :current
    end
  end
end
