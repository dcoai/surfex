defmodule Surfex.DeviationTest do
  # #214: a project adopting surfex over a suite that passed while its code deviated from
  # the spec writes each deviation's test from the spec, sees it fail, and skips it with
  # the issue that will fix the code. The deviating state names that, so the gate can be
  # joined while the deviations are fixed.
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.Report

  @carts "spec.md#Carts"
  @free "spec.md#free-over"
  @add "M.add/2"
  @deviant "T: free delivery over the threshold"
  @plain "T: adds one"

  defp unit_at(id, extra),
    do:
      struct!(
        %Scan{kind: :spec, id: id, hash: "s-#{id}", location: %{file: "spec.md", lines: {3, 9}}},
        extra
      )

  defp test_at(id, line, extra),
    do:
      struct!(
        %Scan{
          kind: :test,
          id: id,
          hash: "t1",
          location: %{file: "test/m_test.exs", lines: {line, line}}
        },
        extra
      )

  # The section, a hint in it, its code, the deviation test verifying the hint (declared
  # with a reference, or not) and a plain test verifying the section.
  defp deviant_world(deviation \\ "#119") do
    [
      unit_at(@carts, role: :section),
      unit_at(@free, role: :test_hint, within: @carts),
      %Scan{kind: :code, id: @add, hash: "c1", location: %{file: "lib/m.ex", lines: {1, 4}}},
      test_at(@deviant, 10, declares: [verifies: "free-over"], deviation: deviation),
      test_at(@plain, 20, declares: [verifies: @carts])
    ]
  end

  defp entry_of(type, {ak, a, ah}, {bk, b, bh}, basis),
    do:
      Entry.new!(
        at: "2026-10-14T10:00:00Z",
        op: :relate,
        type: type,
        basis: basis,
        ends: [%{kind: ak, id: a, hash: ah}, %{kind: bk, id: b, hash: bh}]
      )

  # The deviation test's verifies, recorded on its red run; the plain test's, by review;
  # the section's implements, cited and so only proposed: nothing can validate it while
  # the code deviates.
  defp deviant_log(implements_basis \\ :proposed),
    do: [
      entry_of(:verifies, {:test, @deviant, "t1"}, {:spec, @free, "s-#{@free}"}, :evidence),
      entry_of(:verifies, {:test, @plain, "t1"}, {:spec, @carts, "s-#{@carts}"}, :review),
      entry_of(:implements, {:code, @add, "c1"}, {:spec, @carts, "s-#{@carts}"}, implements_basis)
    ]

  defp ran(test, result, n \\ 1),
    do: %{
      test: test,
      test_hash: "t1",
      result: result,
      at: "2026-10-14T1#{n}:00:00Z",
      run: "r#{n}",
      seq: 0,
      code: if(result in [:passed, :failed], do: %{@add => "c1"}, else: %{})
    }

  describe "status" do
    @describetag verifies: ["deviating-status", "status-states"]

    @tag verifies: ["deviating-status", "status-failing", "status-report-forms"]
    test "a deviating unit is listed with its reference, and its proposed relations don't fail" do
      status = Status.derive(deviant_world(), deviant_log())

      assert status.deviating == [%{spec: @free, test: @deviant, ref: "#119", run: nil}]

      # The section's implements sits over the deviating hint: proposed, deviating, passing.
      implements = Enum.find(status.relations, &(&1.type == :implements))
      assert %{state: :proposed, deviates: ["#119"]} = implements
      refute Status.failing?(status)

      text = Report.text(status)
      assert text =~ "relation status: ok"
      assert text =~ "Deviating (a test declares the code doesn't meet the unit yet)"

      assert text =~
               "spec #{@free} (spec.md:3-9): #119, declared by test #{@deviant}"

      assert text =~ "implements  code #{@add} ↔ spec #{@carts} (deviates: #119)"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert json["failing"] == false

      assert json["deviating"] == [
               %{
                 "spec" => @free,
                 "test" => @deviant,
                 "ref" => "#119",
                 "run" => nil,
                 "stale" => false
               }
             ]

      assert Enum.find(json["relations"], &(&1["type"] == "implements"))["deviates"] == ["#119"]

      golden = status |> Report.golden() |> Surfex.Golden.render()
      assert golden =~ "## deviating"
      assert golden =~ "`spec #{@free}` | #119 | `test #{@deviant}`"
      assert golden =~ "`:proposed` · deviates"

      # A release's check: every deviation fails it.
      held = Status.derive(deviant_world(), deviant_log(), [], deviations: :fail)
      assert Status.failing?(held)

      assert_raise ArgumentError, ~r/deviations: must be :allow or :fail/, fn ->
        Status.derive(deviant_world(), deviant_log(), [], deviations: :maybe)
      end
    end

    test "without the tag, the same proposed relation fails as any does" do
      status = Status.derive(deviant_world(nil), deviant_log())
      assert status.deviating == []

      assert %{state: :proposed, deviates: []} =
               Enum.find(status.relations, &(&1.type == :implements))

      assert Status.failing?(status)
    end

    test "only proposed relations deviate: a dangling one still fails" do
      # The plain test's verifies changed under it: dangling, not excused.
      log =
        deviant_log()
        |> List.replace_at(
          1,
          entry_of(:verifies, {:test, @plain, "t0"}, {:spec, @carts, "s-#{@carts}"}, :review)
        )

      status = Status.derive(deviant_world(), log)

      assert %{state: :dangling, deviates: []} =
               Enum.find(
                 status.relations,
                 &match?(%{relation: {:verifies, {:test, @plain}, _}}, &1)
               )

      assert Status.failing?(status)
    end

    test "the deviation test's own verifies, and the unit's implements, deviate when proposed" do
      log = [
        entry_of(:verifies, {:test, @deviant, "t1"}, {:spec, @free, "s-#{@free}"}, :proposed),
        entry_of(:implements, {:code, @add, "c1"}, {:spec, @free, "s-#{@free}"}, :proposed),
        entry_of(:verifies, {:test, @plain, "t1"}, {:spec, @carts, "s-#{@carts}"}, :review)
      ]

      status = Status.derive(deviant_world(), log)

      assert Enum.map(status.relations, &{&1.type, &1.state, &1.deviates}) |> Enum.sort() == [
               {:implements, :proposed, ["#119"]},
               {:verifies, :current, []},
               {:verifies, :proposed, ["#119"]}
             ]

      refute Status.failing?(status)
    end

    @tag verifies: ["deviating-status", "status-failing"]
    test "a deviation tag on a test that declares no unit is broken" do
      world = [test_at("T: nothing", 30, deviation: "#7") | deviant_world()]
      status = Status.derive(world, deviant_log())

      assert [%{type: :deviation, ref: "#7", reason: :no_unit, scan: %{id: "T: nothing"}}] =
               status.broken

      assert Status.failing?(status)

      assert Report.text(status) =~
               ~s(test T: nothing deviation "#7": the test declares no spec unit to deviate from)
    end
  end

  describe "a deviation test's runs" do
    @describetag verifies: "deviation-runs"

    @tag verifies: ["deviation-runs", "evidence-failed", "status-failing"]
    test "a failed deviation test is listed with its deviation, not as failed" do
      status =
        Status.derive(deviant_world(), deviant_log(), [], evidence: [ran(@deviant, :failed)])

      assert status.failed == []
      assert status.unproven == []
      assert [%{run: :failed}] = status.deviating
      refute Status.failing?(status)
      assert Report.text(status) =~ "(failed in this run, as declared)"

      # Untagged, the same failure fails its relations and the check.
      untagged =
        Status.derive(deviant_world(nil), deviant_log(:review), [],
          evidence: [ran(@deviant, :failed)]
        )

      assert [%{test: @deviant}] = untagged.failed
      assert Status.failing?(untagged)
    end

    @tag verifies: ["deviation-runs", "status-failing", "status-report-forms"]
    test "a deviation test that passed is a stale deviation, and fails" do
      status =
        Status.derive(deviant_world(), deviant_log(), [], evidence: [ran(@deviant, :passed)])

      assert [%{run: :passed}] = status.deviating
      assert Status.failing?(status)

      text = Report.text(status)
      assert text =~ "Stale deviations (a deviation test passed: drop the tag and validate)"
      assert text =~ "passed in this run: the code meets it now, so drop the tag and validate"
      refute text =~ "Deviating (a test declares"

      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert [%{"run" => "passed", "stale" => true}] = json["deviating"]

      # The golden is the ledger, not the run: no result in it.
      refute status |> Report.golden() |> Surfex.Golden.render() =~ "passed"

      # A pass in any job's evidence makes it stale.
      merged = {:merged, [[ran(@deviant, :failed)], [ran(@deviant, :passed, 2)]]}
      assert Status.failing?(Status.derive(deviant_world(), deviant_log(), [], evidence: merged))

      # A pass of another version of the test says nothing of this one.
      other = %{ran(@deviant, :passed) | test_hash: "t0"}
      stale_free = Status.derive(deviant_world(), deviant_log(), [], evidence: [other])
      assert [%{run: nil}] = stale_free.deviating
      refute Status.failing?(stale_free)
    end

    test "skipped, or without evidence, nothing is judged stale" do
      for evidence <- [[ran(@deviant, :skipped)], [ran(@deviant, :excluded)], []] do
        status = Status.derive(deviant_world(), deviant_log(), [], evidence: evidence)
        refute Status.failing?(status), inspect(evidence)
      end

      assert [%{run: :skipped}] =
               Status.derive(deviant_world(), deviant_log(), [],
                 evidence: [ran(@deviant, :skipped)]
               ).deviating

      assert [%{run: nil}] = Status.derive(deviant_world(), deviant_log()).deviating
    end
  end

  describe "completeness" do
    @describetag verifies: "completeness-deviates"

    defp missing_of(report, id),
      do: Enum.find_value(report.incomplete, &(&1.id == id && &1.missing))

    test "a deviating unit is incomplete, deviates, whatever validated its relations" do
      # Its verifies, recorded on the red run, is validated: alone it would count complete.
      report = Completeness.report(Status.derive(deviant_world(), deviant_log()))
      assert missing_of(report, @free) == [{:deviates, ["#119"]}]

      assert Completeness.text(report) =~ "spec #{@free} (spec.md:3-9): deviates (#119)"

      {json, :ok, _} = report |> Completeness.json() |> :json.decode(:ok, %{null: nil})

      assert %{"missing" => ["deviates (#119)"]} =
               Enum.find(json["incomplete"], &(&1["id"] == @free))

      assert report |> Completeness.golden("COMPLETENESS.md") |> Surfex.Golden.render() =~
               "`spec #{@free}` | deviates (#119)"

      # With no code cited, the same.
      no_code = Enum.reject(deviant_log(), &(&1.type == :implements))
      report = Completeness.report(Status.derive(deviant_world(), no_code))
      assert missing_of(report, @free) == [{:deviates, ["#119"]}]

      # Two deviation tests on one unit: both references.
      second =
        test_at("T: free over, again", 40, declares: [verifies: "free-over"], deviation: "#120")

      log =
        no_code ++
          [
            entry_of(
              :verifies,
              {:test, "T: free over, again", "t1"},
              {:spec, @free, "s-#{@free}"},
              :evidence
            )
          ]

      report = Completeness.report(Status.derive([second | deviant_world()], log))
      assert missing_of(report, @free) == [{:deviates, ["#119", "#120"]}]
    end

    @tag verifies: ["completeness-deviates", "deviating-status"]
    test "with the tag removed after the fix, the unit validates by the process and completes" do
      # The fix landed: the tag comes off, and until the relations are validated the
      # proposed implements fails as any does.
      fixed = deviant_world(nil)
      before = Status.derive(fixed, deviant_log())
      assert Status.failing?(before)

      # Validated by evidence (its test went red, then green against the fix): complete.
      validated = Status.derive(fixed, deviant_log(:evidence))
      refute Status.failing?(validated)
      assert validated.deviating == []
      assert missing_of(Completeness.report(validated), @free) == nil
    end
  end
end
