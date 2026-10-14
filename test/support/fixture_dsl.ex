defmodule Surfex.Test.FixtureDsl do
  @moduledoc false
  # A small DSL, as a library would offer one, so surfex's tests prove the scanner contract
  # for DSL items (spec §4.1, §5.4) without surfex depending on any DSL. A module `use`s it
  # and declares actions, each a block of `change` steps naming the functions it applies:
  #
  #     defmodule Shop.Order do
  #       use Surfex.Test.FixtureDsl
  #
  #       action :checkout do
  #         change &Shop.Pricing.total/1
  #       end
  #     end
  #
  # A caller drives an action through the DSL's entry, naming the resource and the action:
  # `Surfex.Test.FixtureDsl.run(Shop.Order, :checkout, order)`. No `def` names the action:
  # it is the block, which is what makes it a DSL item rather than a function.

  defmacro __using__(_opts) do
    quote do
      import Surfex.Test.FixtureDsl, only: [action: 2, attribute: 2]
    end
  end

  @doc false
  defmacro action(name, do: block) do
    steps =
      for {:change, _, [fun]} <- block(block), do: fun

    quote do
      def __action__(unquote(name)), do: unquote(steps)
    end
  end

  @doc false
  # A declaration with no behaviour of its own: it defines nothing.
  defmacro attribute(_name, _type), do: nil

  defp block({:__block__, _, steps}), do: steps
  defp block(step), do: [step]

  @doc false
  # The entry: runs `action` of `resource` on `input`, each step in order.
  def run(resource, action, input),
    do: Enum.reduce(resource.__action__(action), input, fn step, acc -> step.(acc) end)
end
