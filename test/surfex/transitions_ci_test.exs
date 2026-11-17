defmodule Surfex.TransitionsCiTest do
  # #405, #409: CI can't commit, so its flips were lost with its working copy. A job writes
  # them to an artifact instead, and a person folds them in. The task reads the working
  # directory, and one test sets an environment variable: both global.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "failure-transitions-ci"

  alias Surfex.Transitions

  @project Path.expand("../fixtures/elixir_project", __DIR__)

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n\nA cart.\n")

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, ".surfex"))

    File.write!(Path.join(root, "test/cart_test.exs"), [
      "defmodule MyApp.CartTest do\n  use ExUnit.Case\n\n",
      for name <- ~w(a b) do
        "  test \"#{name}\" do\n    assert MyApp.Cart.total() == 0\n  end\n\n"
      end,
      "end\n"
    ])

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{
      cart_test: Path.join(root, "test/cart_test.exs"),
      out: Path.join(root, "ci/transitions.log")
    }
  end

  @lines %{"a" => 4, "b" => 8}

  defp failed,
    do:
      {:failed,
       [
         {:error, %ExUnit.AssertionError{message: "Assertion with == failed", expr: :x},
          [{MyApp.CartTest, :"test a", 1, [file: ~c"test/cart_test.exs", line: 5]}]}
       ]}

  defp run(root, file, states, opts \\ []) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, [surfex_root: root] ++ opts)
    GenServer.cast(pid, {:suite_started, []})

    for {name, state} <- states do
      GenServer.cast(
        pid,
        {:test_finished,
         %ExUnit.Test{
           name: :t,
           module: MyApp.CartTest,
           state: state,
           tags: %{file: file, line: @lines[name]}
         }}
      )
    end

    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)
  end

  defp task(root, args), do: File.cd!(root, fn -> Mix.Tasks.Surfex.Failures.run(args) end)

  defp read!(path) do
    {:ok, transitions} = Transitions.load_file(path)
    transitions
  end

  defp info do
    receive do
      {:mix_shell, :info, [line]} -> [line | info()]
    after
      0 -> []
    end
  end

  test "a CI run writes its flips to the artifact, judged against the committed file, never the checkout",
       %{tmp_dir: root, cart_test: file, out: out} do
    # Committed: a failing.
    run(root, file, [{"a", failed()}, {"b", nil}])
    committed = File.read!(Transitions.path(root))

    run(root, file, [{"a", nil}, {"b", failed()}], surfex_transitions: out)
    assert File.read!(Transitions.path(root)) == committed

    assert [
             %{test: "MyApp.CartTest: a", from: :failed, to: :passed},
             %{test: "MyApp.CartTest: b", from: :passed, to: :failed}
           ] =
             read!(out) |> Enum.sort_by(& &1.test)

    # A second run in the job is judged with the artifact's lines too: b is still red.
    run(root, file, [{"a", nil}, {"b", failed()}], surfex_transitions: out)
    assert length(read!(out)) == 2

    # The environment names the artifact of the checkout in the working directory; a
    # formatter over another root, as a test starts one, leaves it alone.
    env_out = Path.join(root, "ci/env.log")
    System.put_env("SURFEX_TRANSITIONS_OUT", env_out)
    on_exit(fn -> System.delete_env("SURFEX_TRANSITIONS_OUT") end)
    File.cd!(root, fn -> run(root, file, [{"b", failed()}]) end)
    assert [%{test: "MyApp.CartTest: b", to: :failed}] = read!(env_out)
    assert File.read!(Transitions.path(root)) == committed

    File.cd!(System.tmp_dir!(), fn -> run(root, file, [{"b", failed()}]) end)
    System.delete_env("SURFEX_TRANSITIONS_OUT")
    assert length(read!(env_out)) == 1
    # That formatter wrote its own project's file, as one without the variable does.
    assert %{"MyApp.CartTest: b" => %{to: :failed}} = Transitions.last(Transitions.load(root))

    # A checkout with no log still gets its artifact.
    File.rm_rf!(Path.join(root, ".surfex"))
    bare = Path.join(root, "ci/bare.log")
    run(root, file, [{"b", failed()}], surfex_transitions: bare)
    assert [%{test: "MyApp.CartTest: b", to: :failed}] = read!(bare)
    refute File.exists?(Path.join(root, ".surfex"))
  end

  test "--merge reads an artifact into the report, and --ingest appends its new lines once", %{
    tmp_dir: root,
    cart_test: file,
    out: out
  } do
    run(root, file, [{"a", failed()}, {"b", nil}])
    run(root, file, [{"a", nil}, {"b", failed()}], surfex_transitions: out)

    task(root, ["--json"])
    [local] = info()
    assert [%{"test" => "MyApp.CartTest: a"}] = :json.decode(local)["tests"]

    task(root, ["--json", "--merge", out])
    [merged] = info()

    assert Enum.map(:json.decode(merged)["tests"], & &1["test"]) == [
             "MyApp.CartTest: a",
             "MyApp.CartTest: b"
           ]

    assert_raise Mix.Error, ~r/can't read transitions at .*missing.log/, fn ->
      task(root, ["--merge", Path.join(root, "missing.log")])
    end

    task(root, ["--ingest", out])
    assert info() == ["ingested 2 transitions into .surfex/transitions.log; 0 already there"]
    task(root, ["--ingest", out])
    assert info() == ["ingested 0 transitions into .surfex/transitions.log; 2 already there"]

    task(root, ["--json"])
    assert info() == [merged]
  end
end
