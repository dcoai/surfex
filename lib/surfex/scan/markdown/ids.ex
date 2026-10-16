defmodule Surfex.Scan.Markdown.Ids do
  @moduledoc false
  # The ids a heading or rule is given: written, or read by the project's grammars.

  import Surfex.Scan.Markdown.Lines, only: [checked_id!: 4]

  @anchor ~r/^(.*?)\s*\{#([^}\s]*)\}$/
  @heading_comment ~r/^(.*?)\s*<!--\s*surfex:\s*(\S+)\s*-->$/

  def explicit_id(st, text, no) do
    cond do
      match = Regex.run(@heading_comment, text, capture: :all_but_first) ->
        [text, id] = match
        {text, checked_id!(st, no, id, "heading")}

      match = Regex.run(@anchor, text, capture: :all_but_first) ->
        [text, id] = match
        {text, checked_id!(st, no, id, "anchor")}

      true ->
        {text, nil}
    end
  end

  # The first grammar that matches the heading reads its id.
  def grammar_id(%{grammar: grammars} = st, text, no),
    do: read_id(grammars, st, text, no, "heading")

  def read_id(grammars, st, text, no, what) do
    Enum.find_value(grammars, fn grammar ->
      case Regex.named_captures(grammar, text) do
        %{"id" => id} -> checked_id!(st, no, id, what)
        nil -> nil
      end
    end)
  end

  # `heading_ids:` (or `rule_ids:`, read the same way) is one grammar or a list of them,
  # tried in order.
  def heading_grammars(nil, _key), do: []
  def heading_grammars(list, key) when is_list(list), do: Enum.map(list, &grammar!(&1, key))
  def heading_grammars(one, key), do: [grammar!(one, key)]

  defp grammar!(nil, key), do: raise(ArgumentError, "#{key}: a list can't hold nil")

  defp grammar!(named, _key) when named in [:section_sign, :section_number],
    do: heading_grammar(named)

  defp grammar!(%Regex{} = regex, key) do
    if "id" in Regex.names(regex),
      do: regex,
      else: raise(ArgumentError, "#{key}: #{inspect(regex)} needs a named capture (?<id>…)")
  end

  defp grammar!(other, key),
    do:
      raise(
        ArgumentError,
        "#{key}: must be :section_sign, :section_number, a regex with (?<id>…) or a list of them, got #{inspect(other)}"
      )

  @doc """
  The regex a `heading_ids:` setting names, with a named capture `id`: `:section_sign` for
  a leading `§ID` (`§Api.3.2`), `:section_number` for a leading `1.`, `1.2`, `1.2.3`, whose
  last part may end in a letter before its dot (`2a.`), or the project's own regex. Raises
  on anything else, or a regex with no `id` capture. The setting may also be a list of
  these, tried in order.
  """
  @spec heading_grammar(atom | Regex.t() | nil) :: Regex.t() | nil
  def heading_grammar(nil), do: nil

  def heading_grammar(:section_sign),
    do: ~r/^§\s*(?<id>[A-Za-z0-9][A-Za-z0-9._:-]*?)[.:]?(?=\s|$)/u

  def heading_grammar(:section_number),
    do: ~r/^(?<id>\d+(?:\.\d+)*(?:[a-z](?=\.))?)\.?(?=\s|$)/

  def heading_grammar(%Regex{} = regex) do
    if "id" in Regex.names(regex),
      do: regex,
      else: raise(ArgumentError, "heading_ids: #{inspect(regex)} needs a named capture (?<id>…)")
  end

  def heading_grammar(other),
    do:
      raise(
        ArgumentError,
        "heading_ids: must be :section_sign, :section_number, a regex with (?<id>…) or a list of them, got #{inspect(other)}"
      )
end
