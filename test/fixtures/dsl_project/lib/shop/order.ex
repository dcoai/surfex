defmodule Shop.Order do
  @moduledoc "An order, declared with the fixture DSL."
  use Surfex.Test.FixtureDsl

  alias Shop.Pricing

  attribute :total, :integer

  action :checkout do
    change &Pricing.total/1
    change &Shop.Stock.reserve/1
  end

  action :cancel do
    change &Shop.Stock.release/1
  end
end
