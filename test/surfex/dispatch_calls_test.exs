defmodule Surfex.DispatchCallsTest do
  # #272: a call to a declared dispatch function reaches the handlers its module's table
  # lists (spec §11.10).
  use ExUnit.Case, async: true
  @moduletag verifies: "dispatch-calls"

  alias Surfex.{Scan, Status}
  alias Surfex.Status.{Config, Report}

  @lib """
  defmodule Shop.Ops do
    @moduledoc "Runs an operation's handler, looked up in a table."
    alias Shop.Ops.{Carts, Orders}

    @handlers %{
      place: {Orders, :place},
      add: {Carts, :add},
      peek: &Carts.peek/1,
      gone: {Elsewhere, :thing}
    }

    @doc "Runs the handler of `op`."
    def run(op, input) do
      {module, fun} = Map.fetch!(@handlers, op)
      apply(module, fun, [input])
    end
  end

  defmodule Shop.Ops.Orders do
    @moduledoc "Orders."
    @doc "Places an order."
    def place(input), do: {:placed, input}
    @doc "Places an order, with options."
    def place(input, opts), do: {:placed, input, opts}
  end

  defmodule Shop.Ops.Carts do
    @moduledoc "Carts."
    @doc "Adds to a cart."
    def add(input), do: {:added, input}
    @doc "Peeks into a cart."
    def peek(input), do: input
    @doc "Peeks into a cart, twice."
    def peek(input, again), do: {input, again}
    @doc "Not in the table."
    def unused(input), do: input
  end

  defmodule Shop.Web do
    @moduledoc "The endpoint."
    @doc "Handles a request."
    def handle(op, input), do: Shop.Ops.run(op, input)
  end

  defmodule Shop.Lazy do
    @moduledoc "Dispatches through a table it is handed."
    @doc "Runs what `table` holds for `op`."
    def run(table, op), do: apply(table[op], :call, [])
  end
  """

  @tests """
  defmodule Shop.WebTest do
    use ExUnit.Case

    test "an endpoint request" do
      assert Shop.Web.handle(:place, 1)
    end

    test "the dispatcher, directly" do
      assert Shop.Ops.run(:add, 1)
    end
  end
  """

  defmodule PlaceOnly do
    @moduledoc false
    # Answers for a call that runs the `:place` operation, and for nothing else.
    @behaviour Surfex.Scanner
    @impl true
    def items(_root, _opts), do: []

    @impl true
    def calls({{:., _, [{:__aliases__, _, [:Shop, :Ops]}, :run]}, _, [:place | _]}, _, _),
      do: ["Shop.Ops.Orders.place/1"]

    def calls(_call, _aliases, _opts), do: []
  end

  defp project(root, extra) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "lib/shop.ex"), @lib)
    File.write!(Path.join(root, "test/web_test.exs"), @tests)
    File.write!(Path.join(root, "spec.md"), "# Shop\n\nThe shop runs operations.\n")

    config = [sources: ["spec.md"], tests: ["test/*_test.exs"]] ++ extra
    File.write!(Path.join(root, ".surfex.exs"), inspect(config))
    Config.read!(Path.join(root, ".surfex.exs"))
  end

  defp reach(root, extra) do
    scans = Config.scans(project(root, extra), root)
    Scan.reach(scans)
  end

  @tag :tmp_dir
  @tag verifies: ["dispatch-calls", "dispatch-reach"]
  test "a call to a declared dispatcher reaches what its table lists", %{tmp_dir: root} do
    reach = reach(root, dispatch: [{Shop.Ops, :run, 2}])
    endpoint = reach["Shop.WebTest: an endpoint request"]

    # {Module, :fun} names every arity defined; &Module.fun/arity its arity alone.
    for id <- ~w(Shop.Ops.run/2 Shop.Ops.Orders.place/1 Shop.Ops.Orders.place/2
                 Shop.Ops.Carts.add/1 Shop.Ops.Carts.peek/1 Shop.Ops.Orders Shop.Ops.Carts),
        do: assert(id in endpoint, id)

    refute "Shop.Ops.Carts.peek/2" in endpoint
    refute "Shop.Ops.Carts.unused/1" in endpoint

    # A test calling the dispatcher itself reaches the table too.
    assert "Shop.Ops.Carts.add/1" in reach["Shop.WebTest: the dispatcher, directly"]

    # Without dispatch: the handlers are reached by nothing.
    plain = reach(Path.join(root, "plain"), [])["Shop.WebTest: an endpoint request"]
    assert "Shop.Ops.run/2" in plain
    refute "Shop.Ops.Orders.place/1" in plain
    refute "Shop.Ops.Carts.add/1" in plain
  end

  @tag :tmp_dir
  @tag verifies: ["dispatch-calls", "dispatch-unresolved"]
  test "each dispatcher is listed with its reading, an unresolved one never failing", %{
    tmp_dir: root
  } do
    config = project(root, dispatch: [{Shop.Lazy, :run, 2}, {Shop.Ops, :run, 2}])
    scans = Config.scans(config, root)
    status = Status.derive(scans, [])

    assert status.dispatch == [
             %{
               dispatcher: "Shop.Lazy.run/2",
               targets: [],
               unscanned: [],
               unresolved: true
             },
             %{
               dispatcher: "Shop.Ops.run/2",
               targets: ~w(Shop.Ops.Carts.add/1 Shop.Ops.Carts.peek/1 Shop.Ops.Orders.place/1
                           Shop.Ops.Orders.place/2),
               unscanned: ["Elsewhere.thing"],
               unresolved: false
             }
           ]

    # The unresolved one reaches nothing beyond it.
    from = Scan.reacher(scans)
    assert from.(["Shop.Lazy.run/2"]) == ["Shop.Lazy.run/2"]
    refute Status.failing?(status)

    text = Report.text(status)
    assert text =~ "Dispatch ("
    assert text =~ "dispatch Shop.Lazy.run/2: unresolved"
    assert text =~ "dispatch Shop.Ops.run/2: Shop.Ops.Carts.add/1, "
    assert text =~ "not scanned: Elsewhere.thing"

    assert [%{"dispatcher" => "Shop.Lazy.run/2", "unresolved" => true}, ops] =
             JSON.decode!(Report.json(status))["dispatch"]

    assert ops["unscanned"] == ["Elsewhere.thing"]

    golden = status |> Report.golden("RELATIONS.md") |> Surfex.Golden.render()
    assert golden =~ "dispatchers 2"
    assert golden =~ "`dispatch Shop.Ops.run/2`"
    assert golden =~ "`Shop.Ops.Orders.place/2`"

    # Without dispatch: nothing is listed.
    plain_root = Path.join(root, "plain")
    plain = Status.derive(Config.scans(project(plain_root, []), plain_root), [])
    assert plain.dispatch == []
    refute Report.text(plain) =~ "Dispatch"
    assert JSON.decode!(Report.json(plain))["dispatch"] == []
    plain_golden = plain |> Report.golden("RELATIONS.md") |> Surfex.Golden.render()
    refute plain_golden =~ "dispatchers"
    refute plain_golden =~ "## dispatch"
  end

  @tag :tmp_dir
  @tag verifies: ["dispatch-calls", "dispatch-unresolved"]
  test "a malformed dispatch: or an undefined dispatcher is refused", %{tmp_dir: root} do
    assert_raise ArgumentError, ~r/dispatch: must be a list of \{Module, :fun, arity\}/, fn ->
      Config.dispatch!(dispatch: [{Shop.Ops, :run}])
    end

    assert Config.dispatch!(dispatch: [{Shop.Ops, :run, 2}]) == ["Shop.Ops.run/2"]
    assert Config.dispatch!([]) == []

    assert_raise ArgumentError, ~r/dispatch: Shop.Ops.run\/3 isn't a function/, fn ->
      Config.scans(project(root, dispatch: [{Shop.Ops, :run, 3}]), root)
    end
  end

  @tag :tmp_dir
  @tag verifies: ["dispatch-calls", "dispatch-calls-precedence"]
  test "a scanner's calls/3 answer takes precedence over the table", %{tmp_dir: root} do
    reach = reach(root, dispatch: [{Shop.Ops, :run, 2}], scanners: [:elixir, PlaceOnly])

    # A call the scanner doesn't answer (`run(:add, …)`) still reaches the table.
    direct = reach["Shop.WebTest: the dispatcher, directly"]
    assert "Shop.Ops.Carts.add/1" in direct

    # A call the scanner answers reaches its answer alone.
    File.write!(
      Path.join(root, "test/place_test.exs"),
      """
      defmodule Shop.PlaceTest do
        use ExUnit.Case

        test "place" do
          assert Shop.Ops.run(:place, 1)
        end
      end
      """
    )

    config = Config.read!(Path.join(root, ".surfex.exs"))
    place = Scan.reach(Config.scans(config, root))["Shop.PlaceTest: place"]
    assert "Shop.Ops.Orders.place/1" in place
    refute "Shop.Ops.Carts.add/1" in place
    refute "Shop.Ops.Orders.place/2" in place
  end
end
