defmodule Surfex.StatusTaskTest do
  # The task reads the working directory, which is global.
  use ExUnit.Case, async: false

  alias Surfex.{Log, Scan}
  alias Surfex.Log.Entry
  alias Surfex.Status.Config

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Totals\n\nA cart's total.\n")
    File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec.md"], namespace: "MyApp"]))
    Log.init(root)

    scans = Config.scans([sources: ["spec.md"]], root) |> Map.new(&{&1.id, &1})
    Log.append(root, [relate(scans["spec.md#Totals"], scans["MyApp.Cart.total/0"])])
    %{root: root}
  end

  defp relate(%Scan{} = spec, %Scan{} = code) do
    Entry.new!(
      at: "2026-09-28T10:00:00Z",
      op: :relate,
      type: :implements,
      ends: [
        %{kind: :spec, id: spec.id, hash: spec.hash},
        %{kind: :code, id: code.id, hash: code.hash}
      ]
    )
  end

  defp task(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Status.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("no output")
    end
  end

  @tag verifies: ["status-report-forms"]
  test "a current relation passes, and the report says so", %{root: root} do
    task(root, [])
    assert output() =~ "relation status: ok\n  implements: current 1"
  end

  @tag verifies: ["status-report-forms"]
  test "an edit to the code dangles it and fails, naming the end", %{root: root} do
    path = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      path,
      String.replace(File.read!(path), "def total, do: helper(0)", "def total, do: helper(1)")
    )

    assert_raise Mix.Error, ~r/relations need attention/, fn -> task(root, []) end
    assert output() =~ "changed: MyApp.Cart.total/0 (lib/my_app/cart.ex:22-22)"
  end

  @tag verifies: ["status-report-forms"]
  test "--format json is the work list", %{root: root} do
    task(root, ["--format", "json"])
    json = :json.decode(output())

    assert %{"failing" => false, "relations" => [%{"state" => "current", "type" => "implements"}]} =
             json

    assert Enum.any?(json["new"], &(&1["id"] == "MyApp.Cart.add/2"))
  end

  @tag verifies: ["status-report-forms"]
  test "the require policy fails on unrelated code", %{root: root} do
    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], require: [code: [:implements]]])
    )

    assert_raise Mix.Error, fn -> task(root, []) end

    assert output() =~
             "Unmet (required relation missing):\n  code MyApp.Cart needs one of: implements"
  end

  @tag verifies: ["status-report-forms"]
  test "--verify fails on an edited log line", %{root: root} do
    path = Path.join(Log.dir(root), "surfex.log")

    File.write!(
      path,
      String.replace(File.read!(path), "2026-09-28T10:00:00Z", "2026-09-28T10:00:09Z")
    )

    assert_raise Mix.Error, ~r/does not verify/, fn -> task(root, ["--verify"]) end
  end

  # #76: the relation here was recorded with no basis, as before validation existed.
  @tag verifies: ["status-report-forms"]
  test "--validated fails on a relation nothing has validated, and lists it", %{root: root} do
    task(root, [])
    assert output() =~ "relation status: ok\n  implements: current 1\n  unvalidated: 1\n"

    assert_raise Mix.Error, ~r/relations need attention/, fn -> task(root, ["--validated"]) end

    assert output() =~
             "Unvalidated (current, but nothing has validated it):\n  implements  code MyApp.Cart.total/0 ↔ spec spec.md#Totals"
  end

  # #74: a score to move, and a floor a project may set.
  @tag verifies: ["completeness-score", "status-report-forms"]
  test "below completeness: [min: N] the check fails; mix surfex.completeness reports",
       %{root: root} do
    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], namespace: "MyApp", completeness: [min: 100]])
    )

    error = assert_raise Mix.Error, fn -> task(root, []) end
    assert error.message =~ "completeness 0.0% is below the minimum, 100"
    assert output() =~ "relation status: ok"

    assert_raise Mix.Error, ~r/below the minimum/, fn -> completeness(root, []) end
    assert output() =~ "completeness: 0.0%"

    # Without a minimum it only reports, here as JSON for an agent.
    File.write!(Path.join(root, "open.exs"), ~s([sources: ["spec.md"], namespace: "MyApp"]))
    completeness(root, ["--format", "json", "--config", "open.exs"])
    assert %{"scores" => %{"overall" => %{"percent" => _}}} = :json.decode(output())
  end

  defp completeness(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Completeness.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  # #52: the spec can't name what the code doesn't have.
  @tag verifies: ["status-report-forms"]
  test "a citation of nothing is a broken citation, and fails", %{root: root} do
    File.write!(
      Path.join(root, "spec.md"),
      "# Totals\n\nA cart's total.\n\n# Discounts\n\n`MyApp.Cart.discount/1` takes a share off.\n"
    )

    error = assert_raise Mix.Error, fn -> task(root, []) end
    assert error.message =~ "relations need attention"

    assert output() =~
             "Broken citations (the spec names what the code doesn't have):\n  spec.md:7 (Discounts): `MyApp.Cart.discount/1` names nothing the code has"
  end

  describe "broken_citations/4" do
    @describetag verifies: "status-config-read"

    alias Surfex.Item

    @items [
      %Item{kind: :function, name: "wren_send", file: "w.c", hash: "00000001"},
      %Item{kind: :function, name: "wren_twin", file: "w.c", hash: "00000002"},
      %Item{kind: :const, name: "wren_twin", file: "w.h", hash: "00000003"}
    ]

    test "unresolved and ambiguous break; resolved, external and documented absences don't",
         %{root: root} do
      File.write!(Path.join(root, "spec.md"), """
      # Wren

      `wren_send` sends. `wren_gone` was removed. `wren_twin` is two things.
      `wrend` relays. `wren_retry` doesn't exist, on purpose.
      """)

      config = [
        sources: ["spec.md"],
        scanner: WrenScanner,
        shape: ~r/^wren_?\w*$/,
        known_external: %{"wrend" => "the relay daemon"},
        documented_absences: %{{"wren_retry", "spec.md"} => "absent by design"}
      ]

      broken = Config.broken_citations(config, @items, root, nil)

      assert Enum.map(broken, &{&1.span, &1.status}) == [
               {"wren_gone", :unresolved},
               {"wren_twin", :ambiguous}
             ]
    end
  end

  # #98: --merge reads each job's evidence file in a final job.
  @tag verifies: "evidence-merged"
  test "--merge reads the named evidence files, and a missing one fails", %{root: root} do
    files =
      for name <- ~w(main slow) do
        path = Path.join(root, "#{name}.jsonl")
        Surfex.Evidence.append(path, [])
        File.write!(path, "")
        path
      end

    task(root, Enum.flat_map(files, &["--merge", &1]))
    assert output() =~ "relation status: ok"

    error =
      assert_raise Mix.Error, fn -> task(root, ["--merge", Path.join(root, "gone.jsonl")]) end

    assert error.message =~ "no evidence file at"
  end
end
