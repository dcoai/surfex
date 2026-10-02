defmodule Surfex.ScanExUnitTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "scan-records-pure"

  alias Surfex.Scan
  alias Surfex.Scan.ExUnit, as: Tests

  @source ~S'''
  defmodule MyApp.CartTest do
    use ExUnit.Case
    @moduletag verifies: "carts"
    @limit 3

    setup :cart

    defp cart(_ctx), do: %{cart: []}
    defp full?(cart), do: length(cart) >= @limit

    test "starts empty", %{cart: cart} do
      assert cart == []
    end

    describe "adding" do
      @describetag verifies: "cart-add"
      setup do
        %{item: :apple}
      end

      @tag verifies: ["cart-add-closed", "spec.md#Carts/Adding items"]
      @tag :slow
      test "rejects a closed cart", %{cart: cart, item: item} do
        refute full?([item | cart])
      end

      test "adds one" do
        assert true
      end
    end

    for {name, n} <- [{"one", 1}, {"two", 2}] do
      test "counts #{name}" do
        assert unquote(n) > 0
      end
    end
  end
  '''

  defp tests(source \\ @source), do: Tests.tests(source, "test/cart_test.exs")
  defp by_id(source \\ @source), do: Map.new(tests(source), &{&1.id, &1})
  defp version(source \\ @source, id), do: by_id(source)[id].hash

  defp changes?(from, to, id) do
    assert @source =~ from
    version(id) != version(String.replace(@source, from, to), id)
  end

  @closed "MyApp.CartTest: adding: rejects a closed cart"

  test "one record per test: module, describe and name, in source order" do
    assert Enum.map(tests(), & &1.id) == [
             "MyApp.CartTest: starts empty",
             @closed,
             "MyApp.CartTest: adding: adds one",
             ~S"MyApp.CartTest: counts #{name}"
           ]

    assert Enum.all?(tests(), &match?(%Scan{kind: :test, role: nil}, &1))
    assert by_id()[@closed].location == %{file: "test/cart_test.exs", lines: {23, 25}}
  end

  test "declarations come from @tag, @describetag and @moduletag" do
    assert by_id()[@closed].declares == [
             {:verifies, "carts"},
             {:verifies, "cart-add"},
             {:verifies, "cart-add-closed"},
             {:verifies, "spec.md#Carts/Adding items"}
           ]

    assert by_id()["MyApp.CartTest: adding: adds one"].declares ==
             [{:verifies, "carts"}, {:verifies, "cart-add"}]

    # A @tag applies to the next test only.
    assert by_id()["MyApp.CartTest: starts empty"].declares == [{:verifies, "carts"}]
  end

  @tag verifies: "test-versions"
  test "the version follows helpers, attributes, setups and a comprehension's generators" do
    assert changes?("length(cart) >= @limit", "length(cart) > @limit", @closed)
    assert changes?("@limit 3", "@limit 4", @closed)
    assert changes?("%{item: :apple}", "%{item: :pear}", @closed)
    assert changes?("%{cart: []}", "%{cart: [:x]}", "MyApp.CartTest: starts empty")
    assert changes?(~S|{"two", 2}]|, ~S|{"two", 0}]|, ~S"MyApp.CartTest: counts #{name}")

    # What it doesn't read, and a variable's name, aren't part of it.
    refute changes?("%{item: :apple}", "%{item: :pear}", "MyApp.CartTest: starts empty")

    renamed =
      @source
      |> String.replace("item: item}", "item: thing}")
      |> String.replace("full?([item | cart])", "full?([thing | cart])")

    assert version(renamed, @closed) == version(@closed)
  end

  test "two tests with one id are numbered" do
    twice =
      "defmodule T do\n  test \"a\", do: :ok\n  describe \"x\" do\n  end\n  test \"a\", do: :ok\nend\n"

    assert Enum.map(tests(twice), & &1.id) == ["T: a", "T: a~2"]
  end

  test "a verifies value that isn't literal raises, naming the line" do
    bad = "defmodule T do\n  @tag verifies: some_ids()\n  test \"a\", do: :ok\nend\n"

    assert_raise ArgumentError, ~r"test/cart_test.exs:2: verifies: must be a string", fn ->
      tests(bad)
    end
  end

  @tag :tmp_dir
  test "records/2 reads globs under a root", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/cart_test.exs"), @source)
    assert length(Tests.records(root, ["test/**/*_test.exs"])) == 4
  end

  describe "Scan.resolve/2" do
    defp spec(id, role),
      do: %Scan{kind: :spec, id: id, hash: "h", location: %{file: "f", lines: {1, 1}}, role: role}

    @scans [
      %Scan{
        kind: :spec,
        id: "spec.md#Carts/Adding items",
        hash: "h",
        location: %{file: "spec.md", lines: {1, 1}},
        role: :section
      },
      %Scan{
        kind: :spec,
        id: "spec.md#cart-add",
        hash: "h",
        location: %{file: "spec.md", lines: {1, 1}},
        role: :section
      },
      %Scan{
        kind: :spec,
        id: "spec.md#closed",
        hash: "h",
        location: %{file: "spec.md", lines: {1, 1}},
        role: :block
      },
      %Scan{
        kind: :spec,
        id: "other.md#closed",
        hash: "h",
        location: %{file: "other.md", lines: {1, 1}},
        role: :block
      }
    ]

    test "a full id, or a bare anchor, block or hint id" do
      assert {:ok, %{id: "spec.md#Carts/Adding items"}} =
               Scan.resolve(@scans, "spec.md#Carts/Adding items")

      assert {:ok, %{id: "spec.md#cart-add"}} = Scan.resolve(@scans, "cart-add")

      assert {:ok, %{id: "spec.md#closed"}} =
               Scan.resolve([spec("spec.md#closed", :test_hint)], "closed")
    end

    test "unknown, ambiguous, and never a heading path by its bare name" do
      assert {:error, :unknown} = Scan.resolve(@scans, "Carts/Adding items")
      assert {:error, :unknown} = Scan.resolve(@scans, "nothing")

      assert {:error, {:ambiguous, ["other.md#closed", "spec.md#closed"]}} =
               Scan.resolve(@scans, "closed")
    end
  end

  test "calls: aliases, pipes, captures and imports resolved, helpers followed, modules named" do
    source = ~S'''
    defmodule MyApp.CartTest do
      use ExUnit.Case
      alias MyApp.Cart
      alias MyApp.{Line, Price}
      alias MyApp.Tax, as: T
      import MyApp.Fixtures

      defp build(item), do: item |> Line.new() |> Price.of(:eur)

      test "a" do
        cart = Cart.new()
        cart |> Cart.add(build(:apple)) |> T.apply()
        Enum.map([1], &Cart.total/1)
        fixture(:x)
        local_helper()
      end

      def local_helper, do: :ok
    end
    '''

    [test] = Tests.tests(source, "t.exs")

    # Each function it calls, and each module it calls or names (#62).
    assert test.calls == [
             "Enum",
             "Enum.map/2",
             "MyApp.Cart",
             "MyApp.Cart.add/2",
             "MyApp.Cart.new/0",
             "MyApp.Cart.total/1",
             "MyApp.Fixtures.fixture/1",
             "MyApp.Line",
             "MyApp.Line.new/1",
             "MyApp.Price",
             "MyApp.Price.of/2",
             "MyApp.Tax",
             "MyApp.Tax.apply/1"
           ]
  end

  test "a setup's calls are not the test's: it prepares, the test is what it calls" do
    source = ~S"""
    defmodule T do
      use ExUnit.Case
      setup_all do
        %{seeded: MyApp.Seed.run()}
      end

      setup do
        %{cart: MyApp.Cart.new()}
      end

      test "a", %{cart: cart}, do: assert(MyApp.Cart.total(cart) == 0)
    end
    """

    [test] = Tests.tests(source, "t.exs")
    assert test.calls == ["MyApp.Cart", "MyApp.Cart.total/1"]

    # A setup is still part of the test's version.
    [changed] =
      Tests.tests(String.replace(source, "MyApp.Seed.run()", "MyApp.Seed.run(:all)"), "t.exs")

    refute changed.hash == test.hash
  end

  test "a module handed to a helper counts as exercised" do
    source = ~S"""
    defmodule T do
      use ExUnit.Case
      defp run(module, args), do: module.run(args)
      test "a", do: run(Mix.Tasks.Surfex.Status, [])
    end
    """

    assert "Mix.Tasks.Surfex.Status" in hd(Tests.tests(source, "t.exs")).calls
  end

  # #62: a helper defined inside a describe block is the module's function too.
  # #87: an alias applies where it's declared, as the compiler sees it.
  describe "aliases are lexical" do
    @describetag verifies: "test-alias-scope"

    defp calls_of(source), do: Map.new(Tests.tests(source, "t.exs"), &{&1.id, &1.calls})

    test "an alias in a test body applies to that test, from its line on" do
      calls =
        calls_of(~S"""
        defmodule T do
          use ExUnit.Case

          test "a" do
            Cart.empty()
            alias MyApp.Cart
            Cart.total([])
          end

          test "b", do: Cart.total([])
        end
        """)

      assert "MyApp.Cart.total/1" in calls["T: a"]
      # Before its alias, Cart is Cart: the line it's declared on is where it starts.
      assert "Cart.empty/0" in calls["T: a"]
      refute "MyApp.Cart.empty/0" in calls["T: a"]
      # Another test doesn't see it.
      assert calls["T: b"] == ["Cart", "Cart.total/1"]
    end

    test "a describe's alias applies to its tests and helpers, not to a sibling describe" do
      calls =
        calls_of(~S"""
        defmodule T do
          use ExUnit.Case

          describe "d" do
            alias MyApp.Cart, as: C
            defp total(x), do: C.total(x)
            test "a", do: total([])
            test "b", do: C.add([], 1)
          end

          describe "e" do
            test "c", do: C.add([], 1)
          end
        end
        """)

      assert "MyApp.Cart.total/1" in calls["T: d: a"]
      assert "MyApp.Cart.add/2" in calls["T: d: b"]
      assert calls["T: e: c"] == ["C", "C.add/2"]
    end

    test "every form: alias A.B, as:, and A.{B, C}, at any level" do
      calls =
        calls_of(~S"""
        defmodule T do
          use ExUnit.Case
          alias MyApp.Line

          describe "d" do
            alias MyApp.{Cart, Price}

            test "a" do
              alias MyApp.Tax, as: T
              Line.new(Cart.total([]), Price.of(1), T.rate())
            end
          end
        end
        """)

      assert Enum.all?(
               ~w(MyApp.Line.new/3 MyApp.Cart.total/1 MyApp.Price.of/1 MyApp.Tax.rate/0),
               &(&1 in calls["T: d: a"])
             )
    end
  end

  test "a describe block's helpers are followed, for the version and the calls" do
    source = ~S"""
    defmodule T do
      use ExUnit.Case

      describe "d" do
        defp check(x), do: MyApp.Cart.total(x) == 0
        test "a", do: assert(check([]))
      end
    end
    """

    [test] = Tests.tests(source, "t.exs")
    assert "MyApp.Cart.total/1" in test.calls

    [weakened] = Tests.tests(String.replace(source, "== 0", ">= 0"), "t.exs")
    refute weakened.hash == test.hash
  end
end
