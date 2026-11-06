defmodule Surfex.MigrateCallersTest do
  # #289, #374: a none reads as a dead end, when usually a test already calls the code and only
  # the claim it checks has no name yet.
  use ExUnit.Case, async: true
  @moduletag verifies: "migrate-none-callers"

  alias Surfex.{Migrate, Scan}
  alias Surfex.Log.Entry
  alias Surfex.Status.Callers

  @section "spec.md#s"
  @hint "spec.md#h"
  @elsewhere "spec.md#other"
  @at "2026-11-06T10:00:00Z"

  defp spec(id, role, within \\ nil),
    do: %Scan{
      kind: :spec,
      id: id,
      hash: "h-#{id}",
      role: role,
      within: within,
      location: %{file: "spec.md", lines: {1, 2}}
    }

  defp code(id, lines, calls \\ []),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "c-#{id}",
      role: :function,
      calls: calls,
      location: %{file: "lib/m.ex", lines: lines}
    }

  defp test_scan(id, declares, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t-#{id}",
      calls: calls,
      declares: Enum.map(declares, &{:verifies, &1}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp scans do
    [
      spec(@section, :section),
      spec(@hint, :test_hint, @section),
      spec(@elsewhere, :section),
      code("M.called/1", {1, 2}),
      code("M.entry/1", {3, 4}, ["M.deep/1"]),
      code("M.deep/1", {5, 6}),
      code("M.alone/1", {7, 8}),
      test_scan("T: one", [@elsewhere], ["M.called/1"]),
      test_scan("T: two", [@elsewhere], ["M.called/1"]),
      test_scan("T: three", [@elsewhere], ["M.called/1"]),
      test_scan("T: four", [@elsewhere], ["M.called/1"]),
      test_scan("T: through", [@elsewhere], ["M.entry/1"])
    ]
  end

  defp implements(scans, code_id) do
    code = Enum.find(scans, &(&1.id == code_id))

    Entry.new!(
      at: @at,
      op: :relate,
      type: :implements,
      basis: :review,
      note: "checked",
      ends: [
        %{kind: :code, id: code.id, hash: code.hash},
        %{kind: :spec, id: @section, hash: "h-#{@section}"}
      ]
    )
  end

  defp entries(scans), do: for(c <- ~w(M.called/1 M.deep/1 M.alone/1), do: implements(scans, c))

  defp proposal(world, code),
    do:
      world
      |> Migrate.proposals(entries(world), [@section])
      |> Enum.find(&(code in &1.codes))

  test "the lookup gives each test calling or reaching code, and whether it verifies here" do
    index = Callers.index(scans())
    code = Enum.find(scans(), &(&1.id == "M.called/1"))

    assert [
             %{test: "T: four", how: :calls, verifies_here: true},
             %{test: "T: one", how: :calls, verifies_here: false},
             %{test: "T: three", how: :calls, verifies_here: false},
             %{test: "T: two", how: :calls, verifies_here: false}
           ] = Callers.of(index, code, MapSet.new(["T: four"]))

    deep = Enum.find(scans(), &(&1.id == "M.deep/1"))
    assert [%{test: "T: through", how: :reaches}] = Callers.of(index, deep, MapSet.new())
    assert [] = Callers.of(index, Enum.find(scans(), &(&1.id == "M.alone/1")), MapSet.new())

    # A test verifying a claim here, its pair declined so it isn't a candidate, says so.
    world = [test_scan("T: here", [@hint], ["M.called/1"]) | scans()]
    related = implements(world, "M.called/1")
    hint = Enum.find(world, &(&1.id == @hint))
    code = Enum.find(world, &(&1.id == "M.called/1"))

    declined =
      Entry.new!(
        at: @at,
        op: :retire,
        type: :implements,
        note: "not this claim",
        ends: [
          %{kind: :code, id: code.id, hash: code.hash},
          %{kind: :spec, id: hint.id, hash: hint.hash}
        ]
      )

    assert [%{outcome: :none, callers: callers}] =
             Migrate.proposals(world, [related, declined], [@section])

    assert %{verifies_here: true} = Enum.find(callers, &(&1.test == "T: here"))
    assert Migrate.callers_text(callers) =~ "1 verifying a claim here"
  end

  test "a none proposal carries its callers, in the proposal and the report's JSON" do
    world = scans()

    assert %{outcome: :none, callers: [%{test: "T: four", verifies_here: false} | _] = four} =
             proposal(world, "M.called/1")

    assert length(four) == 4
    assert %{outcome: :none, callers: [%{how: :reaches}]} = proposal(world, "M.deep/1")
    assert %{outcome: :none, callers: []} = proposal(world, "M.alone/1")

    json =
      world
      |> Migrate.report(entries(world), [@section])
      |> Migrate.json()
      |> JSON.decode!()

    widths = hd(json["sections"])["widths"]

    assert %{
             "callers" => [
               %{"how" => "reaches", "test" => "T: through", "verifies_here" => false}
             ]
           } =
             Enum.find(widths, &(&1["codes"] == ["M.deep/1"]))
  end

  test "the listing's words: who calls it, and what to do" do
    world = scans()
    line = &Migrate.callers_text(proposal(world, &1).callers)

    assert line.("M.called/1") =~
             "called by 4 tests (T: four, T: one, T: three and 1 more), none verifying a claim " <>
               "here: name the claim they check"

    assert line.("M.deep/1") =~
             "reached by 1 test (T: through), none verifying a claim here: name the claim it checks"

    assert line.("M.alone/1") =~ "no test calls it"
  end
end
