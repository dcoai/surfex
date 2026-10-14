defmodule Surfex.ChecksTest do
  # #207 (B.3), #245: declared checks verify claims. A gate (a lint rule, a project's own
  # verification task) is a scan record of kind :check, versioned over its declaration and
  # its inputs, whose runs are evidence a test's form, so it discriminates as a test does.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Check, Completeness, Record, Scan, Status}
  alias Surfex.Status.{Config, Report}

  @spec_md """
  # App

  ## Rules
  <!-- surfex: rules-sec -->

  No function rescues.

  ```test:plat-3
  no rescue anywhere in lib
  ```

  ## Layout

  <!-- surfex: table layout -->
  | Field | Offset |
  |---|---|
  | a | 0 |
  | b | 4 |
  """

  @meta [by: "tester", commit: "abc"]

  defp checks(overrides \\ []) do
    [
      Keyword.merge(
        [id: "no-rescue", run: "check-rescue", verifies: ["plat-3"], inputs: ["rules.txt"]],
        overrides
      ),
      [id: "layout", run: "check-layout", verifies: "layout/*", inputs: ["lib/*.ex"]]
    ]
  end

  defp config(checks \\ checks()), do: [sources: ["spec.md"], checks: checks]

  defp project(root, files \\ %{}) do
    defaults = %{
      "spec.md" => @spec_md,
      "rules.txt" => "deny rescue\n",
      "lib/app.ex" => "defmodule App do\n  def f, do: 1\nend\n",
      "README.md" => "about\n"
    }

    for {path, text} <- Map.merge(defaults, files) do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    root
  end

  defp scans(root, config \\ config()), do: Config.scans(config, root)

  defp check(scans, id), do: Enum.find(scans, &(&1.kind == :check and &1.id == id))

  # A run of the checks, each passing (exit 0) or failing (exit 1) as `result` says, at a
  # fixed time so the evidence orders as written.
  defp run(scans, ids, result, at) do
    {:ok, selected} = Check.select(scans, ids)

    Check.run(selected, "/nowhere", fn _command, _root ->
      if result == :passed, do: 0, else: 1
    end)
    |> Enum.map(&%{&1 | at: at})
  end

  defp relate!(scans, entries, from, to, type) do
    {:ok, recorded} = Record.relate(scans, entries, from, to, type, @meta)
    entries ++ recorded
  end

  describe "check records" do
    @describetag verifies: "check-records"

    test "a check is a record of kind check, declaring what it verifies", %{tmp_dir: root} do
      scans = root |> project() |> scans()
      rescue_check = check(scans, "no-rescue")

      assert %Scan{kind: :check, location: %{file: ".surfex.exs", lines: nil}} = rescue_check
      assert rescue_check.declares == [{:verifies, "plat-3"}]
      assert %{run: "check-rescue", inputs: %{"rules.txt" => _}} = rescue_check.check

      assert rescue_check.hash ==
               Scan.Checks.version(rescue_check.check.declaration, rescue_check.check.inputs)
    end

    test "TABLE/* declares each row of the table", %{tmp_dir: root} do
      scans = root |> project() |> scans()

      assert check(scans, "layout").declares ==
               [{:verifies, "spec.md#layout/a"}, {:verifies, "spec.md#layout/b"}]
    end

    test "its version changes with its command, verifies, input globs and inputs' content",
         %{tmp_dir: root} do
      project(root)
      version = fn config -> check(scans(root, config), "no-rescue").hash end
      base = version.(config())

      assert version.(config(checks(run: "other"))) != base
      assert version.(config(checks(verifies: ["plat-3", "layout"]))) != base
      assert version.(config(checks(inputs: ["rules.txt", "README.md"]))) != base

      File.write!(Path.join(root, "rules.txt"), "deny rescue and catch\n")
      changed = version.(config())
      assert changed != base

      File.write!(Path.join(root, "README.md"), "about something else\n")
      File.write!(Path.join(root, "lib/other.ex"), "defmodule Other do\nend\n")
      assert version.(config()) == changed
    end

    test "a malformed check, a repeated id or an input matching no file raises",
         %{tmp_dir: root} do
      project(root)
      raises = fn checks -> assert_raise ArgumentError, fn -> scans(root, config(checks)) end end

      raises.(:not_a_list)
      raises.([["id", "run"]])
      raises.(checks(id: "has space"))
      raises.(checks(id: nil))
      raises.(checks(run: ""))
      raises.(checks(verifies: []))
      raises.(checks(verifies: [:atom]))
      raises.(checks(inputs: "rules.txt"))
      raises.(checks(colour: "red"))
      raises.(checks(id: "layout"))

      assert_raise ArgumentError, ~r/matches no file/, fn ->
        scans(root, config(checks(inputs: ["missing/*.txt"])))
      end
    end
  end

  describe "running checks" do
    @describetag verifies: "check-run"

    test "each result is recorded by exit status, at the declaration's version against its inputs",
         %{tmp_dir: root} do
      scans = root |> project() |> scans()
      rescue_check = check(scans, "no-rescue")

      assert {:ok, [%{id: "layout"}, %{id: "no-rescue"}]} = Check.select(scans, [])
      assert {:error, "no check has the id nope"} = Check.select(scans, ["nope"])
      assert {:error, "no checks" <> _} = Check.select([], [])

      {:ok, both} = Check.select(scans, [])

      [layout, rescued] =
        Check.run(both, root, fn cmd, _ -> if cmd == "check-rescue", do: 0, else: 3 end)

      assert %{test: "layout", result: :failed, seq: 0} = layout
      assert %{test: "no-rescue", result: :passed, seq: 1, run: run} = rescued
      assert layout.run == run
      assert rescued.test_hash == rescue_check.check.declaration
      assert rescued.code == rescue_check.check.inputs
    end
  end

  describe "a check's evidence confirms its verifies" do
    @describetag verifies: "check-discriminates"

    test "failing then passing with its inputs changed confirms, and a later green re-confirms",
         %{tmp_dir: root} do
      project(root)
      red_scans = scans(root)
      entries = relate!(red_scans, [], "no-rescue", "spec.md#plat-3", :verifies)
      red = run(red_scans, ["no-rescue"], :failed, "2026-10-14T10:00:01Z")

      File.write!(Path.join(root, "rules.txt"), "deny rescue, fixed\n")
      green_scans = scans(root)
      green = run(green_scans, ["no-rescue"], :passed, "2026-10-14T10:00:02Z")

      {:ok, recorded} = Record.confirm_by_evidence(green_scans, entries, red ++ green, @meta)

      declaration = check(green_scans, "no-rescue").check.declaration

      assert [observed, confirmed] = recorded

      assert %{op: :observe, type: :red_green, ends: [%{kind: :check, hash: ^declaration}]} =
               observed

      assert %{type: :verifies, basis: :evidence} = confirmed
      assert confirmed.note =~ "check no-rescue@#{declaration} failed"

      entries = entries ++ recorded
      status = Status.derive(green_scans, entries)

      assert [%{state: :current} = r] =
               Enum.filter(status.relations, &(&1.type == :verifies))

      assert Status.validated?(status, r)

      # An input changes: the relation dangles, and a green run re-confirms it from the
      # log's observation, with the earlier evidence gone.
      File.write!(Path.join(root, "rules.txt"), "deny rescue, reworded\n")
      later_scans = scans(root)
      assert [%{state: :dangling}] = verifies(Status.derive(later_scans, entries))
      later = run(later_scans, ["no-rescue"], :passed, "2026-10-14T10:00:03Z")

      {:ok, [again]} = Record.confirm_by_evidence(later_scans, entries, later, @meta)
      assert again.note =~ "discriminated (recorded in the log)"
      assert [%{state: :current}] = verifies(Status.derive(later_scans, entries ++ [again]))
    end

    test "a check that never failed, or failed and passed against the same inputs, confirms nothing",
         %{tmp_dir: root} do
      scans = root |> project() |> scans()
      entries = relate!(scans, [], "no-rescue", "spec.md#plat-3", :verifies)

      never_red = run(scans, ["no-rescue"], :passed, "2026-10-14T10:00:01Z")
      assert {:ok, []} = Record.confirm_by_evidence(scans, entries, never_red, @meta)

      same_inputs =
        run(scans, ["no-rescue"], :failed, "2026-10-14T10:00:01Z") ++
          run(scans, ["no-rescue"], :passed, "2026-10-14T10:00:02Z")

      assert {:ok, []} = Record.confirm_by_evidence(scans, entries, same_inputs, @meta)
    end
  end

  defp verifies(status), do: Enum.filter(status.relations, &(&1.type == :verifies))

  # A verifies relation confirmed by a check's evidence, at the scans' versions.
  defp confirmed(root) do
    project(root)
    red_scans = scans(root)
    entries = relate!(red_scans, [], "no-rescue", "spec.md#plat-3", :verifies)
    red = run(red_scans, ["no-rescue"], :failed, "2026-10-14T10:00:01Z")
    File.write!(Path.join(root, "rules.txt"), "deny rescue, fixed\n")
    scans = scans(root)
    green = run(scans, ["no-rescue"], :passed, "2026-10-14T10:00:02Z")
    {:ok, recorded} = Record.confirm_by_evidence(scans, entries, red ++ green, @meta)
    {scans, entries ++ recorded, green}
  end

  describe "the check covers checks" do
    @describetag verifies: "check-evidence-checked"

    test "a run where the check passed bears its claim out; one without it didn't run",
         %{tmp_dir: root} do
      {scans, entries, green} = confirmed(root)

      status = Status.derive(scans, entries, [], evidence: green)
      assert status.unproven == [] and status.failed == []

      status = Status.derive(scans, entries, [], evidence: [])
      assert [%{test: "no-rescue", reason: :not_run}] = status.unproven
    end

    test "a failed check fails its relation; a pass against other inputs ran against other code",
         %{tmp_dir: root} do
      {scans, entries, [green]} = confirmed(root)

      failed = %{green | result: :failed}
      status = Status.derive(scans, entries, [], evidence: [failed])

      assert [%{test: "no-rescue", relation: {:verifies, {:check, "no-rescue"}, _}}] =
               status.failed

      assert status.unproven == []

      other = %{green | code: %{"rules.txt" => "00000000"}}
      status = Status.derive(scans, entries, [], evidence: [other])
      assert [%{reason: :other_code}] = status.unproven
    end

    test "merged evidence from a checks job bears it out", %{tmp_dir: root} do
      {scans, entries, green} = confirmed(root)
      tests_job = []

      status = Status.derive(scans, entries, [], evidence: {:merged, [tests_job, green]})
      assert status.unproven == []

      status = Status.derive(scans, entries, [], evidence: {:merged, [tests_job]})
      assert [%{reason: :no_job}] = status.unproven
    end
  end

  describe "reviewing a check" do
    @describetag verifies: "check-review"

    test "records its verifies on a green run at its current version, with the note",
         %{tmp_dir: root} do
      scans = root |> project() |> scans()
      entries = relate!(scans, [], "no-rescue", "spec.md#plat-3", :verifies)
      green = run(scans, ["no-rescue"], :passed, "2026-10-14T10:00:01Z")
      note = [note: "fails on any rescue in lib, which plat-3 forbids"]

      assert {:error, "a note is required" <> _} =
               Record.validate(scans, entries, "no-rescue", "spec.md#plat-3", green, @meta)

      assert {:error, "no green run of check no-rescue" <> _} =
               Record.validate(scans, entries, "no-rescue", "spec.md#plat-3", [], @meta ++ note)

      assert {:error, "no verifies relation from check no-rescue" <> _} =
               Record.validate(
                 scans,
                 [],
                 "check:no-rescue",
                 "spec.md#plat-3",
                 green,
                 @meta ++ note
               )

      {:ok, [reviewed]} =
        Record.validate(scans, entries, "check:no-rescue", "spec.md#plat-3", green, @meta ++ note)

      assert %{type: :verifies, basis: :review, note: "fails on any rescue" <> _} = reviewed

      assert {:error, "already validated" <> _} =
               Record.validate(
                 scans,
                 entries ++ [reviewed],
                 "no-rescue",
                 "spec.md#plat-3",
                 green,
                 @meta ++ note
               )
    end
  end

  describe "a check in the status" do
    @describetag verifies: "check-status"

    test "its declared verifies is suggested, unrecorded until recorded, undeclared once dropped",
         %{tmp_dir: root} do
      scans = root |> project() |> scans()

      assert %{test: "check no-rescue", spec: "spec.md#plat-3", retired: nil} in Status.derive(
               scans,
               []
             ).unrecorded

      suggested =
        Surfex.Suggest.all(Config.profile!([sources: ["spec.md"]], "App"), [], scans, [], root)

      assert {:check, "no-rescue", "spec.md#plat-3"} in for(
               v <- suggested.verifies,
               do: {v.from.kind, v.from.id, v.to.id}
             )

      {:ok, accepted} = Surfex.Suggest.accept_all(suggested, scans, [], @meta)
      status = Status.derive(scans, accepted)
      assert status.unrecorded == []

      dropped = scans(root, config(checks(verifies: ["layout"])))
      status = Status.derive(dropped, accepted)
      assert %{test: "check no-rescue", spec: "spec.md#plat-3"} in status.undeclared

      retire = %{
        Surfex.Suggest.all(
          Config.profile!([sources: ["spec.md"]], "App"),
          [],
          dropped,
          accepted,
          root
        )
        | verifies: [],
          refines: [],
          implements: [],
          excuses: [],
          tests: [],
          refresh: [],
          moves: []
      }

      {:ok, retired} = Surfex.Suggest.accept_all(retire, dropped, accepted, @meta)

      assert Enum.any?(
               retired,
               &match?(%{op: :retire, type: :verifies, ends: [%{kind: :check}, _]}, &1)
             )
    end

    test "a unit only a check verifies: no triangle gap for the code it inspects, and verified in completeness",
         %{tmp_dir: root} do
      config = config(checks(inputs: ["rules.txt", "lib/app.ex"]))
      scans = root |> project() |> scans(config)
      entries = relate!(scans, [], "no-rescue", "spec.md#plat-3", :verifies)
      entries = relate!(scans, entries, "App.f/0", "spec.md#rules-sec", :implements)

      assert Status.derive(scans, entries).triangle
             |> Enum.filter(&(&1.spec == "spec.md#rules-sec")) == []

      # Inspecting only the rules file, the code is untested.
      blind = scans(root)
      blind_entries = relate!(blind, [], "no-rescue", "spec.md#plat-3", :verifies)
      blind_entries = relate!(blind, blind_entries, "App.f/0", "spec.md#rules-sec", :implements)

      assert Enum.any?(
               Status.derive(blind, blind_entries).triangle,
               &match?(%{gap: :code_untested, code: "App.f/0"}, &1)
             )

      green = run(scans, ["no-rescue"], :passed, "2026-10-14T10:00:01Z")

      {:ok, reviewed} =
        Record.validate(
          scans,
          entries,
          "no-rescue",
          "spec.md#plat-3",
          green,
          @meta ++ [note: "catches any rescue"]
        )

      report = Completeness.report(Status.derive(scans, entries ++ reviewed))
      hint = Enum.find(report.incomplete, &(&1.id == "spec.md#plat-3"))
      assert hint == nil or :no_test not in hint.missing
    end

    test "status, its JSON and the golden list the checks", %{tmp_dir: root} do
      status = Status.derive(root |> project() |> scans(), [])

      assert Report.text(status) =~ "check no-rescue: verifies plat-3; inspects 1 file"

      json = Report.json(status) |> Surfex.Log.Entry.json()

      assert [%{"id" => "layout"}, %{"id" => "no-rescue", "run" => "check-rescue"}] =
               json["checks"]

      golden = Report.golden(status)

      assert %{heading: "checks", rows: [_, _]} =
               Enum.find(golden.groups, &(&1.heading == "checks"))

      plain = Status.derive(Enum.reject(scans(root), &(&1.kind == :check)), [])
      refute Report.text(plain) =~ "Checks ("
      refute Enum.any?(Report.golden(plain).groups, &(&1.heading == "checks"))
    end
  end
end
