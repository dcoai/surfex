defmodule Surfex.Scanner.ElixirTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "elixir-scanner-items"

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
    # Only hidden.ex: its @moduledoc false module is skipped, the module nested in it isn't.
    assert Scanner.items(@project, paths: ["lib/my_app/hidden.ex"]) |> Enum.map(&Item.key/1) ==
             [
               "MyApp.Hidden.Visible",
               "MyApp.Hidden.Visible.shown/0",
               "MyApp.Server",
               "MyApp.Server.handle_call/3",
               "MyApp.Server.start_link/1"
             ]
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
    test "shape matches the namespace's names and nothing else" do
      d = Scanner.profile_defaults("MyApp")

      for name <- ~w(MyApp MyApp.Cart MyApp.Cart.add MyApp.Cart.add/2 MyApp.Cart.valid?/1),
          do: assert(Regex.match?(d[:shape], name), name)

      for name <- ~w(Enum.map/2 :ok MyAppX.Cart myapp.cart Other.MyApp.Cart),
          do: refute(Regex.match?(d[:shape], name), name)

      # token: the same names, found inside longer text.
      assert Regex.scan(d[:token], "see MyApp.Cart.add/2 and Other.MyApp.x here",
               capture: :all_but_first
             ) == [["MyApp.Cart.add/2"]]
    end

    # #69: a name ends where a name ends; a root glued to more letters is another word.
    @tag verifies: "name-boundary"
    test "a token ends at a name's end: a glued or hyphenated suffix is no name" do
      d = Scanner.profile_defaults("MyApp")

      for text <- [
            "the header MyApp-Profile: <key>",
            "MyAppCollector.Forge.* builds it",
            "MyAppWeb.DomainLive.Show renders",
            "see MyApp.Units-old"
          ],
          do: assert(Regex.scan(d[:token], text, capture: :all_but_first) == [], text)

      assert Regex.scan(d[:token], "call MyApp.Units.convert/3. Then", capture: :all_but_first) ==
               [["MyApp.Units.convert/3"]]
    end

    @tag verifies: "name-boundary"
    test "several roots: every top-level module the code has is a root" do
      d = Scanner.profile_defaults(["MyApp", "MyAppWeb"])
      assert Regex.match?(d[:shape], "MyAppWeb.DomainLive.Show")
      assert Regex.match?(d[:shape], "MyApp.Units.convert/3")
      refute Regex.match?(d[:shape], "MyAppCollector.Forge")
    end

    # #69's case, end to end with generic names: only the real citation is suggested, and a stale
    # name under one of the project's roots is reported, not hidden behind the root module.
    @tag verifies: "name-boundary"
    test "a glued name, a header and a stale name under a second root: only the real citation is suggested, and the stale name is unresolved" do
      root = Path.join(System.tmp_dir!(), "surfex_roots_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "spec.md"), """
      # Profiles

      The header `MyApp-Profile: <key> sha256:<hex>` carries it.

      # Forge

      The collector's `MyAppCollector.Forge.*` builds it.

      # Show

      `MyAppWeb.DomainLive.Show` renders a domain.

      # Units

      `MyApp.Units.convert/3` converts.
      """)

      items = [
        %Surfex.Item{kind: :module, name: "MyApp", file: "lib/m.ex", hash: "1"},
        %Surfex.Item{kind: :module, name: "MyAppWeb", file: "lib/w.ex", hash: "2"},
        %Surfex.Item{kind: :module, name: "MyApp.Units", file: "lib/u.ex", hash: "3"},
        %Surfex.Item{
          kind: :function,
          name: "convert/3",
          parent: "MyApp.Units",
          file: "lib/u.ex",
          hash: "4"
        }
      ]

      config = [sources: ["spec.md"]]
      profile = Surfex.Status.Config.profile!(config, "MyApp", items)
      scans = Surfex.Scan.Markdown.records(root, ["spec.md"]) ++ Surfex.Scan.code(items)

      suggested =
        for c <- Surfex.Suggest.candidates(profile, items, scans, [], root),
            do: {c.spec.id, c.code.id}

      assert suggested == [{"spec.md#Units", "MyApp.Units.convert/3"}]

      assert [%{span: "MyAppWeb.DomainLive.Show", status: :unresolved}] =
               Surfex.Status.Config.broken_citations(config, items, root, "MyApp")
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
