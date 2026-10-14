defmodule Shop.Stock do
  @moduledoc "Holds stock for orders."

  @doc "Reserves the order's stock."
  def reserve(order), do: Map.put(order, :reserved, true)

  @doc "Releases the order's stock."
  def release(order), do: Map.put(order, :reserved, false)
end
