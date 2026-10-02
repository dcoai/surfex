defmodule Surfex.RecordTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "recording-by-name"

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

  # A validated implements relation, as the process leaves one (§18): the fixture for what
  # isn't about validation itself.
  defp validated(meta \\ @meta) do
    Entry.new!(
      at: meta[:at],
      op: :relate,
      type: :implements,
      basis: :review,
      ends: [%{kind: :spec, id: @spec_id, hash: "s1"}, %{kind: :code, id: @code_id, hash: "c1"}]
    )
  end

  test "relate records both ends at their current hashes, with who and when" do
    {:ok, [e]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
    assert %Entry{op: :relate, type: :implements, by: "tester", commit: "abc", parents: []} = e

    assert e.ends == [
             %{kind: :code, id: @code_id, hash: "c1"},
             %{kind: :spec, id: @spec_id, hash: "s1"}
           ]

    # Naming a pair is a claim, not a validation (§18).
    assert e.basis == :proposed
    assert state(scans(), [e]) == [:proposed]
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
    assert msg =~ "prefix it with spec:, code:, test: or class:"
    assert {:ok, [e]} = Record.relate(both, [], "spec:x", @code_id, :implements, @meta)
    assert %{kind: :spec, id: "x", hash: "1"} in e.ends
  end

  describe "confirm" do
    setup do
      {:ok, [first]} = Record.relate(scans(), [], @code_id, "M.helper/1", :depends_on, @meta)
      %{first: first, note: later(@meta, 1) ++ [note: "add/2 still calls helper/1"]}
    end

    test "re-records one dangling relation at the current hashes, parented on its tip, as a judgement",
         c do
      {:ok, [e]} =
        Record.confirm(scans("c2"), [c.first], @code_id, "M.helper/1", :depends_on, c.note)

      assert e.parents == [c.first.id]
      assert e.basis == :judgement
      assert %{kind: :code, id: @code_id, hash: "c2"} in e.ends
      assert state(scans("c2"), [c.first, e]) == [:current]
    end

    @tag verifies: "confirm-named"
    test "confirming a relation with nothing to confirm is an error, not a no-op", c do
      assert {:error, msg} =
               Record.confirm(scans(), [c.first], @code_id, "M.helper/1", :depends_on, c.note)

      assert msg =~ "is current: nothing to confirm"

      assert {:error, msg} =
               Record.confirm(scans(), [c.first], @spec_id, "M.helper/1", :depends_on, c.note)

      assert msg =~ "no depends_on relation"
    end
  end

  test "retire names every tip, and works when an end is gone" do
    {:ok, [first]} = Record.relate(scans(), [], @spec_id, @code_id, :implements, @meta)
    gone = [scan(:spec, @spec_id, "s1")]

    {:ok, [retired]} =
      Record.retire(gone, [first], @spec_id, @code_id, :implements, later(@meta, 1))

    assert %Entry{op: :retire, parents: [_]} = retired
    assert state(gone, [first, retired]) == [:retired]

    # A pair never related can be declined only with a reason (#70).
    assert {:error, msg} = Record.retire(scans(), [], @spec_id, @code_id, :implements, @meta)
    assert msg =~ "never related" and msg =~ "note"
  end

  # #70: declining a suggestion is the same decision as retiring it, made earlier.
  describe "declining a pair never related" do
    @describetag verifies: "decline-recorded"

    test "retire records the decision not to relate, at both ends' versions, with its reason" do
      why = Keyword.put(@meta, :note, "add/2 is described by the wire format, not this section")
      {:ok, [declined]} = Record.retire(scans(), [], @spec_id, @code_id, :implements, why)

      assert %Entry{op: :retire, type: :implements, parents: [], basis: nil} = declined
      assert %{kind: :spec, id: @spec_id, hash: "s1"} in declined.ends
      assert state(scans(), [declined]) == [:retired]

      # A later relate revives it, naming the retire as its parent.
      {:ok, [revived]} =
        Record.relate(scans(), [declined], @spec_id, @code_id, :implements, later(@meta, 1))

      assert revived.parents == [declined.id]
    end

    test "it needs a reason, and both ends scanned" do
      assert {:error, msg} = Record.retire(scans(), [], @spec_id, @code_id, :implements, @meta)
      assert msg =~ "note"

      why = Keyword.put(@meta, :note, "never")

      assert {:error, _not_scanned} =
               Record.retire(scans(), [], "spec.md#Nowhere", @code_id, :implements, why)
    end
  end

  # #73: the tests reflect the spec and the code passes them, but the result is wrong.
  describe "mark and withdraw" do
    @describetag verifies: "mark-recorded"

    @note [note: "adding is too slow in use"]

    test "mark records one needs_update mark at the unit's current version, with a note" do
      {:ok, [m]} = Record.mark(scans(), [], @spec_id, :needs_update, @meta ++ @note)

      assert %Entry{op: :mark, type: :needs_update, by: "tester", parents: []} = m
      assert m.ends == [%{kind: :spec, id: @spec_id, hash: "s1"}]
      assert m.note == "adding is too slow in use"
      assert Record.history([m], @spec_id) == [m]

      assert {:error, "a note is required" <> _} =
               Record.mark(scans(), [], @spec_id, :needs_update, @meta)

      assert {:error, "M.add/2 is not a spec unit" <> _} =
               Record.mark(scans(), [], @code_id, :needs_update, @meta ++ @note)

      assert {:error, "spec.md#gone is not scanned" <> _} =
               Record.mark(scans(), [], "spec.md#gone", :needs_update, @meta ++ @note)
    end

    test "withdraw retires the open mark, naming it when there are several" do
      {:ok, [a]} = Record.mark(scans(), [], @spec_id, :needs_update, @meta ++ @note)
      why = later(@meta, 1) ++ [note: "measured again: it is fast enough"]

      {:ok, [w]} = Record.withdraw(scans(), [a], @spec_id, :needs_update, why)
      assert %Entry{op: :retire, type: :needs_update, parents: [parent]} = w
      assert parent == a.id
      assert Status.derive(scans(), [a, w]).marks == []

      assert {:error, "no open needs_update mark on spec.md#Carts/Adding items"} =
               Record.withdraw(scans(), [a, w], @spec_id, :needs_update, why)

      {:ok, [b]} = Record.mark(scans(), [a], @spec_id, :needs_update, later(@meta, 2) ++ @note)

      assert {:error, "2 open needs_update marks on " <> _} =
               Record.withdraw(scans(), [a, b], @spec_id, :needs_update, why)

      pick = why ++ [pick: String.slice(b.id, 0, 8)]
      {:ok, [w2]} = Record.withdraw(scans(), [a, b], @spec_id, :needs_update, pick)
      assert w2.parents == [b.id]

      assert {:error, "a note is required" <> _} =
               Record.withdraw(scans(), [a], @spec_id, :needs_update, later(@meta, 1))
    end
  end

  describe "resolve" do
    setup do
      {:ok, [base]} = Record.relate(scans(), [], @code_id, "M.helper/1", :depends_on, @meta)
      confirm = &Record.confirm(scans("c2"), [base], @code_id, "M.helper/1", :depends_on, &1)
      {:ok, [a]} = confirm.(later(@meta, 1) ++ [note: "a"])
      {:ok, [b]} = confirm.(later(@meta, 2) ++ [note: "b"])
      %{entries: [base, a, b], a: a, b: b}
    end

    test "records the picked tip with both tips as parents, ending the conflict", c do
      assert state(scans("c2"), c.entries) == [:conflicted]

      {:ok, [fix]} =
        Record.resolve(
          scans("c2"),
          c.entries,
          @code_id,
          "M.helper/1",
          :depends_on,
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
                 @code_id,
                 "M.helper/1",
                 :depends_on,
                 "zzz",
                 @meta
               )

      assert msg =~ "no tip's id starts with zzz"

      assert {:error, msg} =
               Record.resolve(
                 scans("c2"),
                 c.entries,
                 @code_id,
                 "M.helper/1",
                 :depends_on,
                 "",
                 @meta
               )

      assert msg =~ "more than one tip"
      [base | _] = c.entries

      assert {:error, msg} =
               Record.resolve(scans(), [base], @code_id, "M.helper/1", :depends_on, "x", @meta)

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

    @tag verifies: "planned-state"
    test "records the unscanned end without a hash, and the relation is planned" do
      {:ok, [e]} =
        Record.plan(scans(), [], @spec_id, "M.later/1", :implements, @anything, @meta)

      assert %{kind: :code, id: "M.later/1", hash: nil} in e.ends
      assert %{kind: :spec, id: @spec_id, hash: "s1"} in e.ends
      assert state(scans(), [e]) == [:planned]

      # The code appears: the relation is a proposed one until evidence or a review
      # validates it (§18); saying so by hand is refused.
      written = scans() ++ [scan(:code, "M.later/1", "l1")]
      assert state(written, [e]) == [:proposed]
      note = later(@meta, 1) ++ [note: "written"]

      assert {:error, "implements is validated by evidence or a review" <> _} =
               Record.confirm(written, [e], @spec_id, "M.later/1", :implements, note)
    end

    # #90: Surfex.Record never writes a basis-less implements or verifies; the grammar
    # admits those only as legacy, so it can't tell a new one from an old one.
    @tag verifies: "grammar-bases"
    test "a planned verifies or implements is proposed: the writers never leave a claim basis-less" do
      {:ok, [ver]} =
        Record.plan(scans(), [], "test:T: later", @spec_id, :verifies, @anything, @meta)

      assert ver.basis == :proposed

      {:ok, [impl]} =
        Record.plan(scans(), [], @spec_id, "M.later/1", :implements, @anything, @meta)

      assert impl.basis == :proposed
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

    defp related, do: validated()

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

    # #70: a retirement is a decision with a reason; a rename is no reason to forget it.
    @tag verifies: "move-carries-retirements"
    test "carries a retired relation as retired, with its reason, and never over a live one" do
      old = related()
      note = later(@meta, 1) ++ [note: "the section describes the wire format, not add/2"]
      {:ok, [retired]} = Record.retire(scans(), [old], @spec_id, @code_id, :implements, note)

      {:ok, recorded} = Record.move(renamed(), [old, retired], @spec_id, @new_id, later(@meta, 2))

      assert [%Entry{op: :retire, type: :implements} = carried] = recorded
      assert %{kind: :spec, id: @new_id, hash: "s1"} in carried.ends
      assert carried.note =~ "the section describes the wire format, not add/2"
      assert carried.note =~ String.slice(retired.id, 0, 12)

      status = Status.derive(renamed(), [old, retired | recorded])

      assert %{state: :retired} =
               Enum.find(
                 status.relations,
                 &(&1.relation == {:implements, {:code, @code_id}, {:spec, @new_id}})
               )

      # The new id already relates the pair: the live decision stands, nothing is retired.
      live =
        Entry.new!(
          at: "2026-09-28T12:00:00Z",
          op: :relate,
          type: :implements,
          basis: :review,
          ends: [
            %{kind: :spec, id: @new_id, hash: "s1"},
            %{kind: :code, id: @code_id, hash: "c1"}
          ]
        )

      assert {:error, "no live relation names " <> _} =
               Record.move(renamed(), [old, retired, live], @spec_id, @new_id, later(@meta, 2))
    end

    test "refuses a new id that isn't scanned, an old id with nothing live, and a conflict" do
      old = related()

      assert {:error, "spec.md#nowhere is not scanned" <> _} =
               Record.move(renamed(), [old], @spec_id, "spec.md#nowhere", @meta)

      assert {:error, "no live relation names spec.md#Gone" <> _} =
               Record.move(renamed(), [old], "spec.md#Gone", @new_id, @meta)

      other = validated(later(@meta, 2))

      assert {:error, _conflicted} =
               Record.move(renamed(), [old, other], @spec_id, @new_id, @meta)
    end
  end

  # #99: a renamed test module or describe is the same test version under a new id; what
  # the log knows about that version comes with it.
  describe "moving a test" do
    @describetag verifies: "move-carries-observations"
    @old_t "OldTest: totals: empty"
    @new_t "NewTest: totals: empty"

    defp test_scan(id, hash, file \\ "test/core/new_test.exs"),
      do: %{scan(:test, id, hash) | location: %{file: file, lines: {1, 1}}}

    defp observed(type, basis, hash \\ "t1"),
      do:
        Entry.new!(
          at: "2026-09-28T09:30:00Z",
          op: :observe,
          type: type,
          basis: basis,
          ends: [%{kind: :test, id: @old_t, hash: hash}]
        )

    defp tested,
      do:
        Entry.new!(
          at: "2026-09-28T09:00:00Z",
          op: :relate,
          type: :tests,
          ends: [%{kind: :test, id: @old_t, hash: "t1"}, %{kind: :code, id: @code_id, hash: "c1"}]
        )

    test "carries its red→green and baseline records when its version is unchanged" do
      log = [tested(), observed(:red_green, :evidence), observed(:baseline, :baseline)]
      scans = [scan(:code, @code_id, "c1"), test_scan(@new_t, "t1")]

      {:ok, recorded} = Record.move(scans, log, "test:" <> @old_t, "test:" <> @new_t, @meta)

      carried = for %Entry{op: :observe} = e <- recorded, do: {e.type, e.basis, hd(e.ends)}

      assert Enum.sort(carried) == [
               {:baseline, :baseline, %{kind: :test, id: @new_t, hash: "t1"}},
               {:red_green, :evidence, %{kind: :test, id: @new_t, hash: "t1"}}
             ]

      assert Enum.all?(recorded, &(&1.op != :observe or &1.note =~ "carried from #{@old_t}"))

      trust = %{setting: :trust, trusted: :all}
      status = Status.derive(scans, log ++ recorded, [], adoption: trust)
      assert MapSet.member?(status.discriminated, {@new_t, "t1"})
      assert MapSet.member?(status.baselined, {@new_t, "t1"})

      # Not a second baseline: the one-shot refusal still holds.
      assert {:error, "a baseline was already taken" <> _} =
               Record.baseline(
                 scans,
                 log ++ recorded,
                 [],
                 Keyword.merge(@meta, adoption: trust, note: "again")
               )
    end

    test "a changed version carries nothing, and says which records stayed behind" do
      log = [tested(), observed(:red_green, :evidence)]
      scans = [scan(:code, @code_id, "c1"), test_scan(@new_t, "t2")]

      {:ok, recorded} = Record.move(scans, log, "test:" <> @old_t, "test:" <> @new_t, @meta)
      refute Enum.any?(recorded, &(&1.op == :observe))

      assert [%{type: :red_green, hash: "t1", now: "t2"}] =
               Record.left_behind(scans, log, "test:" <> @old_t, "test:" <> @new_t)
    end

    test "a test with records but no live relation still moves them" do
      scans = [test_scan(@new_t, "t1")]

      assert {:ok, [%Entry{op: :observe, type: :red_green}]} =
               Record.move(
                 scans,
                 [observed(:red_green, :evidence)],
                 "test:" <> @old_t,
                 "test:" <> @new_t,
                 @meta
               )

      assert {:error, "no live relation names" <> _} =
               Record.move(scans, [], "test:" <> @old_t, "test:" <> @new_t, @meta)
    end
  end

  # #54: people or agents judge meaning, and evidence judges behaviour.
  describe "confirm_by_evidence/4" do
    @describetag verifies: "evidence-confirms"

    @hint "spec.md#h"
    @t "T: rejects"

    defp ev(result, code_hash, n, test_hash \\ "t1"),
      do: %{
        test: @t,
        test_hash: test_hash,
        result: result,
        at: "2026-09-28T1#{n}:00:00Z",
        run: "r#{n}",
        seq: 0,
        code: if(code_hash, do: %{@code_id => code_hash}, else: %{})
      }

    # The spec section, a hint inside it, the test and the code, at given versions.
    defp world(spec \\ "s1", code \\ "c1", test \\ "t1"),
      do: [
        scan(:spec, @spec_id, spec),
        %{scan(:spec, @hint, "h1") | role: :test_hint, within: @spec_id},
        scan(:code, @code_id, code),
        %{scan(:test, @t, test) | declares: [{:verifies, @hint}]}
      ]

    defp rel(type, {ak, a, ah}, {bk, b, bh}),
      do:
        Entry.new!(
          at: "2026-09-28T09:00:00Z",
          op: :relate,
          type: type,
          ends: [%{kind: ak, id: a, hash: ah}, %{kind: bk, id: b, hash: bh}]
        )

    # Everything confirmed at s1/c1/t1, the test verifying the hint.
    # As the process leaves them (§18): the test relation recorded on its failing run, the
    # code relation on red and then green.
    defp confirmed,
      do: [
        on(rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, "c1"}), :evidence),
        on(rel(:verifies, {:test, @t, "t1"}, {:spec, @hint, "h1"}), :evidence),
        rel(:tests, {:test, @t, "t1"}, {:code, @code_id, "c1"})
      ]

    defp on(e, basis),
      do:
        Entry.new!(
          at: e.at,
          op: e.op,
          type: e.type,
          parents: e.parents,
          ends: e.ends,
          basis: basis
        )

    defp confirmed_types(scans, entries, evidence) do
      {:ok, recorded} = Record.confirm_by_evidence(scans, entries, evidence, @meta)
      # The relations confirmed; the red_green observations are the log's own record (§17).
      for(e <- recorded, Entry.relation?(e), do: e.type) |> Enum.sort()
    end

    test "code changed: a test that went red then green confirms tests, and implements follows" do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      assert Enum.map(recorded, & &1.type) == [:red_green, :tests, :implements]
      assert Enum.all?(recorded, &(&1.note =~ "confirmed by evidence: T: rejects@t1 failed at"))
      assert List.last(recorded).note =~ "T: rejects verifies #{@spec_id}"
      assert state(world("s1", "c2"), confirmed() ++ recorded) |> Enum.all?(&(&1 == :current))
    end

    test "evidence for one arity of a function carries the arity the spec names" do
      located = &%{scan(:code, &1, &2) | location: %{file: "lib/m.ex", lines: {3, 5}}}

      scans = [
        scan(:spec, @spec_id, "s1"),
        located.(@code_id, "c2"),
        located.("M.add/3", "c2"),
        scan(:test, @t, "t1")
      ]

      entries = [
        rel(:implements, {:spec, @spec_id, "s1"}, {:code, "M.add/3", "c1"}),
        on(rel(:verifies, {:test, @t, "t1"}, {:spec, @spec_id, "s1"}), :evidence),
        rel(:tests, {:test, @t, "t1"}, {:code, @code_id, "c1"})
      ]

      # The test calls add/2; the section is implemented by add/3, the same definition.
      assert confirmed_types(scans, entries, [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]) == [
               :implements,
               :tests
             ]
    end

    test "a test never red, failing now, or green against other code confirms nothing" do
      assert confirmed_types(world("s1", "c2"), confirmed(), [
               ev(:passed, "c1", 1),
               ev(:passed, "c2", 2)
             ]) == []

      assert confirmed_types(world("s1", "c2"), confirmed(), [
               ev(:failed, "c1", 1),
               ev(:passed, "c2", 2),
               ev(:failed, "c2", 3)
             ]) == []

      assert confirmed_types(world("s1", "c3"), confirmed(), [
               ev(:failed, "c1", 1),
               ev(:passed, "c2", 2)
             ]) == []
    end

    test "a changed test must earn its red again, which is its test relation's failing run" do
      # The test changed (t2): tests and verifies dangle; evidence for t1 doesn't count.
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]
      assert confirmed_types(world("s1", "c1", "t2"), confirmed(), evidence) == []

      # t2 went red: that is the failing test, so its test relation is confirmed (§18); red
      # then green against new code confirms the code relations too.
      evidence = evidence ++ [ev(:failed, "c1", 3, "t2"), ev(:passed, "c2", 4, "t2")]

      assert confirmed_types(world("s1", "c2", "t2"), confirmed(), evidence) == [
               :implements,
               :tests,
               :verifies
             ]
    end

    test "after a spec-only rewording, a failing run doesn't confirm verifies: that is a judgement" do
      evidence = [ev(:failed, "c1", 1)]

      reworded =
        List.replace_at(world(), 1, %{
          scan(:spec, @hint, "h2")
          | role: :test_hint,
            within: @spec_id
        })

      refute :verifies in confirmed_types(reworded, confirmed(), evidence)
    end

    test "when the spec changed, only a test verifying that exact unit can carry implements" do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]
      # The section was reworded and the code changed: the hint's verifies doesn't speak for it.
      assert confirmed_types(world("s2", "c2"), confirmed(), evidence) == [:tests]

      exact = on(rel(:verifies, {:test, @t, "t1"}, {:spec, @spec_id, "s2"}), :judgement)

      assert confirmed_types(world("s2", "c2"), confirmed() ++ [exact], evidence) == [
               :implements,
               :tests
             ]
    end

    test "require_red: a tests relation can't be confirmed by hand until its test was red" do
      entries = confirmed()
      policy = [require_red: true, evidence: [ev(:passed, "c2", 1)]]

      note = Keyword.put(@meta, :note, "still exercises add/2")

      confirm =
        &Record.confirm(
          world("s1", "c2"),
          entries,
          "test:" <> @t,
          "code:" <> @code_id,
          :tests,
          note,
          &1
        )

      assert {:error, "require_red: T: rejects has never failed at its current version"} =
               confirm.(policy)

      policy = [require_red: true, evidence: [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]]
      assert {:ok, [%{basis: :judgement}]} = confirm.(policy)
      assert {:ok, [_]} = confirm.([])
    end
  end

  # #93: the evidence file is scratch; the fact a test version discriminated is kept.
  describe "discrimination in the log" do
    @describetag verifies: "red-green-recorded"

    defp observations(entries), do: for(%Entry{op: :observe} = e <- entries, do: e)

    test "a test version's red then green is recorded once, with its runs" do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      assert [%Entry{type: :red_green, basis: :evidence, parents: []} = seen] =
               observations(recorded)

      assert seen.ends == [%{kind: :test, id: @t, hash: "t1"}]
      assert seen.note =~ "failed at 2026-09-28T11:00:00Z"
      assert seen.note =~ "passed at 2026-09-28T12:00:00Z"

      # Recorded once: a second run with it in the log records no other.
      {:ok, again} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed() ++ recorded, evidence, @meta)

      assert observations(again) == []
      assert %{discriminated: discriminated} = Status.derive(world("s1", "c2"), recorded)
      assert MapSet.member?(discriminated, {@t, "t1"})
    end

    test "after the evidence file is lost, the log record and a green run re-confirm" do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      log = confirmed() ++ recorded

      # A refactor (c3) on a fresh checkout: only this run's green is in the evidence.
      fresh = [ev(:passed, "c3", 3)]
      {:ok, refactored} = Record.confirm_by_evidence(world("s1", "c3"), log, fresh, @meta)

      assert refactored |> Enum.map(& &1.type) |> Enum.sort() == [:implements, :tests]
      assert Enum.all?(refactored, &(&1.basis == :evidence and &1.note =~ "discriminated"))

      # Without the record, the same run confirms nothing.
      without = Enum.reject(log, &(&1.op == :observe))
      assert {:ok, []} = Record.confirm_by_evidence(world("s1", "c3"), without, fresh, @meta)
    end

    test "a changed test version, or red and green against the same code, records nothing" do
      same_code = [ev(:failed, "c1", 1), ev(:passed, "c1", 2)]
      {:ok, recorded} = Record.confirm_by_evidence(world(), confirmed(), same_code, @meta)
      assert observations(recorded) == []

      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      # The test changed (t2): t1's record doesn't speak for it.
      fresh = [ev(:passed, "c3", 3, "t2")]

      assert {:ok, []} =
               Record.confirm_by_evidence(
                 world("s1", "c3", "t2"),
                 confirmed() ++ recorded,
                 fresh,
                 @meta
               )
    end

    test "require_red accepts a test version the log says discriminated" do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      log = confirmed() ++ observations(recorded)
      note = Keyword.put(@meta, :note, "still exercises add/2")

      confirm =
        &Record.confirm(
          world("s1", "c3"),
          log,
          "test:" <> @t,
          "code:" <> @code_id,
          :tests,
          note,
          &1
        )

      # A fresh checkout: no red in the evidence, but the log has the record.
      assert {:ok, [_]} = confirm.(require_red: true, evidence: [ev(:passed, "c3", 3)])
    end
  end

  # #54: CI validates the claims; it records nothing.
  describe "checking confirmations by evidence" do
    @describetag verifies: "evidence-checked"

    defp claimed do
      evidence = [ev(:failed, "c1", 1), ev(:passed, "c2", 2)]

      {:ok, recorded} =
        Record.confirm_by_evidence(world("s1", "c2"), confirmed(), evidence, @meta)

      confirmed() ++ recorded
    end

    defp unproven(run),
      do: Status.derive(world("s1", "c2"), claimed(), [], evidence: run).unproven

    test "a run where the test passes against the code as confirmed bears the claims out" do
      assert unproven([ev(:passed, "c2", 5)]) == []

      refute Status.failing?(
               Status.derive(world("s1", "c2"), claimed(), [], evidence: [ev(:passed, "c2", 5)])
             )
    end

    test "a test that didn't run, failed, or ran against other code, disproves them" do
      assert [%{reason: :not_run}, %{reason: :not_run}] = unproven([])

      assert [%{reason: :failed, test: @t} | _] =
               unproven([ev(:passed, "c2", 5), ev(:failed, "c2", 6)])

      assert [%{reason: :other_code} | _] = unproven([ev(:passed, "c9", 5)])

      status = Status.derive(world("s1", "c2"), claimed(), [], evidence: [])
      assert Status.failing?(status)

      assert Surfex.Status.Report.text(status) =~
               "Unproven (a confirmation by evidence this run doesn't bear out)"
    end

    # #98: a test this job excluded wasn't checked here; that isn't a disproof.
    @tag verifies: "evidence-excluded"
    test "a test excluded or skipped in this run leaves its claims not checked here, not failing" do
      for reason <- [:excluded, :skipped] do
        status = Status.derive(world("s1", "c2"), claimed(), [], evidence: [ev(reason, nil, 5)])
        assert status.unproven == []
        assert [%{reason: ^reason, test: @t} | _] = status.unchecked
        refute Status.failing?(status)

        assert Surfex.Status.Report.text(status) =~
                 "Not checked here (its test was excluded or skipped in this run)"

        {json, :ok, _} =
          status |> Surfex.Status.Report.json() |> :json.decode(:ok, %{null: nil})

        assert [%{"reason" => _} | _] = json["unchecked"]
      end

      # A test that simply didn't run still fails: a broken job can't hide behind this.
      assert [%{reason: :not_run} | _] = unproven([])
    end

    # #98: each CI job's evidence, read together in a final job.
    @tag verifies: "evidence-merged"
    test "merged jobs: one bearing a claim out passes it, a disproof anywhere fails, and none checking it fails" do
      merged = fn files ->
        Status.derive(world("s1", "c2"), claimed(), [], evidence: {:merged, files})
      end

      job_main = [ev(:excluded, nil, 5)]
      job_slow = [ev(:passed, "c2", 6)]

      # The main job excluded the test, the slow job ran it: checked, borne out.
      status = merged.([job_main, job_slow])
      assert status.unproven == [] and status.unchecked == []
      refute Status.failing?(status)

      # A test simply absent from a job's file is normal in a split.
      refute Status.failing?(merged.([[], job_slow]))

      # Every job left it out: no job checked it, and that fails.
      status = merged.([job_main, [ev(:skipped, nil, 6)]])
      assert [%{reason: :no_job} | _] = status.unproven
      assert Status.failing?(status)
      assert Surfex.Status.Report.text(status) =~ "no job's evidence ran it"

      # A disproof in any job fails, whatever another job shows.
      assert [%{reason: :failed} | _] =
               merged.([job_slow, [ev(:failed, "c2", 7)]]).unproven
    end

    test "without evidence given, nothing is checked; relations confirmed by hand never are" do
      assert Status.derive(world("s1", "c2"), claimed(), []).unproven == []

      note = Keyword.put(@meta, :note, "still exercises add/2")

      {:ok, by_hand} =
        Record.confirm(
          world("s1", "c2"),
          confirmed(),
          "test:" <> @t,
          "code:" <> @code_id,
          :tests,
          note
        )

      assert Status.derive(world("s1", "c2"), confirmed() ++ by_hand, [], evidence: []).unproven ==
               []
    end
  end

  # #72: a current relation means validated, not asserted.
  describe "validation by process" do
    defp with_basis(entry, basis),
      do:
        Entry.new!(
          at: entry.at,
          op: entry.op,
          type: entry.type,
          parents: entry.parents,
          ends: entry.ends,
          basis: basis
        )

    @tag verifies: "process-proposed"
    test "a pair named by hand, or a tag with no failing run, is proposed and fails" do
      {:ok, [impl]} = Record.relate(world(), [], @spec_id, @code_id, :implements, @meta)
      assert impl.basis == :proposed
      status = Status.derive(world(), [impl])
      assert [%{state: :proposed}] = status.relations
      assert Status.failing?(status)

      {:ok, [ver]} = Record.relate(world(), [], "test:" <> @t, "spec:" <> @hint, :verifies, @meta)
      assert ver.basis == :proposed

      # The test's current version has failed: the test relation is recorded on that run.
      red = [ev(:failed, "c1", 1)]

      {:ok, [ver]} =
        Record.relate(world(), [], "test:" <> @t, "spec:" <> @hint, :verifies, @meta,
          evidence: red
        )

      assert ver.basis == :evidence
      assert [%{state: :current}] = Status.derive(world(), [ver]).relations
    end

    @tag verifies: "process-validated"
    test "implements becomes current by evidence; without a validating basis it is unvalidated" do
      {:ok, [impl]} = Record.relate(world(), [], @spec_id, @code_id, :implements, @meta)
      ver = with_basis(rel(:verifies, {:test, @t, "t1"}, {:spec, @hint, "h1"}), :evidence)
      tests = rel(:tests, {:test, @t, "t1"}, {:code, @code_id, "c1"})
      evidence = [ev(:failed, "c0", 1), ev(:passed, "c1", 2)]

      {:ok, recorded} = Record.confirm_by_evidence(world(), [impl, ver, tests], evidence, @meta)

      assert [%{type: :implements, basis: :evidence}] =
               Enum.filter(recorded, &(&1.type == :implements))

      entries = [impl, ver, tests | recorded]
      assert Status.derive(world(), entries).unvalidated == []

      # A relation current with no basis, as one recorded before validation existed.
      legacy = rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, "c1"})
      status = Status.derive(world(), [legacy, ver, tests])
      assert [%{relation: {:implements, _, _}}] = status.unvalidated
      refute Status.failing?(status)
      assert Status.failing?(Status.derive(world(), [legacy, ver, tests], [], validated: true))
    end

    @tag verifies: "process-validated"
    test "a move keeps the basis it carries" do
      validated =
        with_basis(rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, "c1"}), :review)

      renamed = [%{scan(:spec, "spec.md#new", "s1") | role: :section} | tl(world())]
      {:ok, [_retired, moved]} = Record.move(renamed, [validated], @spec_id, "spec.md#new", @meta)
      assert moved.basis == :review
    end

    # #89: re-recording a tip judges nothing new, so it keeps whatever validated it.
    @tag verifies: "process-validated"
    test "re-recording a tip keeps its basis: move, and resolve between conflicted tips" do
      impl = &rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, &1})
      renamed = [%{scan(:spec, "spec.md#new", "s1") | role: :section} | tl(world())]

      # Every basis an implements may carry (never judgement, §12.1).
      for basis <- Entry.bases() -- [:judgement] do
        {:ok, [_retired, moved]} =
          Record.move(renamed, [with_basis(impl.("c1"), basis)], @spec_id, "spec.md#new", @meta)

        assert moved.basis == basis, "move dropped #{basis}"

        # Two tips recorded without seeing each other, from one base; pick one.
        base = impl.("c0")
        tip = &%{with_basis(impl.(&1), basis) | parents: [base.id]}
        [a, b] = [tip.("c1"), tip.("c9")] |> Enum.map(&Entry.new!(Map.from_struct(&1)))
        entries = [base, a, b]
        assert [%{state: :conflicted}] = Status.derive(world(), entries).relations

        {:ok, [fix]} =
          Record.resolve(world(), entries, @spec_id, @code_id, :implements, a.id, @meta)

        assert fix.basis == basis, "resolve dropped #{basis}"
      end

      # Resolving between proposed tips leaves a claim, still proposed and failing.
      base = impl.("c0")

      proposed =
        &Entry.new!(Map.from_struct(%{with_basis(impl.(&1), :proposed) | parents: [base.id]}))

      [a, b] = [proposed.("c1"), proposed.("c9")]

      {:ok, [fix]} =
        Record.resolve(world(), [base, a, b], @spec_id, @code_id, :implements, a.id, @meta)

      status = Status.derive(world(), [base, a, b, fix])
      assert [%{state: :proposed}] = status.relations
      assert Status.failing?(status)
    end

    @tag verifies: "process-one-at-a-time"
    test "confirm takes one relation and a note, refuses implements, and records a judgement" do
      legacy = rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, "c1"})

      assert {:error, "implements is validated by evidence or a review" <> _} =
               Record.confirm(
                 world("s1", "c2"),
                 [legacy],
                 @spec_id,
                 @code_id,
                 :implements,
                 Keyword.put(@meta, :note, "looks right")
               )

      ver = rel(:verifies, {:test, @t, "t1"}, {:spec, @hint, "h1"})

      reworded =
        List.replace_at(world(), 1, %{
          scan(:spec, @hint, "h2")
          | role: :test_hint,
            within: @spec_id
        })

      assert {:error, "a note is required" <> _} =
               Record.confirm(reworded, [ver], "test:" <> @t, "spec:" <> @hint, :verifies, @meta)

      note = Keyword.put(@meta, :note, "reworded; the test still checks a closed cart is refused")

      {:ok, [judged]} =
        Record.confirm(reworded, [ver], "test:" <> @t, "spec:" <> @hint, :verifies, note)

      assert judged.basis == :judgement
    end

    @tag verifies: "process-one-at-a-time"
    test "validate needs the verifies relation and green evidence, and records a review" do
      impl = rel(:implements, {:spec, @hint, "h1"}, {:code, @code_id, "c1"})
      tests = rel(:tests, {:test, @t, "t1"}, {:code, @code_id, "c1"})

      note =
        Keyword.put(@meta, :note, "asserts a closed cart is refused, and the cart is unchanged")

      green = [ev(:passed, "c1", 1)]

      assert {:error, "no verifies relation" <> _} =
               Record.validate(world(), [impl, tests], @t, @hint, green, note)

      ver = rel(:verifies, {:test, @t, "t1"}, {:spec, @hint, "h1"})

      assert {:error, "no green run" <> _} =
               Record.validate(
                 world(),
                 [impl, tests, ver],
                 @t,
                 @hint,
                 [ev(:failed, "c1", 1)],
                 note
               )

      {:ok, recorded} = Record.validate(world(), [impl, tests, ver], @t, @hint, green, note)

      assert Enum.map(recorded, &{&1.type, &1.basis}) |> Enum.sort() == [
               implements: :review,
               verifies: :review
             ]

      assert Status.derive(world(), [impl, tests, ver | recorded]).unvalidated == []
    end

    @tag verifies: "process-one-at-a-time"
    test "validate carries a review of one arity to the arity the spec names" do
      located = &%{scan(:code, &1, &2) | location: %{file: "lib/m.ex", lines: {3, 5}}}

      scans = [
        scan(:spec, @spec_id, "s1"),
        located.(@code_id, "c1"),
        located.("M.add/3", "c1"),
        scan(:test, @t, "t1")
      ]

      # The section is implemented by add/3; the test calls add/2, the same definition.
      impl = rel(:implements, {:spec, @spec_id, "s1"}, {:code, "M.add/3", "c1"})
      ver = rel(:verifies, {:test, @t, "t1"}, {:spec, @spec_id, "s1"})
      note = Keyword.put(@meta, :note, "the test checks the section's claim through add/2")

      {:ok, recorded} =
        Record.validate(scans, [impl, ver], @t, @spec_id, [ev(:passed, "c1", 1)], note)

      assert Enum.map(recorded, &{&1.type, &1.basis}) |> Enum.sort() == [
               implements: :review,
               verifies: :review
             ]
    end

    @tag verifies: "process-one-at-a-time"
    test "validate against a section needs the test's current relation to a hint inside it" do
      # The code implements the section; the test verifies the hint inside it.
      impl = rel(:implements, {:spec, @spec_id, "s1"}, {:code, @code_id, "c1"})
      tests = rel(:tests, {:test, @t, "t1"}, {:code, @code_id, "c1"})
      hint = rel(:verifies, {:test, @t, "t1"}, {:spec, @hint, "h1"})
      note = Keyword.put(@meta, :note, "the hint's test covers the section's one claim")
      green = [ev(:passed, "c1", 1)]

      # The test's relation to the hint isn't validated yet: review it against the hint first.
      assert {:error, "validate T: rejects against spec.md#h first" <> _} =
               Record.validate(world(), [impl, tests, hint], @t, @spec_id, green, note)

      validated_hint = on(hint, :review)

      {:ok, recorded} =
        Record.validate(world(), [impl, tests, validated_hint], @t, @spec_id, green, note)

      # The section's code relation alone; the hint's relation is already validated.
      assert [%{type: :implements, basis: :review}] = recorded

      assert Status.derive(world(), [impl, tests, validated_hint | recorded]).unvalidated == []

      # Reviewing again records nothing for code already validated.
      assert {:ok, []} =
               Record.validate(
                 world(),
                 [impl, tests, validated_hint | recorded],
                 @t,
                 @spec_id,
                 green,
                 note
               )

      # A test that verifies nothing inside the section can't validate it.
      assert {:error, "no verifies relation" <> _} =
               Record.validate(world(), [impl, tests], @t, @spec_id, green, note)
    end
  end
end
