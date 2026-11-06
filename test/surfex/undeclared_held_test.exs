defmodule Surfex.UndeclaredHeldTest do
  # #369, #370: a tag can go by mistake, and a retired relation doesn't come back on its own.
  # A bulk command leaves a judgement for someone to read (§15).
  use ExUnit.Case, async: false
  @moduletag verifies: "undeclared-held"
  @moduletag :tmp_dir

  alias Surfex.{Scan, Status, Suggest}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @meta [by: "tester", at: "2026-11-06T10:00:00Z"]
  @test_id "T: the limit"

  defp world(root) do
    File.write!(Path.join(root, "spec.md"), """
    # Limits
    <!-- surfex: limits -->

    Prose.

    ```test:limit
    the limit holds
    ```
    """)

    spec = Markdown.records(root, ["spec.md"])
    {spec, Enum.find(spec, &(&1.id == "spec.md#limit"))}
  end

  defp test_scan(declares),
    do: %Scan{
      kind: :test,
      id: @test_id,
      hash: "t1",
      location: %{file: "test/a_test.exs", lines: {1, 2}},
      declares: Enum.map(declares, &{:verifies, &1})
    }

  defp verifies(hint, basis) do
    Entry.new!(
      at: "2026-11-06T09:00:00Z",
      op: :relate,
      type: :verifies,
      basis: basis,
      note: "checked",
      ends: [
        %{kind: :test, id: @test_id, hash: "t1"},
        %{kind: :spec, id: hint.id, hash: hint.hash}
      ]
    )
  end

  defp suggestions(root, scans, entries) do
    profile = Config.profile!([sources: ["spec.md"]], "Wren")
    Suggest.all(profile, [], scans, entries, root)
  end

  test "an undeclared relation resting on a review is listed as validated and not retired", %{
    tmp_dir: root
  } do
    {spec, hint} = world(root)
    entries = [verifies(hint, :review)]
    scans = [test_scan([]) | spec]
    s = suggestions(root, scans, entries)

    assert [%{test: @test_id, spec: "spec.md#limit", validated: true}] = s.undeclared

    {:ok, recorded} = Suggest.accept_all(s, scans, entries, @meta)
    refute Enum.any?(recorded, &(&1.op == :retire))

    # It stays undeclared, and the status keeps failing until someone decides.
    status = Status.derive(scans, entries ++ recorded)
    assert [%{spec: "spec.md#limit"}] = status.undeclared
    assert Status.failing?(status)
  end

  @tag verifies: ["undeclared-held", "undeclared-verifies"]
  test "--retire-undeclared retires it, and a proposed one retires without being asked", %{
    tmp_dir: root
  } do
    {spec, hint} = world(root)
    scans = [test_scan([]) | spec]

    entries = [verifies(hint, :evidence)]
    s = suggestions(root, scans, entries)

    {:ok, recorded} = Suggest.accept_all(s, scans, entries, @meta, retire_undeclared: true)

    assert [
             %{
               op: :retire,
               type: :verifies,
               note: "the test no longer declares that it verifies this"
             }
           ] =
             Enum.filter(recorded, &(&1.op == :retire))

    proposed = [verifies(hint, :proposed)]
    p = suggestions(root, scans, proposed)
    assert [%{validated: false}] = p.undeclared

    {:ok, retired} = Suggest.accept_all(p, scans, proposed, @meta)
    assert [%{op: :retire}] = Enum.filter(retired, &(&1.op == :retire))
  end

  test "a declaration whose relation was retired names the command that revives it", %{
    tmp_dir: root
  } do
    {spec, hint} = world(root)
    scans = [test_scan(["limit"]) | spec]
    related = verifies(hint, :review)

    retire =
      Entry.new!(
        at: "2026-11-06T09:30:00Z",
        op: :retire,
        type: :verifies,
        parents: [related.id],
        note: "gone",
        ends: related.ends
      )

    assert Report.text(Status.derive(scans, [related, retire])) =~
             ~s(mix surfex.relate "#{@test_id}" spec.md#limit --type verifies)
  end

  describe "the task" do
    setup %{tmp_dir: root} do
      File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)
      File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec.md"]]))
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    test "--retire-undeclared goes with --accept", %{tmp_dir: root} do
      File.write!(Path.join(root, "spec.md"), "# S\n\nText.\n")

      File.cd!(root, fn ->
        assert_raise Mix.Error, ~r/--retire-undeclared goes with --accept/, fn ->
          Mix.Tasks.Surfex.Suggest.run(["--retire-undeclared"])
        end
      end)
    end
  end
end
