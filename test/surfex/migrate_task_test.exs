defmodule Surfex.MigrateTaskTest do
  # #251: mix surfex.migrate lists a section's proposals and reports what migrating buys
  # (§14.1). The task reads the working directory and the Mix shell, which are global.
  use ExUnit.Case, async: false

  describe "mix surfex.migrate" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)

      File.write!(Path.join(root, "spec.md"), """
      # Carts
      <!-- surfex: carts -->

      A cart adds items and totals them.

      <!-- surfex: table surface -->

      | Function | Claim |
      |---|---|
      | `MyApp.Cart.add` | adds an item |
      """)

      File.write!(Path.join(root, ".surfex.exs"), ~s([sources: ["spec.md"]]))

      File.cd!(root, fn ->
        Mix.shell(Mix.Shell.Process)
        Mix.Tasks.Surfex.Log.run(["--init"])

        for c <- ~w(MyApp.Cart.add/2 MyApp.Cart.add/3 MyApp.Cart.total/0),
            do: Mix.Tasks.Surfex.Relate.run(["spec.md#carts", c, "--type", "implements"])
      end)

      drain()
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    defp run(root, args) do
      File.cd!(root, fn -> Mix.Tasks.Surfex.Migrate.run(args) end)
      drain()
    end

    defp drain(acc \\ []) do
      receive do
        {:mix_shell, :info, [text]} -> drain([text | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    @tag verifies: ["migrate-candidates", "migration"]
    test "lists a section's proposals, none first, and writes nothing", %{tmp_dir: root} do
      log = File.read!(Path.join(root, ".surfex/surfex.log"))

      assert [none, single, summary] = run(root, ["spec.md#carts"])
      assert none =~ "none      MyApp.Cart.total/0: no claim inside spec.md#carts"

      assert single ==
               "single    MyApp.Cart.add/2, MyApp.Cart.add/3 (one definition) → " <>
                 "spec.md#surface/MyApp.Cart.add (its key MyApp.Cart.add names it)"

      assert summary ==
               "2 proposals: 1 single, 0 several, 1 none; --accept records the single ones"

      assert run(root, ["spec.md#", "--within"]) == [none, single, summary]
      assert File.read!(Path.join(root, ".surfex/surfex.log")) == log

      assert_raise Mix.Error, ~r/spec.md#nothing is no section/, fn ->
        run(root, ["spec.md#nothing"])
      end
    end

    @tag verifies: "migrate-report"
    test "--report prints the population, then each section worst first", %{tmp_dir: root} do
      assert [
               "section-grain implements: 3 in 1 sections",
               "  claims already units: 1 sections, 3 implements (they migrate today)",
               "  prose: 0 sections, 0 implements" <> _,
               "",
               "spec.md#carts (claims are units): 3 relations now → 1 after; implements 3: " <>
                 "2 single · 0 several · 1 none",
               "  MyApp.Cart.add/2, MyApp.Cart.add/3: 3 now → 2 after (single)",
               "  MyApp.Cart.total/0: 3 now → 1 after (none)"
             ] = run(root, ["--report"])
    end

    @tag verifies: "migrate-accept"
    test "suggest proposes retiring a settled section relation, its claim holding it now", %{
      tmp_dir: root
    } do
      run(root, ["spec.md#carts", "--accept"])

      # Each claim relation reviewed: the migration settled.
      File.cd!(root, fn ->
        entries = Surfex.Log.load(root)

        reviews =
          for %{migrates: "spec.md#carts", ends: ends} = e <- entries do
            relation = Surfex.Log.Entry.relation(:implements, hd(ends), List.last(ends))

            Surfex.Log.Entry.new!(
              at: "2026-10-15T12:00:00Z",
              op: :relate,
              type: :implements,
              basis: :review,
              parents: Enum.map(Surfex.Status.tips(entries, relation), & &1.id),
              ends: e.ends,
              note: "reviewed"
            )
          end

        Surfex.Log.append(root, reviews)
        Mix.Tasks.Surfex.Suggest.run([])
      end)

      lines = drain()

      # One claim holds it: the line agrees in number.
      assert Enum.any?(
               lines,
               &(&1 =~
                   "retire      implements MyApp.Cart.add/2 ↔ spec.md#carts " <>
                     "(moved to spec.md#surface/MyApp.Cart.add, which holds it now)")
             )
    end

    @tag verifies: "migrate-accept"
    test "--accept records the single proposals as migrating; --code --to a chosen claim", %{
      tmp_dir: root
    } do
      out = run(root, ["spec.md#carts", "--accept", "--note", "the table names it"])

      assert [
               "recorded relate implements  code MyApp.Cart.add/2@" <> add2,
               "recorded relate implements  code MyApp.Cart.add/3@" <> _
             ] = out

      assert add2 =~ "spec spec.md#surface/MyApp.Cart.add@"

      assert add2 =~
               "migrating from spec.md#carts to its claim spec.md#surface/MyApp.Cart.add: " <>
                 "the table names it"

      assert [none, migrating, _summary] = run(root, ["spec.md#carts"])
      assert none =~ "none      MyApp.Cart.total/0"

      assert migrating =~
               "migrating MyApp.Cart.add/2, MyApp.Cart.add/3 (one definition) → " <>
                 "spec.md#surface/MyApp.Cart.add: validate the claim's relation"

      assert [chosen] =
               run(root, [
                 "spec.md#carts",
                 "--code",
                 "MyApp.Cart.total/0",
                 "--to",
                 "spec.md#surface/MyApp.Cart.add"
               ])

      assert chosen =~ "code MyApp.Cart.total/0@"

      assert_raise Mix.Error, ~r/--to CLAIM/, fn ->
        run(root, ["spec.md#carts", "--code", "MyApp.Cart.total/0"])
      end
    end
  end

  describe "mix surfex.migrate --report, the work list" do
    @describetag :tmp_dir

    # A section whose hint alone is verified, holding no implements: contained.
    setup %{tmp_dir: root} do
      File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)

      File.write!(Path.join(root, "spec.md"), """
      # Totals
      <!-- surfex: totals -->

      A cart totals its items.

      ```test:totals-empty
      an empty cart totals nothing
      ```
      """)

      File.mkdir_p!(Path.join(root, "test"))

      File.write!(Path.join(root, "test/cart_test.exs"), """
      defmodule MyApp.CartTest do
        use ExUnit.Case

        @tag verifies: "totals-empty"
        test "an empty cart totals" do
          assert MyApp.Cart.total() == 1
        end
      end
      """)

      config = [sources: ["spec.md"], tests: ["test/*_test.exs"], claim_grain: true]
      File.write!(Path.join(root, ".surfex.exs"), inspect(config))

      File.cd!(root, fn ->
        Mix.shell(Mix.Shell.Process)
        Mix.Tasks.Surfex.Log.run(["--init"])

        # The test's verifies to the hint, current: as its evidence would record it.
        scans = Surfex.Status.Config.scans(config, root)
        at = fn kind, id -> Enum.find(scans, &(&1.kind == kind and &1.id == id)).hash end
        test = "MyApp.CartTest: an empty cart totals"

        Surfex.Log.append(root, [
          Surfex.Log.Entry.new!(
            at: "2026-10-15T10:00:00Z",
            op: :relate,
            type: :verifies,
            basis: :evidence,
            ends: [
              %{kind: :test, id: test, hash: at.(:test, test)},
              %{kind: :spec, id: "spec.md#totals-empty", hash: at.(:spec, "spec.md#totals-empty")}
            ]
          )
        ])
      end)

      drain()
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    defp report(root, args) do
      File.cd!(root, fn -> Mix.Tasks.Surfex.Migrate.run(["--report" | args]) end)
      drain()
    end

    @tag verifies: ["migrate-report-contained", "migration-work-list"]
    test "--report lists a contained section, holding no implements, naming its verified claim",
         %{tmp_dir: root} do
      assert [
               "section-grain implements: 0 in 1 sections",
               _units,
               _prose,
               "  contained: 1 sections (a claim inside is verified, their own text isn't, " <>
                 "spec §14.2)",
               "",
               "spec.md#totals (claims are units): " <> _,
               "  contained: spec.md#totals-empty verified inside, its own text isn't"
             ] = report(root, [])

      assert [json] = report(root, ["--format", "json"])

      assert %{
               "population" => %{"contained" => %{"sections" => 1}},
               "sections" => [
                 %{"section" => "spec.md#totals", "contained" => ["spec.md#totals-empty"]}
               ]
             } = :json.decode(json)

      assert_raise Mix.Error, ~r/--format json is the report's/, fn ->
        File.cd!(root, fn ->
          Mix.Tasks.Surfex.Migrate.run(["spec.md#totals", "--format", "json"])
        end)
      end

      assert_raise Mix.Error, ~r/--format must be text or json/, fn ->
        report(root, ["--format", "csv"])
      end
    end
  end
end
