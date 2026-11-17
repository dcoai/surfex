defmodule Surfex.TransitionsTest do
  # #405, #407: a flaky test was "proven fixed" by running the suite 100 times, and a
  # failure's history was lost with the evidence on a clean build. Each flip of a test's
  # result is now a committed line.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "failure-transitions"

  alias Surfex.{Evidence, Transitions}

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

    # Tests a, b and c at lines 4, 8 and 12, each calling the cart.
    File.write!(Path.join(root, "test/cart_test.exs"), [
      "defmodule MyApp.CartTest do\n  use ExUnit.Case\n\n",
      for name <- ~w(a b c) do
        "  test \"#{name}\" do\n    assert MyApp.Cart.total() == 0\n  end\n\n"
      end,
      "end\n"
    ])

    %{cart_test: Path.join(root, "test/cart_test.exs")}
  end

  @lines %{"a" => 4, "b" => 8, "c" => 12}

  defp failed(line),
    do:
      {:failed,
       [
         {:error, %ExUnit.AssertionError{message: "Assertion with == failed", expr: :x},
          [{MyApp.CartTest, :"test a", 1, [file: ~c"test/cart_test.exs", line: line]}]}
       ]}

  # One run: each named test's state (nil passes); the transitions it wrote.
  defp run(root, file, states) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
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

    before = length(Transitions.load(root))
    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)
    Enum.drop(Transitions.load(root), before)
  end

  defp all_pass, do: [{"a", nil}, {"b", nil}, {"c", nil}]

  test "a stable suite writes nothing; a flip writes one line with both ends", %{
    tmp_dir: root,
    cart_test: file
  } do
    assert run(root, file, all_pass()) == []
    assert run(root, file, all_pass()) == []
    refute File.exists?(Transitions.path(root))

    assert [line] = run(root, file, [{"a", failed(5)}, {"b", nil}, {"c", nil}])

    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)

    assert %{
             test: "MyApp.CartTest: a",
             from: :passed,
             to: :failed,
             commit: commit,
             changed: %{test: false, code: []},
             failure: %{kind: "assertion", location: "test/cart_test.exs:5"}
           } = line

    assert commit == String.trim(head)

    [evidence] =
      Evidence.load(Evidence.path(root))
      |> Enum.filter(&(&1.run == line.run and &1.test == line.test))

    assert line.version == evidence.test_hash
    assert line.at == evidence.at
  end

  test "a test that stays red writes nothing more, and its fail→pass counts the failed runs", %{
    tmp_dir: root,
    cart_test: file
  } do
    run(root, file, all_pass())

    for _ <- 1..5 do
      run(root, file, [{"a", failed(5)}])
    end

    assert [%{to: :failed}] = Transitions.load(root)

    assert [%{from: :failed, to: :passed, failed_runs: 5, changed: %{code: []}}] =
             run(root, file, all_pass())

    assert Transitions.last(Transitions.load(root))["MyApp.CartTest: a"].to == :passed
  end

  test "what changed since the opposite result is named: the code, or the test", %{
    tmp_dir: root,
    cart_test: file
  } do
    run(root, file, all_pass())

    cart = Path.join(root, "lib/my_app/cart.ex")

    File.write!(
      cart,
      String.replace(File.read!(cart), "def total", "def total, do: 1\n  def old_total",
        global: false
      )
    )

    assert [%{to: :failed, changed: %{test: false, code: code}}] =
             run(root, file, [{"a", failed(5)}])

    assert "MyApp.Cart.total/0" in code

    File.write!(
      file,
      String.replace(File.read!(file), "test \"a\" do\n", "test \"a\" do\n    :edited\n")
    )

    assert [%{to: :passed, changed: %{test: true}}] = run(root, file, [{"a", nil}])
  end

  test "only tests that ran flip: a partial run, and excluded or skipped tests, write nothing",
       %{tmp_dir: root, cart_test: file} do
    run(root, file, [{"a", failed(5)}, {"b", failed(9)}])
    assert length(Transitions.load(root)) == 2

    assert run(root, file, [{"a", {:excluded, "no"}}, {"b", {:skipped, "no"}}, {"c", nil}]) == []
    assert run(root, file, [{"c", nil}]) == []
    assert [%{test: "MyApp.CartTest: b", to: :passed}] = run(root, file, [{"b", nil}])
  end

  test "after a clean build the opposite result and the count are unknown, and no .surfex means no file",
       %{tmp_dir: root, cart_test: file} do
    run(root, file, all_pass())
    File.rm!(Evidence.path(root))
    assert [%{to: :failed, changed: nil}] = run(root, file, [{"a", failed(5)}])

    File.rm!(Evidence.path(root))
    assert [%{to: :passed, failed_runs: nil, changed: nil}] = run(root, file, [{"a", nil}])

    File.rm_rf!(Path.join(root, ".surfex"))
    assert run(root, file, [{"a", failed(5)}]) == []
    refute File.exists?(Transitions.path(root))
  end

  test "merged branches' lines read in time order, a repeated end is tolerated, and damage raises",
       %{tmp_dir: root, cart_test: file} do
    line = fn at, from, to ->
      ~s({"at":"#{at}","changed":null,"code":"c","commit":null,"from":"#{from}","run":"r#{at}","test":"MyApp.CartTest: a","to":"#{to}","version":"v"})
    end

    # Two branches each recorded a pass→fail, and one then a fail→pass; union merge kept
    # them all, out of time order, the last line in the file a pass→fail.
    File.write!(Transitions.path(root), [
      line.("2026-11-17T10:00:03Z", "failed", "passed"),
      "\n",
      line.("2026-11-17T10:00:01Z", "passed", "failed"),
      "\n",
      line.("2026-11-17T10:00:02Z", "passed", "failed"),
      "\n"
    ])

    assert Enum.map(Transitions.load(root), & &1.at) == [
             "2026-11-17T10:00:01Z",
             "2026-11-17T10:00:02Z",
             "2026-11-17T10:00:03Z"
           ]

    # The state is the latest in time, passed: a failing run flips it, and a passing one
    # doesn't, as it would if the file's last line were taken.
    assert run(root, file, [{"b", nil}, {"a", nil}]) == []
    assert [%{from: :passed, to: :failed}] = run(root, file, [{"a", failed(5)}])

    File.write!(Transitions.path(root), ~s({"test":"T: a"}\n), [:append])
    assert_raise ArgumentError, ~r/not a transition/, fn -> Transitions.load(root) end
  end
end
