defmodule Surfex.DeviationHoldsTest do
  # #255: a deviation says the code doesn't meet a unit yet, so neither confirm --evidence
  # nor earning may treat the code as meeting that unit or a section holding it (§13.11).
  use ExUnit.Case, async: true

  alias Surfex.{Record, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Report

  @spec_text """
  ## Shop
  <!-- surfex: shop -->

  The shop sells carts.

  ### Carts
  <!-- surfex: carts -->

  A cart holds items.

  ```test:free-over
  delivery is free over the threshold
  ```
  """

  @shop "spec.md#shop"
  @carts "spec.md#carts"
  @free "spec.md#free-over"
  @add "M.add/2"
  @deviant "T: free delivery over the threshold"
  @plain "T: adds one"
  @top "T: the shop sells"
  @at "2026-10-14T10:00:00Z"

  defp code,
    do: %Scan{
      kind: :code,
      id: @add,
      hash: "c-new",
      role: :function,
      calls: [],
      location: %{file: "lib/m.ex", lines: {1, 4}}
    }

  defp test_scan(id, line, verifies, extra \\ []),
    do:
      struct!(
        %Scan{
          kind: :test,
          id: id,
          hash: "#{id}-h",
          calls: [@add],
          declares: Enum.map(verifies, &{:verifies, &1}),
          location: %{file: "test/m_test.exs", lines: {line, line}}
        },
        extra
      )

  # The shop, the carts section under it and the hint in carts; the deviation test on the
  # hint (tagged with `deviation`, or not), a plain test verifying carts and the hint, and
  # a test verifying the shop.
  defp world(deviation \\ "#119") do
    Markdown.sections(@spec_text, "spec.md") ++
      [
        code(),
        test_scan(@deviant, 10, [@free], deviation: deviation),
        test_scan(@plain, 20, [@carts, @free]),
        test_scan(@top, 30, [@shop])
      ]
  end

  defp entry(type, a, b, basis),
    do:
      Entry.new!(
        at: @at,
        op: :relate,
        type: type,
        basis: basis,
        by: "t",
        note: if(basis == :proposed, do: nil, else: "checked"),
        ends: [%{kind: a.kind, id: a.id, hash: a.hash}, %{kind: b.kind, id: b.id, hash: b.hash}]
      )

  # The plain and shop tests' verifies reviewed, the deviation test's proposed, and the
  # code's implements of the hint, carts and the shop proposed.
  defp log(scans) do
    by_id = Map.new(scans, &{&1.id, &1})

    [
      entry(:verifies, by_id[@deviant], by_id[@free], :proposed),
      entry(:verifies, by_id[@plain], by_id[@carts], :review),
      entry(:verifies, by_id[@plain], by_id[@free], :review),
      entry(:verifies, by_id[@top], by_id[@shop], :review)
      | for(
          unit <- [@free, @carts, @shop],
          do: entry(:implements, by_id[@add], by_id[unit], :proposed)
        )
    ]
  end

  defp run(test, result, code_hash, n),
    do: %{
      test: test,
      test_hash: "#{test}-h",
      result: result,
      at: "2026-10-14T1#{n}:00:00Z",
      run: "r#{n}",
      seq: 0,
      code: %{@add => code_hash}
    }

  # Each passing test failed against old code and passed against the code as it is; the
  # deviation test failed.
  defp evidence,
    do: [
      run(@plain, :failed, "c-old", 1),
      run(@top, :failed, "c-old", 1),
      run(@deviant, :failed, "c-old", 1),
      run(@plain, :passed, "c-new", 2),
      run(@top, :passed, "c-new", 2)
    ]

  defp implements(entries),
    do:
      for(
        %Entry{type: :implements, ends: [_, %{id: unit}]} <- entries,
        do: unit
      )
      |> Enum.sort()

  describe "confirm by evidence" do
    @describetag verifies: ["deviation-holds-back", "deviation-holds"]

    test "holds back the hint's and its section's implements, and still records the verifies" do
      scans = world()

      assert {:ok, recorded, held} = Record.evidence_outcome(scans, log(scans), evidence(), [])

      # The section above carts isn't held without claim_grain: its implements is recorded.
      assert implements(recorded) == [@shop]

      assert Enum.any?(
               recorded,
               &match?(%Entry{type: :verifies, ends: [%{id: @deviant}, %{id: @free}]}, &1)
             )

      assert held == [
               %{relation: {:implements, {:code, @add}, {:spec, @carts}}, deviates: ["#119"]},
               %{relation: {:implements, {:code, @add}, {:spec, @free}}, deviates: ["#119"]}
             ]

      # confirm_by_evidence/4 records the same, and never what is held.
      assert {:ok, ^recorded} = Record.confirm_by_evidence(scans, log(scans), evidence(), [])
    end

    test "under claim_grain: a section the deviating one sits under is held too" do
      scans = world()

      assert {:ok, recorded, held} =
               Record.evidence_outcome(scans, log(scans), evidence(), claim_grain: true)

      assert implements(recorded) == []

      assert Enum.map(held, fn %{relation: {_, _, {:spec, unit}}} -> unit end) ==
               [@carts, @free, @shop]

      # The derive says the same: the shop is held, and marks its proposed relation.
      status = Status.derive(scans, log(scans), [], claim_grain: true)
      assert status.held == %{@free => ["#119"], @carts => ["#119"], @shop => ["#119"]}

      assert %{deviates: ["#119"]} =
               Enum.find(
                 status.relations,
                 &(&1.relation == {:implements, {:code, @add}, {:spec, @shop}})
               )

      assert Status.derive(scans, log(scans)).held == %{@free => ["#119"], @carts => ["#119"]}
    end

    test "with the tag off and the test passing, the next run validates them" do
      scans = world()

      {:ok, first, _held} =
        Record.evidence_outcome(scans, log(scans), evidence(), claim_grain: true)

      fixed = world(nil)
      green = evidence() ++ [run(@deviant, :passed, "c-new", 3)]

      assert {:ok, recorded, []} =
               Record.evidence_outcome(fixed, log(fixed) ++ first, green, claim_grain: true)

      assert implements(recorded) == [@carts, @free, @shop]
    end
  end

  describe "earning" do
    @describetag verifies: ["deviation-unearned", "deviation-holds"]

    # Every relation validated, so only earning decides.
    defp validated(scans) do
      by_id = Map.new(scans, &{&1.id, &1})

      [
        entry(:verifies, by_id[@plain], by_id[@carts], :review),
        entry(:verifies, by_id[@plain], by_id[@free], :review),
        entry(:verifies, by_id[@top], by_id[@shop], :review)
        | for(
            unit <- [@free, @carts, @shop],
            do: entry(:implements, by_id[@add], by_id[unit], :review)
          )
      ]
    end

    test "under claim_grain: an implements to a held unit is unearned as deviates" do
      scans = world()
      status = Status.derive(scans, validated(scans), [code: [:implements]], claim_grain: true)

      # Each is verified and exercised; the deviation alone holds it.
      for unit <- [@free, @carts, @shop] do
        assert Status.earning(status, {:implements, {:code, @add}, {:spec, unit}}) ==
                 {:unearned, :deviates}
      end

      assert status.unearned ==
               for(unit <- [@carts, @free, @shop], do: %{code: @add, unit: unit, why: :deviates})

      assert [%{scan: %Scan{id: @add}, why: :unearned}] =
               Enum.filter(status.unmet, &(&1.scan.id == @add))

      assert Report.text(status) =~
               "implements  code #{@add} → spec #{@shop}: deviates: a test declares the code doesn't meet the unit"

      # The tag off: the same relations earn.
      fixed = world(nil)
      earned = Status.derive(fixed, validated(fixed), [code: [:implements]], claim_grain: true)
      assert earned.unearned == []
    end

    test "without claim_grain: earning reads as before" do
      scans = world()
      status = Status.derive(scans, validated(scans), code: [:implements])

      assert status.unearned == []
      assert status.earning.held == %{}

      assert Status.earning(status, {:implements, {:code, @add}, {:spec, @free}}) == :earned
    end
  end
end
