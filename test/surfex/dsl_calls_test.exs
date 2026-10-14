defmodule Surfex.DslCallsTest do
  # #208, #241: a call a test or a function makes through a DSL's entry reaches the DSL item
  # it names, as a project scanner's `calls/3` answers (spec §5.4).
  use ExUnit.Case, async: true
  @moduletag verifies: "dsl-calls"

  alias Surfex.{Evidence, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.Config
  alias Surfex.Test.FixtureDsl

  @project Path.expand("../fixtures/dsl_project", __DIR__)

  defmodule ItemsOnly do
    @moduledoc false
    # The fixture DSL's items, from a scanner that answers no calls.
    @behaviour Surfex.Scanner
    @impl true
    def items(root, opts), do: Surfex.Test.FixtureDsl.Scanner.items(root, opts)
  end

  defmodule BadAnswer do
    @moduledoc false
    @behaviour Surfex.Scanner
    @impl true
    def items(_root, _opts), do: []
    @impl true
    def calls(_call, _aliases, _opts), do: [:checkout]
  end

  @test_source """
  defmodule Shop.OrderTest do
    use ExUnit.Case
    alias Shop.Order
    alias Surfex.Test.FixtureDsl

    @tag verifies: "checkout-totals"
    test "checkout totals the order" do
      assert FixtureDsl.run(Order, :checkout, %{lines: [1, 2]}).total == 3
    end

    test "cancel, piped" do
      refute (Order |> FixtureDsl.run(:cancel, %{reserved: true})).reserved
    end

    test "a capture calls nothing" do
      assert is_function(&FixtureDsl.run/3)
    end
  end
  """

  defp project(root, scanner \\ FixtureDsl.Scanner) do
    File.cp_r!(@project, root)

    File.write!(Path.join(root, "spec.md"), """
    # Checkout
    <!-- surfex: checkout -->

    `Shop.Order.checkout` totals the order and reserves its stock.

    ```test:checkout-totals
    checkout totals the order
    ```
    """)

    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/order_test.exs"), @test_source)

    File.write!(
      Path.join(root, ".surfex.exs"),
      inspect(
        sources: ["spec.md"],
        tests: ["test/*_test.exs"],
        scanners: [:elixir, scanner]
      )
    )

    Config.read!(Path.join(root, ".surfex.exs"))
  end

  defp calls(tests),
    do: Map.new(tests, &{String.replace_prefix(&1.id, "Shop.OrderTest: ", ""), &1.calls})

  test "a test's call through the entry names the action, piped or not; a capture names none" do
    code = Scan.code(FixtureDsl.Scanner.items(@project, []))

    tests =
      Scan.ExUnit.tests(@test_source, "test/order_test.exs", code, [{FixtureDsl.Scanner, []}])

    calls = calls(tests)

    assert "Shop.Order.checkout" in calls["checkout totals the order"]
    assert "Surfex.Test.FixtureDsl.run/3" in calls["checkout totals the order"]
    assert "Shop.Order.cancel" in calls["cancel, piped"]
    refute Enum.any?(calls["a capture calls nothing"], &String.starts_with?(&1, "Shop.Order."))

    # calls/3 is optional: a scanner without it, or none, changes nothing.
    assert Surfex.Scanner.behaviour_info(:optional_callbacks) == [calls: 3]

    for scanners <- [[], [{ItemsOnly, []}]] do
      plain = calls(Scan.ExUnit.tests(@test_source, "test/order_test.exs", code, scanners))
      refute "Shop.Order.checkout" in plain["checkout totals the order"]
    end
  end

  @tag :tmp_dir
  test "a function's call through the entry names the action, and reach goes on through it",
       %{tmp_dir: root} do
    config = project(root)

    File.write!(Path.join(root, "lib/shop/till.ex"), """
    defmodule Shop.Till do
      @moduledoc "Rings up an order."
      alias Surfex.Test.FixtureDsl

      @doc "Checks the order out."
      def ring(order), do: FixtureDsl.run(Shop.Order, :checkout, order)
    end
    """)

    items = Config.items(config, root)
    assert "Shop.Order.checkout" in Enum.find(items, &(&1.name == "ring/1")).calls

    scans = Config.scans(config, root)
    reach = Scan.reach(scans)

    assert Enum.all?(
             ["Shop.Order.checkout", "Shop.Pricing.total/1", "Shop.Stock.reserve/1"],
             &(&1 in reach["Shop.OrderTest: checkout totals the order"])
           )

    refute "Shop.Order.cancel" in reach["Shop.OrderTest: checkout totals the order"]
  end

  @tag :tmp_dir
  test "a run records the action's version for a test driving it", %{tmp_dir: root} do
    project(root)
    file = Path.join(root, "test/order_test.exs")

    {:ok, pid} = GenServer.start_link(Surfex.ExUnitFormatter, surfex_root: root)
    GenServer.cast(pid, {:suite_started, []})

    GenServer.cast(
      pid,
      {:test_finished,
       %ExUnit.Test{name: :t, module: Shop.OrderTest, state: nil, tags: %{file: file, line: 8}}}
    )

    GenServer.cast(pid, {:suite_finished, %{}})
    GenServer.stop(pid)

    assert [%{test: "Shop.OrderTest: checkout totals the order", code: code}] =
             Evidence.load(Evidence.path(root))

    checkout = Enum.find(FixtureDsl.Scanner.items(root, []), &(&1.name == "checkout"))
    assert code["Shop.Order.checkout"] == checkout.hash
    assert Map.has_key?(code, "Shop.Pricing.total/1")
  end

  @tag :tmp_dir
  test "the triangle closes for a claim related to the action; without calls/3 it doesn't",
       %{tmp_dir: root} do
    triangle = fn scanner, dir ->
      config = project(Path.join(root, dir), scanner)
      scans = Config.scans(config, Path.join(root, dir))
      by_id = Map.new(scans, &{&1.id, &1})
      test = "Shop.OrderTest: checkout totals the order"

      entries = [
        relation(:implements, by_id["Shop.Order.checkout"], by_id["spec.md#checkout"]),
        relation(:verifies, by_id[test], by_id["spec.md#checkout-totals"])
      ]

      Status.derive(scans, entries).triangle
    end

    assert triangle.(FixtureDsl.Scanner, "with") == []

    gaps = triangle.(ItemsOnly, "without")

    assert Enum.sort(Enum.map(gaps, &{&1.gap, &1.test, &1.code})) == [
             {:code_untested, nil, "Shop.Order.checkout"},
             {:test_misses_code, "Shop.OrderTest: checkout totals the order", nil}
           ]
  end

  test "an answer that isn't a list of keys raises, naming the scanner" do
    code = Scan.code(FixtureDsl.Scanner.items(@project, []))

    assert_raise ArgumentError, ~r/BadAnswer.calls\/3 must answer a list of item keys/, fn ->
      Scan.ExUnit.tests(@test_source, "test/order_test.exs", code, [{BadAnswer, []}])
    end
  end

  defp relation(type, a, b),
    do:
      Entry.new!(
        at: "2026-10-14T10:00:00Z",
        op: :relate,
        type: type,
        ends: [
          %{kind: a.kind, id: a.id, hash: a.hash},
          %{kind: b.kind, id: b.id, hash: b.hash}
        ]
      )
end
