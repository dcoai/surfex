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

  # #216: a gate step wants the scores, not the work list COMPLETENESS.md already holds.
  @tag verifies: ["completeness-summary"]
  test "mix surfex.completeness --summary prints the score lines only, and fails as before",
       %{root: root} do
    File.write!(Path.join(root, "open.exs"), ~s([sources: ["spec.md"], namespace: "MyApp"]))
    completeness(root, ["--config", "open.exs"])
    assert output() =~ "\nIncomplete:\n"

    completeness(root, ["--summary", "--config", "open.exs"])
    summary = output()

    assert [overall, "  spec units: " <> _, "  tests: " <> _, "  code: " <> _] =
             String.split(summary, "\n", trim: true)

    assert overall =~ ~r/^completeness: \d+\.\d% \(\d+\/\d+\)$/
    refute summary =~ "Incomplete"

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], namespace: "MyApp", completeness: [min: 100]])
    )

    error = assert_raise Mix.Error, fn -> completeness(root, ["--summary"]) end
    assert error.message == "completeness 0.0% is below the minimum, 100"
    assert output() == summary

    assert_raise Mix.Error, ~r/--summary/, fn ->
      completeness(root, ["--summary", "--format", "json"])
    end
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

  # #211: nftables_port's planted bug. Every relation validated by review, the gate run
  # with --verify --validated over a job's evidence where the verifying test failed.
  @tag verifies: ["evidence-failed", "status-report-forms"]
  test "--merge over a red run fails relations validated by review, naming the test and unit",
       %{root: root} do
    File.write!(
      Path.join(root, "spec.md"),
      "# Totals\n\nA cart's total.\n\n```test totals-test\nan empty cart totals zero\n```\n"
    )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case
      @tag verifies: "totals-test"
      test "an empty cart" do
        assert MyApp.Cart.total() == 0
      end
    end
    """)

    config = [sources: ["spec.md"], namespace: "MyApp", tests: ["test/**/*_test.exs"]]
    File.write!(Path.join(root, ".surfex.exs"), inspect(config))
    File.rm_rf!(Path.join(root, ".surfex"))
    Log.init(root)

    scans = Config.scans(config, root) |> Map.new(&{&1.id, &1})
    test = scans["MyApp.CartTest: an empty cart"]
    end_ = fn %Scan{} = s -> %{kind: s.kind, id: s.id, hash: s.hash} end

    reviewed = fn type, a, b ->
      Entry.new!(
        at: "2026-09-28T10:00:00Z",
        op: :relate,
        type: type,
        ends: [end_.(a), end_.(b)],
        basis: :review,
        note: "reviewed"
      )
    end

    Log.append(root, [
      reviewed.(:verifies, test, scans["spec.md#totals-test"]),
      reviewed.(:implements, scans["spec.md#Totals"], scans["MyApp.Cart.total/0"])
    ])

    run = fn result ->
      path = Path.join(root, "#{result}.jsonl")

      Surfex.Evidence.append(path, [
        %{
          test: test.id,
          test_hash: test.hash,
          result: result,
          at: "2026-09-28T11:00:00Z",
          run: "r",
          seq: 0,
          code: %{"MyApp.Cart.total/0" => scans["MyApp.Cart.total/0"].hash}
        }
      ])

      path
    end

    task(root, ["--verify", "--validated", "--merge", run.(:passed)])
    assert output() =~ "relation status: ok"

    assert_raise Mix.Error, ~r/relations need attention/, fn ->
      task(root, ["--verify", "--validated", "--merge", run.(:failed)])
    end

    assert output() =~
             "verifies  test MyApp.CartTest: an empty cart ↔ spec spec.md#totals-test: " <>
               "MyApp.CartTest: an empty cart failed"
  end

  # #214: a project joins the gate while it fixes its deviations; a release holds them.
  @tag verifies: ["status-report-forms"]
  test "a declared deviation passes the check, --no-deviations fails it, and a pass is stale",
       %{root: root} do
    File.write!(
      Path.join(root, "spec.md"),
      "# Totals\n\nA cart's total.\n\n```test totals-free\na cart over 50 ships free\n```\n"
    )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case
      @tag verifies: "totals-free", deviation: "#119", skip: "known deviation (#119)"
      test "free over 50" do
        assert MyApp.Cart.total() == :free
      end
    end
    """)

    config = [sources: ["spec.md"], namespace: "MyApp", tests: ["test/**/*_test.exs"]]
    File.write!(Path.join(root, ".surfex.exs"), inspect(config))
    File.rm_rf!(Path.join(root, ".surfex"))
    Log.init(root)

    scans = Config.scans(config, root) |> Map.new(&{&1.id, &1})
    deviant = scans["MyApp.CartTest: free over 50"]
    end_of = fn %Scan{} = s -> %{kind: s.kind, id: s.id, hash: s.hash} end

    on_basis = fn type, a, b, basis ->
      Entry.new!(
        at: "2026-09-28T10:00:00Z",
        op: :relate,
        type: type,
        ends: [end_of.(a), end_of.(b)],
        basis: basis
      )
    end

    # The verifies on its red run; the section's implements cited, so only proposed.
    Log.append(root, [
      on_basis.(:verifies, deviant, scans["spec.md#totals-free"], :evidence),
      on_basis.(:implements, scans["spec.md#Totals"], scans["MyApp.Cart.total/0"], :proposed)
    ])

    task(root, [])
    text = output()
    assert text =~ "relation status: ok"
    assert text =~ "spec.md#totals-free (spec.md:5-7): #119, declared by test MyApp.CartTest"

    assert_raise Mix.Error, ~r/relations need attention/, fn ->
      task(root, ["--no-deviations"])
    end

    passed = Path.join(root, "passed.jsonl")

    Surfex.Evidence.append(passed, [
      %{
        test: deviant.id,
        test_hash: deviant.hash,
        result: :passed,
        at: "2026-09-28T11:00:00Z",
        run: "r",
        seq: 0,
        code: %{"MyApp.Cart.total/0" => scans["MyApp.Cart.total/0"].hash}
      }
    ])

    # Drain the --no-deviations report before the stale run's.
    _held = output()

    assert_raise Mix.Error, ~r/relations need attention/, fn ->
      task(root, ["--merge", passed])
    end

    assert output() =~ "Stale deviations"
  end
end
