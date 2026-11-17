defmodule Surfex.EvidenceFailureTest do
  # #405, #406: a failed test's record kept only that it failed, so a failure's history
  # couldn't tell one failure from another, or say which seed reproduces it.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "evidence-failure-detail"

  alias Surfex.Evidence

  @project Path.expand("../fixtures/elixir_project", __DIR__)

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n\nA cart.\n")

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    File.mkdir_p!(Path.join(root, "test"))

    # One test per failure kind, each its own scanned record, at lines 4, 8, 12, … 32.
    tests =
      for {name, n} <- Enum.with_index(~w(a b c d e f g h)) do
        "  test \"#{name}\" do\n    assert MyApp.Cart.total() == #{n}\n  end\n\n"
      end

    File.write!(Path.join(root, "test/cart_test.exs"), [
      "defmodule MyApp.CartTest do\n  use ExUnit.Case\n\n",
      tests,
      "  for n <- [1, 2] do\n    test \"case \#{n}\" do\n      assert unquote(n) > 0\n    end\n  end\nend\n"
    ])

    %{cart_test: Path.join(root, "test/cart_test.exs")}
  end

  # A stack frame in the test file at `line`, as ExUnit reports it (relative to the root).
  defp frame(line), do: {MyApp.CartTest, :"test a", 1, [file: ~c"test/cart_test.exs", line: line]}
  defp elsewhere, do: {MyApp.Cart, :total, 0, [file: ~c"lib/my_app/cart.ex", line: 3]}

  defp run(root, file, finished) do
    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
    GenServer.cast(pid, {:suite_started, []})

    for {line, state, time} <- finished do
      GenServer.cast(
        pid,
        {:test_finished,
         %ExUnit.Test{
           name: :t,
           module: MyApp.CartTest,
           state: state,
           time: time,
           tags: %{file: file, line: line}
         }}
      )
    end

    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)

    Map.new(
      Evidence.load(Evidence.path(root)),
      &{&1.test |> String.split(": ") |> List.last(), &1}
    )
  end

  defp assertion(message), do: %ExUnit.AssertionError{message: message, expr: :x}

  test "a failed record says how and where its first failure happened, with the run's seed",
       %{tmp_dir: root, cart_test: file} do
    pid = inspect(self())

    records =
      run(root, file, [
        {4, {:failed, [{:error, assertion("Assertion with == failed\ncode: x"), [frame(5)]}]},
         10},
        # The same assertion failing with other values, and a pid, in its message.
        {8, {:failed, [{:error, assertion("Assertion with == failed #{pid}"), [frame(5)]}]}, 11},
        {12, {:failed, [{:error, assertion("Assertion with == failed"), [frame(13)]}]}, 12},
        {16, {:failed, [{:error, %RuntimeError{message: "boom"}, [elsewhere(), frame(17)]}]}, 13},
        {20, {:failed, [{:error, %ArgumentError{message: "boom"}, [elsewhere(), frame(17)]}]},
         14},
        # A timeout's stack is wherever the test waited; it is placed at the test.
        {24, {:failed, [{:error, %ExUnit.TimeoutError{timeout: 60, type: "test"}, [frame(25)]}]},
         15},
        {28, {:failed, [{{:EXIT, self()}, :killed, []}]}, 16},
        {32, {:failed, [{:throw, {:value, pid}, [frame(33)]}]}, 17}
      ])

    seed = ExUnit.configuration()[:seed]
    assert is_integer(seed)

    assert %{
             result: :failed,
             duration: 10,
             failure: %{
               kind: "assertion",
               line: "Assertion with == failed",
               location: "test/cart_test.exs:5",
               seed: ^seed
             }
           } = records["a"]

    assert records["b"].failure.digest == records["a"].failure.digest
    assert records["b"].failure.line =~ pid
    assert records["c"].failure.location == "test/cart_test.exs:13"
    refute records["c"].failure.digest == records["a"].failure.digest

    assert %{kind: "error", line: "boom", location: "test/cart_test.exs:17"} =
             records["d"].failure

    assert %{kind: "error", location: "test/cart_test.exs:17"} = records["e"].failure
    refute records["e"].failure.digest == records["d"].failure.digest

    assert %{kind: "timeout", location: "test/cart_test.exs:24"} = records["f"].failure

    assert %{kind: "exit", line: ":killed", location: "test/cart_test.exs:28"} =
             records["g"].failure

    assert %{kind: "throw", location: "test/cart_test.exs:33"} = records["h"].failure

    assert records |> Map.values() |> Enum.map(& &1.failure.digest) |> Enum.uniq() |> length() ==
             7
  end

  test "a passed record carries its cases' duration and no failure; a family takes its first failing case",
       %{tmp_dir: root, cart_test: file} do
    records =
      run(root, file, [
        {4, nil, 40},
        {38, nil, 5},
        {38, {:failed, [{:error, assertion("first"), [frame(39)]}]}, 6},
        {38, {:failed, [{:error, assertion("second"), [frame(40)]}]}, 7},
        {8, {:skipped, "no"}, 0}
      ])

    assert records["a"].duration == 40
    refute Map.has_key?(records["a"], :failure)

    family = records["case \#{n}"]
    assert %{result: :failed, duration: 18, failure: %{line: "first"}} = family
    assert %{result: :skipped, duration: 0} = records["b"]
    refute Map.has_key?(records["b"], :failure)
  end

  test "lines without the detail load as before, and a malformed detail is refused", %{
    tmp_dir: root
  } do
    path = Evidence.path(root)
    File.mkdir_p!(Path.dirname(path))

    old =
      ~s({"at":"2026-11-17T10:00:00Z","code":{},"result":"passed","run":"r","seq":0,"test":"T: a","test_hash":"t"})

    File.write!(path, old <> "\n")
    assert [record] = Evidence.load(path)
    assert Map.keys(record) |> Enum.sort() == [:at, :code, :result, :run, :seq, :test, :test_hash]

    # What append writes, load gives back.
    detailed =
      Map.merge(record, %{
        result: :failed,
        duration: 3,
        failure: %{kind: "exit", line: ":x", location: "t.exs:1", seed: nil, digest: "d"}
      })

    Evidence.append(path, [detailed])
    assert Evidence.load(path) == [record, detailed]

    File.write!(
      path,
      String.replace(old, ~s("code":{}), ~s("code":{},"failure":{"kind":"exit"})) <> "\n"
    )

    assert_raise ArgumentError, ~r/evidence failure has no line, location, seed, digest/, fn ->
      Evidence.load(path)
    end
  end
end
