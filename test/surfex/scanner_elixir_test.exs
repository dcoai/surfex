defmodule Surfex.Scanner.ElixirTest do
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Profile}
  alias Surfex.Scanner.Elixir, as: Scanner

  @project Path.expand("../fixtures/elixir_project", __DIR__)

  defp keys(items), do: Enum.map(items, &{Item.key(&1), &1.kind})

  test "a fixture project scans to exactly its public API" do
    assert keys(Scanner.items(@project)) == [
             {"MyApp.Cart", :module},
             {"MyApp.Cart.Line", :module},
             {"MyApp.Cart.Line.new/1", :function},
             {"MyApp.Cart.add/1", :function},
             {"MyApp.Cart.add/2", :function},
             {"MyApp.Cart.add/3", :function},
             {"MyApp.Cart.after_hidden/1", :function},
             {"MyApp.Cart.is_cart/1", :macro},
             {"MyApp.Cart.is_small/1", :macro},
             {"MyApp.Cart.size/1", :function},
             {"MyApp.Cart.total/0", :function},
             {"MyApp.Hidden.Visible", :module},
             {"MyApp.Hidden.Visible.shown/0", :function},
             {"MyApp.Server", :module},
             {"MyApp.Server.handle_call/3", :function},
             {"MyApp.Server.start_link/1", :function}
           ]
  end

  test "items carry parent, file, alias and one hash per function" do
    items = Map.new(Scanner.items(@project), &{Item.key(&1), &1})
    add2 = items["MyApp.Cart.add/2"]

    assert %Item{parent: "MyApp.Cart", file: "lib/my_app/cart.ex", aliases: ["MyApp.Cart.add"]} =
             add2

    # The default-argument arities share the function's one hash; add/1 is its own function.
    assert add2.hash == items["MyApp.Cart.add/3"].hash
    refute add2.hash == items["MyApp.Cart.add/1"].hash
    assert items["MyApp.Cart"].aliases == []
  end

  test ":paths narrows the scan" do
    assert Scanner.items(@project, paths: ["lib/my_app/hidden.ex"])
           |> Enum.map(&Item.key/1)
           |> Enum.all?(&(String.starts_with?(&1, "MyApp.Hidden") or &1 =~ "Server"))
  end

  test "surfex's own lib scans to its public API, compile-free" do
    keys = Scanner.items(Path.expand("../..", __DIR__)) |> Enum.map(&Item.key/1)

    for key <- ~w(Surfex.Golden Surfex.Golden.render/1 Surfex.SourceScan.defs/1
                  Surfex.Cite.citations/3 Surfex.Coverage.verdict/3 Surfex.Profile.new!/1
                  Surfex.Item.key/1 Surfex.Scanner Surfex.Scanner.Elixir.items/1
                  Surfex.Scanner.Elixir.items/2 Surfex.Scanner.Elixir.profile_defaults/1) do
      assert key in keys, "#{key} missing from the scan of surfex itself"
    end

    # Private helpers are not surface.
    refute Enum.any?(keys, &String.contains?(&1, "strip_meta"))
  end

  describe "profile_defaults/1" do
    setup do
      %{d: Scanner.profile_defaults("MyApp")}
    end

    test "shape matches the namespace's names and nothing else", %{d: d} do
      for name <- ~w(MyApp MyApp.Cart MyApp.Cart.add MyApp.Cart.add/2 MyApp.Cart.valid?/1),
          do: assert(Regex.match?(d[:shape], name), name)

      for name <- ~w(Enum.map/2 :ok MyAppX.Cart myapp.cart Other.MyApp.Cart),
          do: refute(Regex.match?(d[:shape], name), name)
    end

    test "citing a function without its arity cites every arity; a call's arguments drop" do
      items = Scanner.items(@project)
      root = Path.join(System.tmp_dir!(), "surfex_elixir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "spec.md"), """
      # Carts
      `MyApp.Cart.add` rejects a closed cart; `MyApp.Cart.total/0` is free.
      `MyApp.Cart.remove/1` is planned. Calling `MyApp.Cart.size(cart)` counts.
      ```elixir
      MyApp.Cart.Line.new(:apple)
      ```
      """)

      profile = Profile.new!([sources: ["spec.md"]] ++ Scanner.profile_defaults("MyApp"))
      by_span = Cite.citations(items, profile, root) |> Map.new(&{&1.span, &1})

      assert %{status: :resolved, items: ~w(MyApp.Cart.add/1 MyApp.Cart.add/2 MyApp.Cart.add/3)} =
               by_span["MyApp.Cart.add"]

      assert %{status: :resolved, items: ["MyApp.Cart.total/0"]} = by_span["MyApp.Cart.total/0"]
      assert %{status: :unresolved} = by_span["MyApp.Cart.remove/1"]
      assert %{status: :resolved, items: ["MyApp.Cart.size/1"]} = by_span["MyApp.Cart.size(cart)"]

      assert %{section: "(code block)", items: ["MyApp.Cart.Line.new/1"]} =
               by_span["MyApp.Cart.Line.new"]
    end
  end
end
