defmodule ShopWeb.Router do
  @moduledoc "Routes."
  use ShopWeb, :router

  scope "/", ShopWeb do
    get "/health", HealthController, :show
    live "/", HomeLive
  end

  scope "/carts", ShopWeb do
    pipe_through :browser

    live_session :carts, on_mount: [] do
      live "/new", CartLive.New
      live "/:id", CartLive.Show, :show
      live "/:id/items/:item", CartLive.Item
    end

    post "/:id/checkout", CheckoutController, :create
    delete "/:id", CheckoutController, :delete
  end

  scope "/admin", ShopWeb.Admin, as: :admin do
    live "/orders", OrderLive
  end

  scope "/files" do
    get "/*path", ShopWeb.FileController, :show
  end
end
