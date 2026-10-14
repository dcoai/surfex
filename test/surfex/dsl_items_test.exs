defmodule Surfex.DslItemsTest do
  # #208, #240: a DSL item is a Surfex.Item a project scanner gives for a block a DSL
  # declares (spec §4.1). The fixture DSL and its scanner live in test/support, so surfex
  # depends on no DSL.
  use ExUnit.Case, async: true
  @moduletag verifies: "dsl-item-shape"

  alias Surfex.{Item, Scan}
  alias Surfex.Status.Config
  alias Surfex.Test.FixtureDsl

  @project Path.expand("../fixtures/dsl_project", __DIR__)

  defp items(root \\ @project),
    do: Map.new(FixtureDsl.Scanner.items(root, []), &{Item.key(&1), &1})

  test "one item per block, keyed Module.name, with its kind, parent, file and lines" do
    items = items()
    assert Map.keys(items) == ["Shop.Order.cancel", "Shop.Order.checkout", "Shop.Order.total"]

    assert %Item{kind: :action, parent: "Shop.Order", name: "checkout", file: "lib/shop/order.ex"} =
             checkout = items["Shop.Order.checkout"]

    assert checkout.lines == {9, 12}
    refute checkout.shape
    assert checkout.hidden == %{} and checkout.runs == %{}

    # A declaration with no behaviour of its own is a shape.
    assert %Item{kind: :attribute, shape: true, calls: []} = items["Shop.Order.total"]
  end

  test "an action lists the functions and modules its block references" do
    assert items()["Shop.Order.checkout"].calls == [
             "Shop.Pricing",
             "Shop.Pricing.total/1",
             "Shop.Stock",
             "Shop.Stock.reserve/1"
           ]
  end

  @tag :tmp_dir
  test "a block's hash changes with the block, not with a sibling or the layout",
       %{tmp_dir: root} do
    File.cp_r!(@project, root)
    before = items(root)
    order = Path.join(root, "lib/shop/order.ex")
    source = File.read!(order)

    File.write!(order, String.replace(source, "&Shop.Stock.release/1", "&Shop.Stock.reserve/1"))
    changed = items(root)
    refute changed["Shop.Order.cancel"].hash == before["Shop.Order.cancel"].hash
    assert changed["Shop.Order.checkout"].hash == before["Shop.Order.checkout"].hash

    File.write!(order, String.replace(source, "  action :checkout", "\n\n  action :checkout"))
    moved = items(root)
    assert moved["Shop.Order.checkout"].hash == before["Shop.Order.checkout"].hash
    refute moved["Shop.Order.checkout"].lines == before["Shop.Order.checkout"].lines
  end

  @tag :tmp_dir
  test "beside the Elixir scanner, a DSL key is a code record and a citation of it resolves",
       %{tmp_dir: root} do
    File.cp_r!(@project, root)

    File.write!(Path.join(root, "spec.md"), """
    # Checkout

    `Shop.Order.checkout` totals the order and reserves its stock.
    """)

    config = [sources: ["spec.md"], scanners: [:elixir, FixtureDsl.Scanner]]
    {scans, options} = Config.load(config, root, "Shop")

    assert %Scan{kind: :code, role: :action, within: "Shop.Order"} =
             Enum.find(scans, &(&1.id == "Shop.Order.checkout"))

    assert Enum.any?(scans, &(&1.id == "Shop.Pricing.total/1"))
    assert options[:citations] == []

    items = Config.items(config, root)
    profile = Config.profile!(config, "Shop", items)

    assert [%{span: "Shop.Order.checkout", status: :resolved, items: ["Shop.Order.checkout"]}] =
             Surfex.Cite.citations(items, profile, root)
  end
end
