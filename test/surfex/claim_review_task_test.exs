defmodule Surfex.ClaimReviewTaskTest do
  # #329: mix surfex.suggest --accept records structural suggestions and the citation
  # bootstrap, never a claim-derived implements; each of those is printed with the
  # commands that relate and decline it, then one count line (§15.5). The task reads the
  # working directory and the Mix shell, which are global.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.cp_r!(Path.expand("../fixtures/elixir_project", __DIR__), root)

    File.write!(Path.join(root, "spec.md"), """
    # Carts
    <!-- surfex: carts -->

    Carts hold lines.

    ```test:totals
    a cart totals its lines
    ```

    ```test:makes-line
    a line is made from an item
    ```

    # Lines
    <!-- surfex: lines -->

    A line is made by `MyApp.Cart.Line.new/1`.
    """)

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "test/cart_test.exs"), """
    defmodule MyApp.CartTest do
      use ExUnit.Case

      @tag verifies: "totals"
      test "totals" do
        assert MyApp.Cart.total() == 0
        assert MyApp.Cart.Line.new(:x) == {:x, 1}
      end

      @tag verifies: "makes-line"
      test "makes a line" do
        assert MyApp.Cart.Line.new(:y) == {:y, 1}
      end
    end
    """)

    File.write!(
      Path.join(root, ".surfex.exs"),
      ~s([sources: ["spec.md"], tests: ["test/*_test.exs"]])
    )

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp crt_suggest(root, args) do
    File.cd!(root, fn -> Mix.Tasks.Surfex.Suggest.run(args) end)
    crt_drain()
  end

  defp crt_drain(acc \\ []) do
    receive do
      {:mix_shell, :info, [text]} -> crt_drain([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tag verifies: ["accept-skips-claim-candidates", "accept-records"]
  test "--accept records the structural and cited suggestions, never a claim-derived one", %{
    tmp_dir: root
  } do
    File.cd!(root, fn -> Mix.Tasks.Surfex.Log.run(["--init"]) end)
    crt_drain()

    lines = crt_suggest(root, [])
    text = Enum.join(lines, "\n")

    # totals' tests call total/0 and Line.new/1; makes-line's call Line.new/1 too, so it
    # is totals' less specific call: counted, not proposed.
    assert text =~
             "implements  spec.md#totals ↔ MyApp.Cart.total/0  (called by its test MyApp.CartTest: totals)"

    assert text =~
             "implements  spec.md#makes-line ↔ MyApp.Cart.Line.new/1  (called by its test " <>
               "MyApp.CartTest: makes a line; also called by the tests of 1 other claim)"

    assert text =~
             ~s(  relate:  mix surfex.relate "spec:spec.md#totals" "code:MyApp.Cart.total/0" --type implements)

    assert text =~
             ~s(  decline: mix surfex.retire "spec:spec.md#totals" "code:MyApp.Cart.total/0")

    assert "also called spec.md#totals: +1 call also made by the tests of other claims" in lines
    refute text =~ "spec.md#totals ↔ MyApp.Cart.Line.new/1"

    assert List.last(Enum.drop(lines, -1)) ==
             "2 claim-derived implements to review one at a time: not recorded by --accept"

    # The citation's candidate has no relate line: --accept records it.
    refute text =~ ~s(relate:  mix surfex.relate "spec:spec.md#lines")

    crt_suggest(root, ["--accept", "--note", "upkeep"])
    entries = Surfex.Log.load(root)
    implements = for %{type: :implements} = e <- entries, do: Enum.map(e.ends, & &1.id)
    assert implements == [["MyApp.Cart.Line.new/1", "spec.md#lines"]]
    assert Enum.any?(entries, &(&1.type == :refines))
    assert Enum.any?(entries, &(&1.type == :tests))
    assert Enum.any?(entries, &(&1.type == :verifies))

    # Only the claim-derived candidates are left: listed, and --accept isn't offered.
    lines = crt_suggest(root, [])
    assert "2 claim-derived implements to review one at a time: not recorded by --accept" in lines
    refute Enum.any?(lines, &(&1 =~ "--accept` records them"))
    refute Enum.any?(lines, &(&1 =~ "nothing to suggest"))
  end

  @tag verifies: ["claim-candidates-specific", "accept-records"]
  test "--format json carries shared and whether --accept records each", %{tmp_dir: root} do
    File.cd!(root, fn -> Mix.Tasks.Surfex.Log.run(["--init"]) end)
    crt_drain()

    [json] = crt_suggest(root, ["--format", "json"])
    implements = JSON.decode!(json)["implements"]

    assert %{"shared" => 1, "accept" => false, "cited_at" => nil} =
             Enum.find(implements, &(&1["spec"] == "spec.md#makes-line"))

    assert %{"shared" => nil, "accept" => true, "cited_at" => "spec.md:" <> _} =
             Enum.find(implements, &(&1["spec"] == "spec.md#lines"))

    assert_raise Mix.Error, ~r/--format json/, fn ->
      crt_suggest(root, ["--format", "json", "--accept"])
    end
  end
end
