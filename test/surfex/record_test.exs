defmodule Surfex.RecordTest do
  use ExUnit.Case, async: true

  alias Surfex.{Record, Scan, Status}
  alias Surfex.Log.Entry

  @spec_id "spec.md#Carts/Adding items"
  @code_id "M.add/2"
  @meta [by: "tester", commit: "abc", at: "2026-09-28T10:00:00Z"]

  defp scan(kind, id, hash),
    do: %Scan{kind: kind, id: id, hash: hash, location: %{file: "f", lines: {1, 1}}}

  defp scans(code_hash \\ "c1"),
    do: [
      scan(:spec, @spec_id, "s1"),
      scan(:code, @code_id, code_hash),
      scan(:code, "M.helper/1", "h1")
    ]

  defp later(meta, n), do: Keyword.put(meta, :at, "2026-09-28T1#{n}:00:00Z")

  defp state(scans, entries), do: Status.derive(scans, entries).relations |> Enum.map(& &1.state)

  test "relate records both ends at their current hashes, with who and when" do
    {:ok, [e]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
    assert %Entry{op: :relate, type: :implements, by: "tester", commit: "abc", parents: []} = e

    assert e.ends == [
             %{kind: :code, id: @code_id, hash: "c1"},
             %{kind: :spec, id: @spec_id, hash: "s1"}
           ]

    assert state(scans(), [e]) == [:current]
  end

  test "relating again supersedes the tip" do
    {:ok, [first]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)

    {:ok, [second]} =
      Record.relate(scans(), [first], @spec_id, @code_id, :implements, later(@meta, 1))

    assert second.parents == [first.id]
  end

  test "a directed type keeps from → to" do
    {:ok, [e]} = Record.relate(scans(), [], @code_id, "M.helper/1", :depends_on, @meta)
    assert Enum.map(e.ends, & &1.id) == [@code_id, "M.helper/1"]
  end

  test "ids must be scanned, and a kind prefix picks between kinds" do
    assert {:error, msg} = Record.relate(scans(), [], @spec_id, "M.gone/0", :implements, @meta)
    assert msg =~ "M.gone/0 is not scanned"

    both = [scan(:spec, "x", "1"), scan(:code, "x", "2") | scans()]
    assert {:error, msg} = Record.relate(both, [], "x", @code_id, :implements, @meta)
    assert msg =~ "prefix it with spec: or code:"
    assert {:ok, [e]} = Record.relate(both, [], "spec:x", @code_id, :implements, @meta)
    assert %{kind: :spec, id: "x", hash: "1"} in e.ends
  end

  describe "confirm" do
    setup do
      {:ok, [first]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
      %{first: first}
    end

    test "re-records a dangling relation at the current hashes, parented on its tip", %{
      first: first
    } do
      {:ok, [e]} = Record.confirm(scans("c2"), [first], [@code_id], later(@meta, 1))
      assert e.parents == [first.id]
      assert %{kind: :code, id: @code_id, hash: "c2"} in e.ends
      assert state(scans("c2"), [first, e]) == [:current]
    end

    @tag verifies: "confirm-named"
    test "naming an id with nothing dangling is an error, not a no-op", %{first: first} do
      assert {:error, msg} = Record.confirm(scans(), [first], [@code_id], @meta)
      assert msg =~ "nothing dangling touches M.add/2"
    end

    test "naming both ends of one relation confirms it once", %{first: first} do
      {:ok, entries} = Record.confirm(scans("c2"), [first], [@code_id, @spec_id], later(@meta, 1))
      assert length(entries) == 1
    end
  end

  test "retire names every tip, and works when an end is gone" do
    {:ok, [first]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
    gone = [scan(:spec, @spec_id, "s1")]

    {:ok, [retired]} =
      Record.retire(gone, [first], @spec_id, @code_id, :implements, later(@meta, 1))

    assert %Entry{op: :retire, parents: [_]} = retired
    assert state(gone, [first, retired]) == [:retired]

    assert {:error, msg} = Record.retire(scans(), [], @spec_id, @code_id, :implements, @meta)
    assert msg =~ "no implements relation"
  end

  describe "resolve" do
    setup do
      {:ok, [base]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
      {:ok, [a]} = Record.confirm(scans("c2"), [base], [@code_id], later(@meta, 1) ++ [note: "a"])
      {:ok, [b]} = Record.confirm(scans("c2"), [base], [@code_id], later(@meta, 2) ++ [note: "b"])
      %{entries: [base, a, b], a: a, b: b}
    end

    test "records the picked tip with both tips as parents, ending the conflict", c do
      assert state(scans("c2"), c.entries) == [:conflicted]

      {:ok, [fix]} =
        Record.resolve(
          scans("c2"),
          c.entries,
          @spec_id,
          @code_id,
          :implements,
          String.slice(c.a.id, 0, 8),
          later(@meta, 3)
        )

      assert Enum.sort(fix.parents) == Enum.sort([c.a.id, c.b.id])
      assert state(scans("c2"), c.entries ++ [fix]) == [:current]
    end

    test "an unknown or ambiguous pick, or nothing to resolve, is an error", c do
      assert {:error, msg} =
               Record.resolve(
                 scans("c2"),
                 c.entries,
                 @spec_id,
                 @code_id,
                 :implements,
                 "zzz",
                 @meta
               )

      assert msg =~ "no tip's id starts with zzz"

      assert {:error, msg} =
               Record.resolve(scans("c2"), c.entries, @spec_id, @code_id, :implements, "", @meta)

      assert msg =~ "more than one tip"
      [base | _] = c.entries

      assert {:error, msg} =
               Record.resolve(scans(), [base], @spec_id, @code_id, :implements, "x", @meta)

      assert msg =~ "not conflicted"
    end
  end

  test "history lists every entry touching an id, oldest first" do
    {:ok, [first]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)

    {:ok, [dep]} =
      Record.relate(scans(), [first], @code_id, "M.helper/1", :depends_on, later(@meta, 1))

    assert Record.history([dep, first], @code_id) == [first, dep]
    assert Record.history([dep, first], "spec:" <> @spec_id) == [first]
    assert Record.history([dep, first], "M.nothing/0") == []
  end

  describe "plan" do
    @anything &__MODULE__.plausible/2
    def plausible(_kind, id), do: not String.contains?(id, "typo")

    test "records the unscanned end without a hash, and the relation is planned" do
      {:ok, [e]} =
        Record.plan(scans(), [], @spec_id, "M.later/1", :implements, @anything, @meta)

      assert %{kind: :code, id: "M.later/1", hash: nil} in e.ends
      assert %{kind: :spec, id: @spec_id, hash: "s1"} in e.ends
      assert state(scans(), [e]) == [:planned]

      # The code appears: the relation dangles on it until someone confirms it.
      written = scans() ++ [scan(:code, "M.later/1", "l1")]
      assert state(written, [e]) == [:dangling]
      {:ok, [confirmed]} = Record.confirm(written, [e], ["M.later/1"], later(@meta, 1))
      assert confirmed.parents == [e.id]
      assert state(written, [e, confirmed]) == [:current]
    end

    test "the unscanned end's kind comes from its prefix, or from a # for a spec id" do
      {:ok, [e]} =
        Record.plan(scans(), [], "spec.md#Later", @code_id, :implements, @anything, @meta)

      assert %{kind: :spec, id: "spec.md#Later", hash: nil} in e.ends

      {:ok, [e]} = Record.plan(scans(), [], "code:Odd#1", @code_id, :depends_on, @anything, @meta)
      assert %{kind: :code, id: "Odd#1", hash: nil} in e.ends
    end

    test "refuses when both ends or neither end is scanned, and an implausible id" do
      assert {:error, "M.add/2 and M.helper/1 are both scanned" <> _} =
               Record.plan(scans(), [], @code_id, "M.helper/1", :depends_on, @anything, @meta)

      assert {:error, "neither" <> _} =
               Record.plan(scans(), [], "M.a/0", "M.b/0", :depends_on, @anything, @meta)

      assert {:error, "M.typo/0 is not scanned and doesn't look like a code id" <> _} =
               Record.plan(scans(), [], @spec_id, "M.typo/0", :implements, @anything, @meta)
    end

    test "a planned relation retires like any other" do
      {:ok, [e]} = Record.plan(scans(), [], @spec_id, "M.later/1", :implements, @anything, @meta)

      {:ok, [retired]} =
        Record.retire(scans(), [e], @spec_id, "M.later/1", :implements, later(@meta, 1))

      assert retired.parents == [e.id]
      assert state(scans(), [e, retired]) == [:retired]
    end
  end

  # #37: a renamed heading or an added anchor carries its relations across.
  describe "move" do
    @new_id "spec.md#cart-add"

    defp renamed(spec_hash \\ "s1", code_hash \\ "c1"),
      do: [
        scan(:spec, @new_id, spec_hash),
        scan(:code, @code_id, code_hash),
        scan(:code, "M.helper/1", "h1")
      ]

    defp related do
      {:ok, [e]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
      e
    end

    test "retires the old relation and relates the new id at the recorded versions" do
      old = related()
      {:ok, [retired, moved]} = Record.move(renamed(), [old], @spec_id, @new_id, later(@meta, 1))

      assert %Entry{op: :retire, parents: [old_id]} = retired
      assert old_id == old.id
      assert %Entry{op: :relate, type: :implements} = moved
      assert %{kind: :spec, id: @new_id, hash: "s1"} in moved.ends
      assert moved.note == "moved from #{@spec_id} to #{@new_id}"

      assert Enum.map(
               Status.derive(renamed(), [old, retired, moved]).relations,
               &{&1.relation, &1.state}
             ) == [
               {{:implements, {:code, @code_id}, {:spec, @spec_id}}, :retired},
               {{:implements, {:code, @code_id}, {:spec, @new_id}}, :current}
             ]
    end

    @tag verifies: "move-carries"
    test "never confirms: text changed in the move, or the other end changed, still dangles" do
      old = related()

      {:ok, entries} = Record.move(renamed("s2"), [old], @spec_id, @new_id, later(@meta, 1))
      assert :dangling in state(renamed("s2"), [old | entries])

      {:ok, entries} = Record.move(renamed("s1", "c2"), [old], @spec_id, @new_id, later(@meta, 1))
      moved = List.last(entries)
      assert %{kind: :code, id: @code_id, hash: "c1"} in moved.ends
      assert :dangling in state(renamed("s1", "c2"), [old | entries])
    end

    test "refuses a new id that isn't scanned, an old id with nothing live, and a conflict" do
      old = related()

      assert {:error, "spec.md#nowhere is not scanned" <> _} =
               Record.move(renamed(), [old], @spec_id, "spec.md#nowhere", @meta)

      assert {:error, "no live relation names spec.md#Gone" <> _} =
               Record.move(renamed(), [old], "spec.md#Gone", @new_id, @meta)

      {:ok, [other]} =
        Record.relate(scans("c1"), [], @spec_id, @code_id, :implements, later(@meta, 2))

      assert {:error, _conflicted} =
               Record.move(renamed(), [old, other], @spec_id, @new_id, @meta)
    end
  end
end
