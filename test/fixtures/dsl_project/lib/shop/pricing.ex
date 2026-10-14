defmodule Shop.Pricing do
  @moduledoc "Prices an order."

  @doc "The order with its total."
  def total(order), do: Map.put(order, :total, Enum.sum(order.lines))
end
