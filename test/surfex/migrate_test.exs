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
      test_scan(@t1, ["M.get/1"]),
      test_scan(@t2, ["M.get/1", "M.list/1"])
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
end
