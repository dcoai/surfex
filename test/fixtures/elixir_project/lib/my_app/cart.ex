defmodule MyApp.Cart do
  @moduledoc "A cart."

  @doc "Adds an item."
  def add(cart, item, qty \\ 1)
  def add(%{closed: true}, _item, _qty), do: {:error, :closed}
  def add(cart, item, qty), do: {:ok, [{item, qty} | cart]}

  def add(cart), do: cart

  @doc false
  def internal(x), do: x

  def after_hidden(x), do: x

  defmacro is_cart(x), do: quote(do: is_list(unquote(x)))
  defguard is_small(n) when n < 10
  defdelegate size(cart), to: Enum, as: :count

  defp helper(x), do: x

  def total, do: helper(0)

  defmodule Line do
    @moduledoc "A line."
    def new(item), do: {item, 1}
  end
end
