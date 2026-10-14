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

    @tag verifies: "migrate-candidates"
    test "lists a section's proposals, none first, and writes nothing", %{tmp_dir: root} do
      log = File.read!(Path.join(root, ".surfex/surfex.log"))

      assert [none, single, summary] = run(root, ["spec.md#carts"])
      assert none =~ "none      MyApp.Cart.total/0: no claim inside spec.md#carts"

      assert single ==
               "single    MyApp.Cart.add/2, MyApp.Cart.add/3 (one definition) → " <>
                 "spec.md#surface/MyApp.Cart.add (its key MyApp.Cart.add names it)"

      assert summary == "2 proposals: 1 single, 0 several, 1 none"
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
  end
end
