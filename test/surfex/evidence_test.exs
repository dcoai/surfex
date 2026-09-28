defmodule Surfex.EvidenceTest do
  use ExUnit.Case, async: true

  alias Surfex.Evidence

  @moduletag :tmp_dir

  defp record(result, code, seq, extra \\ []) do
    Map.merge(
      %{
        test: "T: a",
        test_hash: "t1",
        result: result,
        at: "2026-09-28T10:00:0#{seq}Z",
        run: "r#{seq}",
        seq: 0,
        code: %{"M.f/1" => code}
      },
      Map.new(extra)
    )
  end

  test "append then load, oldest first", %{tmp_dir: root} do
    path = Evidence.path(root)
    assert path == Path.join([root, "_build", "surfex", "evidence.jsonl"])
    assert Evidence.load(path) == []

    Evidence.append(path, [record(:passed, "c2", 2)])
    Evidence.append(path, [record(:failed, "c1", 1)])

    assert [%{result: :failed, code: %{"M.f/1" => "c1"}}, %{result: :passed}] =
             Evidence.load(path)
  end

  describe "discriminating?/3" do
    @describetag verifies: "evidence-discriminates"

    test "red against one version of the code, then green against another" do
      evidence = [record(:failed, "c1", 1), record(:passed, "c2", 2)]
      assert Evidence.discriminating?(evidence, "T: a", "t1")

      assert {%{result: :failed}, %{result: :passed}} =
               Evidence.red_then_green(evidence, "T: a", "t1")
    end

    test "never red, red with the code unchanged, or green before red, is not" do
      refute Evidence.discriminating?(
               [record(:passed, "c1", 1), record(:passed, "c2", 2)],
               "T: a",
               "t1"
             )

      refute Evidence.discriminating?(
               [record(:failed, "c1", 1), record(:passed, "c1", 2)],
               "T: a",
               "t1"
             )

      refute Evidence.discriminating?(
               [record(:passed, "c1", 1), record(:failed, "c2", 2)],
               "T: a",
               "t1"
             )
    end

    test "a changed test is a new version, which must fail and pass again" do
      evidence = [record(:failed, "c1", 1), record(:passed, "c2", 2, test_hash: "t2")]
      refute Evidence.discriminating?(evidence, "T: a", "t1")
      refute Evidence.discriminating?(evidence, "T: a", "t2")
    end
  end

  describe "the formatter" do
    @project Path.expand("../fixtures/elixir_project", __DIR__)

    setup %{tmp_dir: root} do
      File.cp_r!(@project, root)
      File.write!(Path.join(root, "spec.md"), "# Carts\n\nA cart.\n")

      File.write!(
        Path.join(root, ".surfex.exs"),
        ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
      )

      File.mkdir_p!(Path.join(root, "test"))

      File.write!(Path.join(root, "test/cart_test.exs"), """
      defmodule MyApp.CartTest do
        use ExUnit.Case

        test "totals" do
          assert MyApp.Cart.total() == 0
        end

        for n <- [1, 2] do
          test "case \#{n}" do
            assert unquote(n) > 0
          end
        end
      end
      """)

      {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
      %{pid: pid, cart_test: Path.join(root, "test/cart_test.exs")}
    end

    defp finished(pid, file, line, state),
      do:
        GenServer.cast(
          pid,
          {:test_finished,
           %ExUnit.Test{
             name: :t,
             module: MyApp.CartTest,
             state: state,
             tags: %{file: file, line: line}
           }}
        )

    test "records each test's result at its version, with the versions of what it calls",
         %{pid: pid, cart_test: file, tmp_dir: root} do
      GenServer.cast(pid, {:suite_started, []})
      finished(pid, file, 4, nil)
      finished(pid, file, 9, nil)
      finished(pid, file, 9, {:failed, []})
      finished(pid, file, 4, {:skipped, "no"})
      GenServer.cast(pid, {:suite_finished, %{}})
      GenServer.stop(pid)

      [generated, totals] = Evidence.load(Evidence.path(root))

      assert %{
               test: "MyApp.CartTest: totals",
               result: :passed,
               code: %{"MyApp.Cart.total/0" => _}
             } = totals

      # One case of the generated family failed: the family failed.
      assert %{test: "MyApp.CartTest: case #{"\#{n}"}", result: :failed} = generated
      assert generated.run == totals.run
    end
  end
end
