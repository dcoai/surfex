defmodule Surfex.FrameworkCallsTest do
  # #206 (B.2), #243: calls a test states through a framework rather than by name. A
  # request to a route the router maps, an event to the view it mounted, and a message to a
  # named GenServer resolve from source, so they are calls and reach follows them (§11).
  use ExUnit.Case, async: true

  alias Surfex.Scan
  alias Surfex.Status.Config

  @project Path.expand("../fixtures/web_project", __DIR__)

  @test_source ~S'''
  defmodule ShopWeb.CartTest do
    use ExUnit.Case
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest
    alias ShopWeb.CartLive

    test "a live route mounts its view" do
      {:ok, view, _html} = live(conn, "/carts/42")
      assert render(view) =~ "42"
    end

    test "a verified path with params, and its query string" do
      id = 42
      {:ok, _view, _html} = live(conn, ~p"/carts/#{id}?tab=items")
    end

    test "a literal route wins where the router declares it first" do
      {:ok, _view, _html} = conn |> live("/carts/new")
    end

    test "an unknown path, or a path in a variable, is no call" do
      live(conn, "/nowhere")
      path = "/carts/1"
      live(conn, path)
      section = "carts"
      live(conn, ~p"/#{section}/1")
    end

    test "a controller route calls its action" do
      post(conn, "/carts/7/checkout")
      conn |> delete(~p"/carts/#{7}")
      get(conn, "/files/a/b/c.txt")
    end

    test "a scope's alias joins the route's module" do
      Phoenix.LiveViewTest.live(conn, "/admin/orders")
    end

    test "live_isolated mounts the module it names" do
      live_isolated(conn, CartLive.New, session: %{})
    end

    test "events go to the view a request mounted" do
      {:ok, view, _html} = live(conn, ~p"/carts/#{1}")
      render_click(view, "add", %{"sku" => "x"})
      view |> element("button#add") |> render_click()
      view |> form("#cart") |> render_submit()
    end

    test "an event to a view no resolved request mounted is no call" do
      {:ok, view, _html} = live(conn, "/nowhere")
      render_click(view, "add", %{})
      render_click(other_view, "add", %{})
    end

    test "messages to a named GenServer" do
      GenServer.call(Shop.Stock, {:level, "x"})
      Shop.Stock |> GenServer.cast({:put, "x", 1})
      GenServer.call(pid, :anything)
    end

    test "a capture handed to a helper is the test's call" do
      Helper.growth(&Shop.Carts.add/2, 10, 1000)
    end
  end
  '''

  defp routes, do: Config.routes([sources: ["spec.md"]], @project)

  defp calls do
    code = Scan.code(Surfex.Scanner.Elixir.items(@project))
    tests = Scan.ExUnit.tests(@test_source, "test/cart_test.exs", code, [], routes())
    Map.new(tests, &{String.replace_prefix(&1.id, "ShopWeb.CartTest: ", ""), &1.calls})
  end

  @tag verifies: ["route-calls"]
  test "the router is found from the endpoint, its scopes joined in order" do
    assert [health, home, new, show, item, checkout, drop, admin, files] = routes()

    assert %{verb: :get, segments: ["health"], module: "ShopWeb.HealthController", action: :show} =
             health

    assert %{segments: [], module: "ShopWeb.HomeLive", live: true} = home
    assert %{segments: ["carts", "new"], module: "ShopWeb.CartLive.New"} = new
    assert %{segments: ["carts", {:param, "id"}], module: "ShopWeb.CartLive.Show"} = show
    assert %{segments: ["carts", {:param, "id"}, "items", {:param, "item"}]} = item
    assert %{verb: :post, module: "ShopWeb.CheckoutController", action: :create} = checkout
    assert %{verb: :delete, action: :delete} = drop
    assert %{module: "ShopWeb.Admin.OrderLive"} = admin
    assert %{segments: ["files", {:glob, "path"}], module: "ShopWeb.FileController"} = files

    # Named, the same router; off, none; a router the source doesn't define, or a
    # router: of another shape, is refused.
    assert Config.routes([router: ShopWeb.Router], @project) == routes()
    assert Config.routes([router: false], @project) == []

    assert_raise ArgumentError, ~r/router: ShopWeb.Nope isn't defined/, fn ->
      Config.routes([router: ShopWeb.Nope], @project)
    end

    assert_raise ArgumentError, ~r/router: must be a module/, fn ->
      Config.routes([router: "ShopWeb.Router"], @project)
    end
  end

  @tag verifies: ["route-calls"]
  test "a request calls what its route runs: a view's mount and handle_params, or an action" do
    calls = calls()

    show = [
      "ShopWeb.CartLive.Show",
      "ShopWeb.CartLive.Show.mount/3",
      "ShopWeb.CartLive.Show.handle_params/3"
    ]

    for name <- [
          "a live route mounts its view",
          "a verified path with params, and its query string"
        ],
        do: assert(show -- calls[name] == [], name)

    assert "ShopWeb.CartLive.New.mount/3" in calls[
             "a literal route wins where the router declares it first"
           ]

    refute "ShopWeb.CartLive.Show.mount/3" in calls[
             "a literal route wins where the router declares it first"
           ]

    refute Enum.any?(
             calls["an unknown path, or a path in a variable, is no call"],
             &String.starts_with?(&1, "ShopWeb.")
           )

    controller = calls["a controller route calls its action"]
    assert "ShopWeb.CheckoutController.create/2" in controller
    assert "ShopWeb.CheckoutController.delete/2" in controller
    assert "ShopWeb.FileController.show/2" in controller

    assert "ShopWeb.Admin.OrderLive.mount/3" in calls["a scope's alias joins the route's module"]

    isolated = calls["live_isolated mounts the module it names"]
    assert "ShopWeb.CartLive.New.mount/3" in isolated
    refute "ShopWeb.CartLive.New.handle_params/3" in isolated

    # Without routes nothing resolves: the router is what makes a path a call.
    code = Scan.code(Surfex.Scanner.Elixir.items(@project))
    [plain | _] = Scan.ExUnit.tests(@test_source, "test/cart_test.exs", code)
    refute "ShopWeb.CartLive.Show.mount/3" in plain.calls
  end

  @tag verifies: ["event-calls"]
  test "an event to a view a request mounted calls its handle_event/3" do
    calls = calls()

    assert "ShopWeb.CartLive.Show.handle_event/3" in calls[
             "events go to the view a request mounted"
           ]

    refute Enum.any?(
             calls["an event to a view no resolved request mounted is no call"],
             &String.ends_with?(&1, "handle_event/3")
           )
  end

  @tag verifies: ["message-calls"]
  test "a message to a GenServer named by its module calls its callback; a capture is a call" do
    calls = calls()
    messages = calls["messages to a named GenServer"]
    assert "Shop.Stock.handle_call/3" in messages
    assert "Shop.Stock.handle_cast/2" in messages

    refute Enum.any?(
             messages,
             &(String.ends_with?(&1, ".handle_call/3") and
                 not String.starts_with?(&1, "Shop.Stock."))
           )

    assert "Shop.Carts.add/2" in calls["a capture handed to a helper is the test's call"]
  end

  @tag :tmp_dir
  @tag verifies: ["route-calls"]
  test "a project's scans pass its routes to the test scanner", %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n<!-- surfex: carts -->\n\nCarts.\n")
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/cart_test.exs"), @test_source)

    scans =
      Config.scans([sources: ["spec.md"], tests: ["test/*_test.exs"]], root)

    test = Enum.find(scans, &(&1.id == "ShopWeb.CartTest: a live route mounts its view"))
    assert "ShopWeb.CartLive.Show.mount/3" in test.calls

    off = Config.scans([sources: ["spec.md"], tests: ["test/*_test.exs"], router: false], root)
    test = Enum.find(off, &(&1.id == "ShopWeb.CartTest: a live route mounts its view"))
    refute "ShopWeb.CartLive.Show.mount/3" in test.calls
  end

  @tag verifies: ["route-calls", "message-calls"]
  test "reach goes on from a route and a message into the code they run" do
    code = Scan.code(Surfex.Scanner.Elixir.items(@project))
    tests = Scan.ExUnit.tests(@test_source, "test/cart_test.exs", code, [], routes())
    reach = Scan.reach(tests ++ code)

    assert "Shop.Carts.get/1" in reach["ShopWeb.CartTest: a live route mounts its view"]

    assert "Shop.Carts.add/2" in reach[
             "ShopWeb.CartTest: events go to the view a request mounted"
           ]

    assert "Shop.Carts.checkout/1" in reach[
             "ShopWeb.CartTest: a controller route calls its action"
           ]

    assert "Shop.Stock" in reach["ShopWeb.CartTest: messages to a named GenServer"]
  end
end
