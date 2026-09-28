defmodule Surfex.ItemTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "item-key"

  alias Surfex.Item

  test "an item's key is its name, or parent.name when it has a parent" do
    assert Item.key(%Item{kind: :module, name: "MyApp.Cart", file: "c.ex", hash: "1"}) ==
             "MyApp.Cart"

    assert Item.key(%Item{
             kind: :function,
             name: "add/2",
             parent: "MyApp.Cart",
             file: "c.ex",
             hash: "1"
           }) ==
             "MyApp.Cart.add/2"
  end
end
