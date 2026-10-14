defmodule ShopWeb.Endpoint do
  @moduledoc "The web endpoint."
  use Phoenix.Endpoint, otp_app: :shop

  plug Plug.RequestId
  plug ShopWeb.Router
end
