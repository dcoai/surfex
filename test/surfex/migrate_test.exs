defmodule Surfex.MigrateTest do
  # #251: moving a section's implements to the claims inside it, and what that buys (§14.1).
  use ExUnit.Case, async: true

  alias Surfex.{Migrate, Scan}
  alias Surfex.Log.Entry

  @s "spec.md#s"
  @p "spec.md#p"
  @table "spec.md#t"
  @row "spec.md#t/M.put"
  @h1 "spec.md#h1"
  @h2 "spec.md#h2"
  @t1 "MTest: gets"
  @t2 "MTest: lists"

  defp spec(id, role, within),
    do: %Scan{
      kind: :spec,
      id: id,
      hash: "s1",
      role: role,
      within: within,
      location: %{file: "spec.md", lines: {1, 1}}
    }

  defp code(id, lines, calls \\ [], hash \\ "c1"),
    do: %Scan{
      kind: :code,
      id: id,
      hash: hash,
      role: :function,
      within: "M",
      calls: calls,
      location: %{file: "lib/m.ex", lines: lines}
    }

  defp test_scan(id, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t1",
      calls: calls,
      location: %{file: "test/m_test.exs", lines: {1, 1}}
    }

  # A section with three claims (a row keyed with no arity, and two hints) and six code
  # relations; and a prose section with one.
  defp scans,
    do: [
      spec(@s, :section, nil),
      spec(@table, :table, @s),
      spec(@row, :row, @table),
      spec(@h1, :test_hint, @s),
      spec(@h2, :test_hint, @s),
      spec(@p, :section, nil),
      # put/3 and put/4 are one definition: a default argument.
      code("M.put/3", {1, 3}, [], "p1"),
      code("M.put/4", {1, 3}, [], "p1"),
      code("M.get/1", {5, 6}),
      code("M.list/1", {8, 9}, ["M.helper/1"]),
      code("M.helper/1", {11, 12}),
      code("M.encode/1", {14, 15}),
      code("M.other/1", {17, 18}),
      %{test_scan(@t1, ["M.get/1"]) | declares: [{:verifies, @h1}]},
      %{test_scan(@t2, ["M.get/1", "M.list/1"]) | declares: [{:verifies, @h2}]}
    ]

  defp rel(type, {ak, a}, {bk, b}, basis),
    do:
      Entry.new!(
        at: "2026-10-14T10:00:00Z",
        op: :relate,
        type: type,
        basis: basis,
        ends: [
          %{kind: ak, id: a, hash: hash(ak, a)},
          %{kind: bk, id: b, hash: hash(bk, b)}
        ]
      )

  defp hash(kind, id), do: Enum.find(scans(), &(&1.kind == kind and &1.id == id)).hash

  defp entries do
    implements =
      for c <- ~w(M.put/3 M.put/4 M.get/1 M.list/1 M.helper/1 M.encode/1),
          do: rel(:implements, {:code, c}, {:spec, @s}, :review)

    implements ++
      [
        rel(:implements, {:code, "M.other/1"}, {:spec, @p}, :review),
        rel(:verifies, {:test, @t1}, {:spec, @h1}, :evidence),
        rel(:verifies, {:test, @t2}, {:spec, @h2}, :evidence),
        rel(:refines, {:spec, @h1}, {:spec, @s}, nil),
        rel(:refines, {:spec, @h2}, {:spec, @s}, nil),
        rel(:refines, {:spec, @table}, {:spec, @s}, nil),
        rel(:refines, {:spec, @row}, {:spec, @table}, nil)
      ]
  end

  @tag verifies: "migrate-candidates"
  test "each section-grain implements is proposed to the claims that could own it" do
    proposals = Migrate.proposals(scans(), entries(), [@s])

    assert Enum.map(proposals, &{&1.outcome, &1.codes, Enum.map(&1.claims, fn c -> c.claim end)}) ==
             [
               # None first: the spec work the migration surfaces.
               {:none, ["M.encode/1"], []},
               # Several, never decided.
               {:several, ["M.get/1"], [@h1, @h2]},
               # Reached only, through the item the test calls.
               {:single, ["M.helper/1"], [@h2]},
               {:single, ["M.list/1"], [@h2]},
               # One definition, one proposal; the arity-less key names both arities.
               {:single, ["M.put/3", "M.put/4"], [@row]}
             ]

    why = Map.new(proposals, &{&1.codes, Enum.flat_map(&1.claims, fn c -> c.why end)})
    assert why[["M.get/1"]] == [{:calls, @t1}, {:calls, @t2}]
    assert why[["M.helper/1"]] == [{:reaches, "M.list/1", @t2}]
    assert why[["M.put/3", "M.put/4"]] == [{:names, "M.put"}]

    # A key with an arity names that arity alone.
    scans = List.replace_at(scans(), 2, spec("spec.md#t/M.put/4", :row, @table))
    [put] = for p <- Migrate.proposals(scans, entries(), [@s]), "M.put/3" in p.codes, do: p
    assert put.claims == [%{claim: "spec.md#t/M.put/4", why: [{:names, "M.put/4"}]}]

    # A claim a test calls outranks one a test only reaches.
    scans = scans() ++ [test_scan("MTest: helps", ["M.helper/1"])]
    # A declaration resolving to the claim makes its test a verifying one too.
    scans = List.update_at(scans, -1, &%{&1 | declares: [{:verifies, @h1}]})
    entries = entries()
    [helper] = for p <- Migrate.proposals(scans, entries, [@s]), p.codes == ["M.helper/1"], do: p

    assert {:single, [%{claim: @h1, why: [{:calls, "MTest: helps"}]}]} =
             {helper.outcome, helper.claims}

    # A retired section relation isn't proposed.
    retire =
      Entry.new!(
        at: "2026-10-14T11:00:00Z",
        op: :retire,
        type: :implements,
        parents: [hd(entries()).id],
        ends: hd(entries()).ends
      )

    refute Enum.any?(
             Migrate.proposals(scans(), entries() ++ [retire], [@s]),
             &("M.put/3" in &1.codes)
           )

    assert Migrate.sections(scans(), "spec.md#", within: true) == {:ok, [@p, @s]}
    assert Migrate.sections(scans(), @s) == {:ok, [@s]}
    assert {:error, "spec.md#x is no section"} = Migrate.sections(scans(), "spec.md#x")
    assert {:error, "spec.md#h1 is no section"} = Migrate.sections(scans(), @h1)
    assert {:error, _} = Migrate.sections(scans(), "other.md", within: true)
  end

  @tag verifies: "migrate-report"
  test "the report gives relations now and after, the marking, and each dangle width" do
    %{sections: [s, p], population: population} = Migrate.report(scans(), entries(), :all)

    # Six implements and three refines on the section: one edit of its text dangles nine.
    assert %{
             section: @s,
             kind: :units,
             relations: 9,
             after: 4,
             marking: 0,
             implements: 6,
             single: 4,
             several: 1,
             none: 1
           } = s

    # The code no claim owns stays on the section; each claim's is its own and the moved.
    assert Enum.map(s.widths, &{&1.codes, &1.now, &1.after}) == [
             {["M.encode/1"], 9, 4},
             {["M.get/1"], 9, 3},
             {["M.helper/1"], 9, 3},
             {["M.list/1"], 9, 3},
             {["M.put/3", "M.put/4"], 9, 3}
           ]

    # A prose section needs its claims named first: the marking dangles all it holds.
    assert %{section: @p, kind: :prose, relations: 1, marking: 1, none: 1, after: 1} = p

    assert population == %{
             units: %{sections: 1, implements: 6},
             prose: %{sections: 1, implements: 1}
           }

    assert %{sections: [%{section: @p}]} = Migrate.report(scans(), entries(), [@p])
  end

  describe "migrating" do
    @meta [by: "tester", commit: "abc", at: "2026-10-14T12:00:00Z"]

    # The claim relation validated, as a review records it: the relation's tip again, at
    # its versions, with basis review.
    defp reviewed(entries, code, claim) do
      relation = Entry.relation(:implements, %{kind: :code, id: code}, %{kind: :spec, id: claim})
      tips = Surfex.Status.tips(entries, relation)

      Entry.new!(
        at: "2026-10-14T13:00:00Z",
        op: :relate,
        type: :implements,
        basis: :review,
        parents: Enum.map(tips, & &1.id),
        ends: hd(tips).ends,
        note: "reviewed"
      )
    end

    defp derive(entries), do: Surfex.Status.derive(scans(), entries)

    defp state(status, code, unit) do
      relation = Entry.relation(:implements, %{kind: :code, id: code}, %{kind: :spec, id: unit})
      Enum.find(status.relations, &(&1.relation == relation))
    end

    @tag verifies: "migrate-accept"
    test "--accept records each single proposal, proposed and migrating, failing nothing" do
      {:ok, recorded} = Migrate.accept(scans(), entries(), [@s], @meta)

      assert Enum.map(recorded, &{&1.op, &1.basis, &1.migrates, code_of(&1), spec_of(&1)}) == [
               {:relate, :proposed, @s, "M.helper/1", @h2},
               {:relate, :proposed, @s, "M.list/1", @h2},
               {:relate, :proposed, @s, "M.put/3", @row},
               {:relate, :proposed, @s, "M.put/4", @row}
             ]

      assert hd(recorded).note == "migrating from #{@s} to its claim #{@h2}"

      status = derive(entries() ++ recorded)
      refute Surfex.Status.failing?(status)
      assert %{state: :proposed, migrates: @s} = state(status, "M.list/1", @h2)
      # The section keeps its relation until its claim's is validated.
      assert %{state: :current} = state(status, "M.list/1", @s)

      assert %{code: "M.list/1", section: @s, claims: [@h2], settled: false} in status.migrating

      # The same claims named by hand, without migrates, fail as any proposed relation.
      plain = for e <- recorded, do: Entry.new!(e |> Map.from_struct() |> Map.put(:migrates, nil))
      assert Surfex.Status.failing?(derive(entries() ++ plain))

      # The listing shows them migrating now, and a second --accept records nothing new.
      assert [:none, :several, :migrating, :migrating, :migrating] =
               Enum.map(Migrate.proposals(scans(), entries() ++ recorded, [@s]), & &1.outcome)

      assert {:ok, []} = Migrate.accept(scans(), entries() ++ recorded, [@s], @meta)
    end

    @tag verifies: "migrate-accept"
    test "the section's relation is retired only once its claim's is validated" do
      {:ok, recorded} = Migrate.accept(scans(), entries(), [@s], @meta)
      log = entries() ++ recorded
      assert {:ok, []} = Migrate.settle(scans(), log, [@s], @meta)

      log = log ++ [reviewed(log, "M.list/1", @h2)]
      status = derive(log)

      assert %{code: "M.list/1", settled: true} =
               Enum.find(status.migrating, &(&1.code == "M.list/1"))

      # --accept retires what is settled, noting the claim it moved to.
      {:ok, [retire]} = Migrate.accept(scans(), log, [@s], @meta)
      assert {retire.op, code_of(retire), spec_of(retire)} == {:retire, "M.list/1", @s}
      assert retire.note == "moved to its claim #{@h2}"

      status = derive(log ++ [retire])
      assert %{state: :retired} = state(status, "M.list/1", @s)
      assert %{state: :current, migrates: nil} = state(status, "M.list/1", @h2)
      refute Enum.any?(status.migrating, &(&1.code == "M.list/1"))
      refute Surfex.Status.failing?(status)

      # Retired by hand before its claim holds it, the claim's proposed relation fails.
      early =
        Entry.new!(
          at: "2026-10-14T14:00:00Z",
          op: :retire,
          type: :implements,
          parents: [Enum.find(entries(), &(code_of(&1) == "M.helper/1")).id],
          ends: Enum.find(entries(), &(code_of(&1) == "M.helper/1")).ends
        )

      status = derive(log ++ [early])
      assert %{state: :proposed, migrates: nil} = state(status, "M.helper/1", @h2)
      assert Surfex.Status.failing?(status)

      # suggest proposes the same retirement, and --accept records it.
      profile = Surfex.Status.Config.profile!([sources: ["spec.md"]], "M")
      log = log ++ [retire, reviewed(log, "M.helper/1", @h2)]
      suggestions = Surfex.Suggest.all(profile, [], scans(), log, "test/fixtures/none")
      assert [%{code: "M.helper/1", section: @s, claims: [@h2]}] = suggestions.migrated

      only = Map.new(suggestions, fn {k, v} -> {k, if(k == :migrated, do: v, else: [])} end)
      {:ok, [retire]} = Surfex.Suggest.accept_all(only, scans(), log, @meta)
      assert {retire.op, retire.note} == {:retire, "moved to its claim #{@h2}"}
    end

    @tag verifies: "migrate-accept"
    test "--code --to records a reviewer's choice; a claim already holding it retires the section's" do
      {:ok, [chosen]} = Migrate.choose(scans(), entries(), @s, "M.get/1", [@h1], @meta)
      assert {chosen.migrates, code_of(chosen), spec_of(chosen)} == {@s, "M.get/1", @h1}

      # One arity names the definition: both are chosen.
      {:ok, both} = Migrate.choose(scans(), entries(), @s, "M.put/4", [@row], @meta)
      assert Enum.map(both, &code_of/1) == ["M.put/3", "M.put/4"]

      assert {:error, "spec.md#p: not a claim inside spec.md#s"} =
               Migrate.choose(scans(), entries(), @s, "M.get/1", [@p], @meta)

      assert {:error, "M.other/1 has no live implements to spec.md#s" <> _} =
               Migrate.choose(scans(), entries(), @s, "M.other/1", [@h1], @meta)

      # The claim already holds a validated relation: nothing to wait for.
      held = reviewed([chosen], "M.get/1", @h1)

      {:ok, [retire]} =
        Migrate.choose(scans(), entries() ++ [chosen, held], @s, "M.get/1", [@h1], @meta)

      assert {retire.op, code_of(retire), spec_of(retire)} == {:retire, "M.get/1", @s}

      # A claim the code was declined from is no candidate.
      declined =
        Entry.new!(
          at: "2026-10-14T09:00:00Z",
          op: :retire,
          type: :implements,
          note: "not this one",
          ends: [%{kind: :code, id: "M.get/1", hash: "c1"}, %{kind: :spec, id: @h1, hash: "s1"}]
        )

      [get] =
        for p <- Migrate.proposals(scans(), entries() ++ [declined], [@s]),
            p.codes == ["M.get/1"],
            do: p

      assert {get.outcome, Enum.map(get.claims, & &1.claim)} == {:single, [@h2]}
    end

    # A section relation on the baseline, its test baselined at its version (§18.1).
    defp baselined(test) do
      on_baseline = fn e ->
        if code_of_or_nil(e) == "M.list/1" or e.type == :verifies,
          do: Entry.new!(e |> Map.from_struct() |> Map.put(:basis, :baseline)),
          else: e
      end

      Enum.map(entries(), on_baseline) ++
        [
          rel(:tests, {:test, @t2}, {:code, "M.list/1"}, nil),
          Entry.new!(
            at: "2026-10-14T09:00:00Z",
            op: :observe,
            type: :baseline,
            basis: :baseline,
            ends: [%{kind: :test, id: test, hash: "t1"}]
          )
        ]
    end

    defp code_of_or_nil(entry), do: Enum.find_value(entry.ends, &(&1.kind == :code && &1.id))

    @trust [adoption: %{setting: :trust, trusted: :all}]

    @tag verifies: "migrate-baseline"
    test "a baselined section relation carries its baseline to the claim its test verifies" do
      log = baselined(@t2)
      {:ok, recorded} = Migrate.accept(scans(), log, [@s], @meta, @trust)

      carried = Enum.find(recorded, &(&1.op == :relate and code_of(&1) == "M.list/1"))

      assert {carried.basis, spec_of(carried), Map.get(carried, :migrates)} ==
               {:baseline, @h2, @s}

      assert carried.note =~ "baseline carried from #{@s} to its claim #{@h2}"

      # It holds at once, so the section's relation retires in the same accept.
      assert Enum.any?(recorded, &(&1.op == :retire and code_of(&1) == "M.list/1"))
      status = Surfex.Status.derive(scans(), log ++ recorded, [], @trust)
      assert %{state: :current} = state(status, "M.list/1", @h2)
      assert Surfex.Status.validated?(status, state(status, "M.list/1", @h2))
      assert %{state: :retired} = state(status, "M.list/1", @s)

      # The others aren't on the baseline: proposed, as any claim relation.
      helper = Enum.find(recorded, &(&1.op == :relate and code_of(&1) == "M.helper/1"))
      assert helper.basis == :proposed

      # Another baselined test, which doesn't exercise the code, carries nothing.
      {:ok, other} = Migrate.accept(scans(), baselined(@t1), [@s], @meta, @trust)
      list = Enum.find(other, &(&1.op == :relate and code_of(&1) == "M.list/1"))
      assert list.basis == :proposed
      refute Enum.any?(other, &(&1.op == :retire))

      # A changed test version isn't the one the baseline trusted.
      changed = Enum.map(scans(), &if(&1.id == @t2, do: %{&1 | hash: "t2"}, else: &1))
      {:ok, moved} = Migrate.accept(changed, log, [@s], @meta, @trust)
      list = Enum.find(moved, &(&1.op == :relate and code_of(&1) == "M.list/1"))
      assert list.basis == :proposed
    end

    @tag verifies: "migrate-accept"
    test "the reports show what is migrating" do
      {:ok, recorded} = Migrate.accept(scans(), entries(), [@s], @meta)
      status = derive(entries() ++ recorded)
      alias Surfex.Status.Report

      text = Report.text(status)
      assert text =~ "Migrating (a section's implements moving to its claims)"
      assert text =~ "implements  code M.list/1: spec.md#s → spec.md#h2: the section keeps"

      json = Entry.json(Report.json(status))

      assert %{"code" => "M.list/1", "section" => @s, "claims" => [@h2], "settled" => false} in json[
               "migrating"
             ]

      assert Enum.any?(json["relations"], &(&1["migrates"] == @s))

      golden = status |> Report.golden() |> Surfex.Golden.render()
      assert golden =~ "**migrating**"
      assert golden =~ "`:proposed` · migrating"
    end
  end

  @tag verifies: "migrates-entry"
  test "migrates is written only when set, on a proposed or baselined implements" do
    ends = [%{kind: :code, id: "M.f/1", hash: "c1"}, %{kind: :spec, id: @h1, hash: "s1"}]
    base = [at: "2026-10-14T10:00:00Z", op: :relate, type: :implements, ends: ends]

    plain = Entry.new!(base ++ [basis: :proposed])
    refute Entry.encode(plain) =~ "migrates"

    moving = Entry.new!(base ++ [basis: :proposed, migrates: @s])
    assert String.ends_with?(Entry.encode(moving), ~s("basis":"proposed","migrates":"spec.md#s"}))
    assert {:ok, ^moving} = Entry.decode(Entry.encode(moving))
    assert Map.get(Entry.new!(base ++ [basis: :baseline, migrates: @s]), :migrates) == @s

    for bad <- [
          base ++ [basis: :review, migrates: @s],
          [at: "2026-10-14T10:00:00Z", op: :retire, type: :implements, ends: ends, migrates: @s],
          [
            at: "2026-10-14T10:00:00Z",
            op: :relate,
            type: :verifies,
            basis: :proposed,
            ends: [%{kind: :test, id: "T", hash: "t1"}, %{kind: :spec, id: @h1, hash: "s1"}],
            migrates: @s
          ]
        ] do
      assert {:error, "only a proposed or baselined implements carries migrates" <> _} =
               Entry.build(bad)
    end

    assert {:error, _} = Entry.build(base ++ [basis: :proposed, migrates: " "])
  end

  defp code_of(entry), do: Enum.find(entry.ends, &(&1.kind == :code)).id
  defp spec_of(entry), do: Enum.find(entry.ends, &(&1.kind == :spec)).id
end
