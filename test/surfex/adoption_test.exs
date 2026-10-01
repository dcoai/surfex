defmodule Surfex.AdoptionTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Record, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.{Config, Report}

  @unit "spec.md#totals"
  @code "M.add/2"
  @core "T: core"
  @legacy "T: legacy"
  @meta [by: "tester", commit: "abc", at: "2026-10-01T10:00:00Z", note: "adopting the suite"]

  # The suite on disk, so adoption: globs have files to match.
  defp suite(root) do
    for file <- ~w(test/core/a_test.exs test/legacy/b_test.exs) do
      File.mkdir_p!(Path.dirname(Path.join(root, file)))
      File.write!(Path.join(root, file), "")
    end

    [tests: ["test/**/*_test.exs"]]
  end

  defp adoption(root, setting), do: Config.adoption!(suite(root) ++ [adoption: setting], root)

  defp scans(code \\ "c1", core \\ "t1") do
    loc = &%{file: &1, lines: {1, 1}}

    [
      %Scan{kind: :spec, id: @unit, hash: "s1", location: loc.("spec.md")},
      %Scan{kind: :code, id: @code, hash: code, location: %{file: "lib/m.ex", lines: {3, 5}}},
      %Scan{
        kind: :test,
        id: @core,
        hash: core,
        location: loc.("test/core/a_test.exs"),
        declares: [{:verifies, @unit}],
        calls: [@code]
      },
      %Scan{
        kind: :test,
        id: @legacy,
        hash: "l1",
        location: loc.("test/legacy/b_test.exs"),
        declares: [{:verifies, @unit}],
        calls: [@code]
      }
    ]
  end

  defp run(test, test_hash, result, code, n),
    do: %{
      test: test,
      test_hash: test_hash,
      result: result,
      at: "2026-10-01T1#{n}:00:00Z",
      run: "r#{n}",
      seq: 0,
      code: %{@code => code}
    }

  defp green(code \\ "c1", n \\ 1),
    do: [run(@core, "t1", :passed, code, n), run(@legacy, "l1", :passed, code, n)]

  # What adoption leaves before the baseline: a cited implements (proposed) and the tests'
  # structural relations to the code they call.
  defp adopted(scans) do
    {:ok, [impl]} = Record.relate(scans, [], @unit, @code, :implements, @meta)
    {:ok, [t1]} = Record.relate(scans, [impl], "test:" <> @core, @code, :tests, @meta)
    {:ok, [t2]} = Record.relate(scans, [impl, t1], "test:" <> @legacy, @code, :tests, @meta)
    [impl, t1, t2]
  end

  defp baseline(root, setting, entries \\ nil) do
    entries = entries || adopted(scans())
    meta = Keyword.put(@meta, :adoption, adoption(root, setting))
    {Record.baseline(scans(), entries, green(), meta), entries}
  end

  defp by_type(entries, type), do: Enum.filter(entries, &(&1.type == type))

  # Recording under an adoption setting: Record reads it from meta.
  defp trusting(adoption), do: Keyword.put(@meta, :adoption, adoption)

  describe "adoption:" do
    @describetag verifies: "adoption-modes"

    test "is :reevaluate by default, :trust, or trusted and re-evaluated globs", %{tmp_dir: root} do
      config = suite(root)
      default = Config.adoption!(config, root)
      assert default.setting == :reevaluate
      refute Config.trusted?(default, "test/core/a_test.exs")

      all = adoption(root, :trust)
      assert Config.trusted?(all, "test/core/a_test.exs")
      assert Config.trusted?(all, "test/legacy/b_test.exs")

      area =
        adoption(root, trust: ["test/core/*_test.exs"], reevaluate: ["test/legacy/*_test.exs"])

      assert Config.trusted?(area, "test/core/a_test.exs")
      refute Config.trusted?(area, "test/legacy/b_test.exs")
    end

    test "refuses globs outside tests:, overlapping globs and anything else", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "other"))
      File.write!(Path.join(root, "other/c_test.exs"), "")

      assert_raise ArgumentError, ~r/adoption: .*outside tests:/, fn ->
        adoption(root, trust: ["other/*_test.exs"], reevaluate: [])
      end

      assert_raise ArgumentError, ~r/adoption: .*overlap/, fn ->
        adoption(root, trust: ["test/**/*_test.exs"], reevaluate: ["test/legacy/*_test.exs"])
      end

      for bad <- [:maybe, [trust: "test/*"], [keep: []]] do
        assert_raise ArgumentError, ~r/adoption: must be :reevaluate, :trust/, fn ->
          adoption(root, bad)
        end
      end
    end
  end

  describe "the baseline" do
    @describetag verifies: "baseline-one-shot"

    test "records each trusted test version and its declared verifies, basis baseline", %{
      tmp_dir: root
    } do
      {{:ok, recorded}, _} = baseline(root, :trust)

      assert [%Entry{op: :observe, basis: :baseline} | _] = seen = by_type(recorded, :baseline)

      assert Enum.map(seen, &hd(&1.ends)) |> Enum.sort_by(& &1.id) == [
               %{kind: :test, id: @core, hash: "t1"},
               %{kind: :test, id: @legacy, hash: "l1"}
             ]

      assert Enum.all?(seen, &(&1.note =~ "adoption: :trust" and &1.note =~ "adopting the suite"))

      assert [%Entry{op: :relate, basis: :baseline}, %Entry{basis: :baseline}] =
               verifies = by_type(recorded, :verifies)

      assert Enum.all?(verifies, &(%{kind: :spec, id: @unit, hash: "s1"} in &1.ends))
    end

    test "per area, only the trusted tests", %{tmp_dir: root} do
      setting = [trust: ["test/core/*_test.exs"], reevaluate: ["test/legacy/*_test.exs"]]
      {{:ok, recorded}, _} = baseline(root, setting)
      assert [%Entry{ends: [%{id: @core}]}] = by_type(recorded, :baseline)
      assert [%Entry{ends: ends}] = by_type(recorded, :verifies)
      assert %{kind: :test, id: @core, hash: "t1"} in ends
    end

    test "refuses under :reevaluate, a second time, without tests, or before a green run", %{
      tmp_dir: root
    } do
      assert {{:error, "adoption: is :reevaluate" <> _}, _} = baseline(root, :reevaluate)

      {{:ok, recorded}, entries} = baseline(root, :trust)

      assert {{:error, "a baseline was already taken" <> _}, _} =
               baseline(root, :trust, entries ++ recorded)

      meta = Keyword.put(@meta, :adoption, adoption(root, :trust))
      no_tests = Enum.reject(scans(), &(&1.kind == :test))
      assert {:error, "no tests are scanned" <> _} = Record.baseline(no_tests, [], [], meta)

      assert {:error, "1 trusted test hasn't run green" <> _} =
               Record.baseline(scans(), adopted(scans()), tl(green()), meta)

      assert {:error, "a note is required" <> _} =
               Record.baseline(scans(), [], green(), Keyword.delete(meta, :note))
    end
  end

  describe "trust shrinks" do
    @describetag verifies: "baseline-shrinks"

    # Adopted under :trust, the baseline taken, and implements confirmed through it.
    defp trusted(root) do
      {{:ok, recorded}, entries} = baseline(root, :trust)
      log = entries ++ recorded
      trust = adoption(root, :trust)
      {:ok, confirmed} = Record.confirm_by_evidence(scans(), log, green(), trusting(trust))
      {log ++ confirmed, trust}
    end

    test "a baselined test carries implements, and re-confirms a refactor, as baseline", %{
      tmp_dir: root
    } do
      {log, trust} = trusted(root)
      assert [%Entry{basis: :baseline}] = by_type(log, :implements) |> Enum.take(-1)
      assert Status.derive(scans(), log, [], adoption: trust).unvalidated == []

      # A refactor (c2) on a fresh checkout: green is enough, and it stays trusted.
      {:ok, refactored} =
        Record.confirm_by_evidence(scans("c2"), log, green("c2", 2), trusting(trust))

      assert refactored |> Enum.map(&{&1.type, &1.basis}) |> Enum.sort() == [
               implements: :baseline,
               tests: :baseline,
               tests: :baseline
             ]
    end

    test "a test's first red→green moves its relations to evidence", %{tmp_dir: root} do
      {log, trust} = trusted(root)
      evidence = [run(@core, "t1", :failed, "c2", 2), run(@core, "t1", :passed, "c3", 3)]
      {:ok, moved} = Record.confirm_by_evidence(scans("c3"), log, evidence, trusting(trust))

      assert [%Entry{type: :red_green}] = by_type(moved, :red_green)
      assert [%Entry{basis: :evidence}] = by_type(moved, :implements)
    end

    test "a changed test version, or narrowed trust, leaves its relations unvalidated", %{
      tmp_dir: root
    } do
      {log, trust} = trusted(root)

      # The core test changed (t9): its baseline record doesn't speak for the new version.
      changed = Status.derive(scans("c1", "t9"), log, [], adoption: trust)
      refute MapSet.member?(changed.baselined, {@core, "t9"})

      # Trust narrowed to nothing: every baseline relation is now unvalidated.
      narrowed = Status.derive(scans(), log, [], adoption: adoption(root, :reevaluate))
      assert narrowed.baselined == MapSet.new()
      [implements] = Enum.filter(narrowed.relations, &(&1.type == :implements))
      refute Status.validated?(narrowed, implements)
      assert Enum.any?(narrowed.unvalidated, &match?(%{relation: {:implements, _, _}}, &1))
      assert Enum.any?(narrowed.unvalidated, &match?(%{relation: {:verifies, _, _}}, &1))
    end

    test "baseline relations are counted with the mode, and fail under baseline: :fail", %{
      tmp_dir: root
    } do
      {log, trust} = trusted(root)
      status = Status.derive(scans(), log, [], adoption: trust)
      assert Status.baseline_count(status) == 3
      claims = Enum.filter(status.relations, &(&1.type in [:implements, :verifies]))
      assert Enum.all?(claims, &Status.validated?(status, &1))

      assert Report.text(status) =~ "  baseline: 3 relations (adoption: :trust)"
      {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})
      assert json["baseline"] == %{"relations" => 3, "adoption" => ":trust"}
      assert status |> Report.golden() |> Surfex.Golden.render() =~ "baseline 3"

      refute Status.failing?(status)
      assert Status.failing?(Status.derive(scans(), log, [], adoption: trust, baseline: :fail))
      assert Surfex.Completeness.report(status).scores.overall.percent == 100.0
    end
  end
end
