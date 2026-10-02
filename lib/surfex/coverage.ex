defmodule Surfex.Coverage do
  @moduledoc """
  Adjudicates an item nothing describes: is the silence expected, or is it a gap? The
  relation log asks it when suggesting an `excuses` relation and when judging whether an
  excuse is stale (`Surfex.Suggest`, `Surfex.Status`).

  Most of what code declares is its own factoring (helpers, bookkeeping, plumbing) rather
  than what the spec is about. The profile's rules are by **class**, never by item. A new
  helper falls into its class and stays quiet; a new entry point matches no rule and is a
  gap, which is the direction that matters. Each class carries its reason, so silence is
  always attributable. A `:never_excused` kind is the spec's subject matter: it is a gap
  whatever the rules say. The rules are data in a `Surfex.Profile`.
  """

  alias Surfex.{Item, Profile}

  @type verdict :: :cited | {:expected, String.t()} | :gap

  @typedoc "What a verdict reads: a `Surfex.Profile`, or `Surfex.Profile.coverage!/1`'s map."
  @type rules :: Profile.t() | %{rules: [Profile.rule()], never_excused: [atom]}

  @doc "The verdict for `item`, given the set of cited keys."
  @spec verdict(Item.t(), MapSet.t(String.t()), rules) :: verdict
  def verdict(%Item{} = item, cited, %{rules: _, never_excused: _} = profile) do
    cond do
      MapSet.member?(cited, Item.key(item)) -> :cited
      item.kind in profile.never_excused -> :gap
      true -> Enum.find_value(profile.rules, :gap, &excuse(&1, item, cited))
    end
  end

  defp excuse(
         %{class: class, kinds: kinds, name: name, parent_cited: parent_cited} = rule,
         item,
         cited
       ) do
    if item.kind in kinds and name_matches?(name, item.name) and
         parent_ok?(parent_cited, item.parent, cited) and
         family?(Map.get(rule, :parent), item.parent),
       do: {:expected, class}
  end

  # `parent:` names a module family: it matches a member's parent, never an item with none.
  defp family?(nil, _parent), do: true
  defp family?(re, parent), do: is_binary(parent) and Regex.match?(re, parent)

  defp name_matches?(nil, _name), do: true
  defp name_matches?(re, name), do: Regex.match?(re, name)

  # A member whose parent is cited is covered by the parent's row. Whose parent is not, is
  # not covered by anything.
  defp parent_ok?(false, _parent, _cited), do: true
  defp parent_ok?(true, parent, cited), do: is_binary(parent) and MapSet.member?(cited, parent)
end
