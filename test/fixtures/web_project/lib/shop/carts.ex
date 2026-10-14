defmodule Shop.Carts do
  @moduledoc "Carts."

  @doc "A cart."
  def get(id), do: %{id: id, items: []}

  @doc "Adds an item."
  def add(cart, sku), do: %{cart | items: [sku | cart.items]}

  @doc "Checks a cart out."
  def checkout(id), do: %{id: id, paid: true}
end

defmodule Shop.Stock do
  @moduledoc "Stock levels, held by a server."
  use GenServer

  @doc "Starts the server."
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:level, sku}, _from, state), do: {:reply, Map.get(state, sku, 0), state}

  @impl true
  def handle_cast({:put, sku, n}, state), do: {:noreply, Map.put(state, sku, n)}
end
