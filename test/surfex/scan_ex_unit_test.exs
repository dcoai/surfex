defmodule Surfex.ScanExUnitTest do
  use ExUnit.Case, async: true

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

  test "calls: aliases, pipes, captures and imports resolved, helpers followed" do
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

    assert test.calls == [
             "Enum.map/2",
             "MyApp.Cart.add/2",
             "MyApp.Cart.new/0",
             "MyApp.Cart.total/1",
             "MyApp.Fixtures.fixture/1",
             "MyApp.Line.new/1",
             "MyApp.Price.of/2",
             "MyApp.Tax.apply/1"
           ]
  end
end
