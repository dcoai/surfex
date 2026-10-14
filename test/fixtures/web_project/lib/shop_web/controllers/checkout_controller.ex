defmodule ShopWeb.CheckoutController do
  @moduledoc "Checks a cart out."
  use Phoenix.Controller

  @doc "Checks the cart out."
  def create(conn, %{"id" => id}), do: json(conn, Shop.Carts.checkout(id))

  @doc "Drops the cart."
  def delete(conn, _params), do: send_resp(conn, 204, "")
end
