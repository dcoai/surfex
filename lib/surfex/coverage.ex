defmodule Surfex.Coverage do
  @moduledoc """
  Adjudicates an item the spec does not cite: is the silence expected, or is it a gap?

  Without this, a trace's headline number is mostly noise. Most of what code declares is
  its own factoring (helpers, bookkeeping, plumbing) rather than what the spec is about,
  and a coverage document whose uncited count is mostly that gets read once.

  The profile's rules are by **class**, never by item. A new helper falls into its class
  and stays quiet; a new entry point matches no rule and is a gap, which is the direction
  that matters. Each class carries the reason a golden prints, so silence is always
  attributable. A `:never_excused` kind is the spec's subject matter: an uncited one is a
  gap whatever the rules say. The rules are data in a `Surfex.Profile`.
  """

  alias Surfex.{Item, Profile}

  @type verdict :: :cited | {:expected, String.t()} | :gap

  @doc "The verdict for `item`, given the set of cited keys."
  @spec verdict(Item.t(), MapSet.t(String.t()), Profile.t()) :: verdict
  def verdict(%Item{} = item, cited, %Profile{} = profile) do
    cond do
      MapSet.member?(cited, Item.key(item)) -> :cited
      item.kind in profile.never_excused -> :gap
      true -> Enum.find_value(profile.rules, :gap, &excuse(&1, item, cited))
    end
  end

  @doc """
  Every item paired with its own verdict, in item order, from the citations
  `Surfex.Cite.by_item/2` joined.

  Pairs, not a map keyed by `Item.key/1`: two items may share a key (a citation of it is
  then ambiguous), and each still needs its own verdict. Keyed by key, one would overwrite
  the other, and a GAP could vanish from the gate (#15).
  """
  @spec verdicts([Item.t()], %{String.t() => [String.t()]}, Profile.t()) :: [
          {Item.t(), verdict}
        ]
  def verdicts(items, by_item, %Profile{} = profile) do
    cited = MapSet.new(Map.keys(by_item))
    Enum.map(items, &{&1, verdict(&1, cited, profile)})
  end

  defp excuse(%{class: class, kinds: kinds, name: name, parent_cited: parent_cited}, item, cited) do
    if item.kind in kinds and name_matches?(name, item.name) and
         parent_ok?(parent_cited, item.parent, cited),
       do: {:expected, class}
  end

  defp name_matches?(nil, _name), do: true
  defp name_matches?(re, name), do: Regex.match?(re, name)

  # A member whose parent is cited is covered by the parent's row. Whose parent is not, is
  # not covered by anything.
  defp parent_ok?(false, _parent, _cited), do: true
  defp parent_ok?(true, parent, cited), do: is_binary(parent) and MapSet.member?(cited, parent)
end
