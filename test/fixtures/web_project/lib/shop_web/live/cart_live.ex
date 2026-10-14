defmodule ShopWeb.CartLive.Show do
  @moduledoc "One cart."
  use Phoenix.LiveView

  @impl true
  def mount(%{"id" => id}, _session, socket), do: {:ok, assign(socket, cart: Shop.Carts.get(id))}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add", %{"sku" => sku}, socket),
    do: {:noreply, assign(socket, cart: Shop.Carts.add(socket.assigns.cart, sku))}
end

defmodule ShopWeb.CartLive.New do
  @moduledoc "A new cart."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}
end
