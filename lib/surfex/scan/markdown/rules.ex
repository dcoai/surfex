defmodule Surfex.Scan.Markdown.Rules do
  @moduledoc false
  # Rules (§11.1): a named paragraph or list item, and the list items they are read from.

  import Surfex.Scan.Markdown.Lines
  import Surfex.Scan.Markdown.ClassMarkers, only: [class_line: 3, own_marker?: 2]

  alias Surfex.Scan.Markdown.Fence

  @list_item ~r/^( *)([-*+]|\d{1,9}[.)])(?:([ \t]+)(.*))?$/
  @lead_comment ~r/^<!--\s*surfex:\s*(\S+)\s*-->\s*(.*)$/

  # ── Rules ───────────────────────────────────────────────────────────────

  # A rule opens on its first line: a list item (with its content's indent) or a paragraph
  # (`content: nil`). Its version is its text without the list marker or the id comment.
  def open_rule(st, id, item, no) do
    text =
      case lead(item.text) do
        {_id, rest} -> rest
        nil -> item.text
      end

    rule = %{
      id: id,
      first: no,
      last: no,
      body: [text],
      within: within(st),
      content: item.content,
      blank: false
    }

    %{st | rule: rule, cur: %{st.cur | last: no}}
  end

  # A paragraph ends at a blank line or anything that interrupts it. An item takes every
  # line indented to its content, and a lazy continuation of its text; a less indented
  # line after a blank one, another item at its level or above, a marker, a fence or a
  # heading ends it.
  def rule_ends?(st, %{content: nil}, line) do
    String.trim(line) == "" or heading(line) != nil or own_marker?(st, line) or
      Fence.info(line) != nil or list_item(line) != nil
  end

  def rule_ends?(st, rule, line) do
    cond do
      String.trim(line) == "" -> false
      heading(line) != nil -> true
      indent(line) >= rule.content -> false
      rule.blank -> true
      true -> list_item(line) != nil or own_marker?(st, line) or Fence.info(line) != nil
    end
  end

  def rule_line(%{rule: rule} = st, line, no) do
    {_prose?, fence} = Fence.step(line, st.fence)
    opened? = st.fence == nil and fence != nil
    item = if st.fence == nil, do: list_item(line)

    cond do
      opened? and hint_id(line) != nil ->
        id = checked_id!(st, no, hint_id(line), "test hint")
        hint = %{id: id, first: no, body: [], within: within(st)}
        %{st | fence: fence, hint: hint, cur: extend(st.cur, line, no)}

      item != nil and lead(item.text) != nil ->
        fail(st, no, "rule #{rule.id} (line #{rule.first}) can't hold another rule")

      st.fence == nil and class_line(st, line, no) != nil ->
        fail(
          st,
          no,
          "a class or deferral marker can't sit in rule #{rule.id} (line #{rule.first}): a rule is a claim"
        )

      true ->
        blank? = String.trim(line) == ""
        last = if blank?, do: rule.last, else: no
        rule = %{rule | body: [line | rule.body], last: last, blank: blank? and fence == nil}
        %{st | fence: fence, rule: rule, cur: extend(st.cur, line, no)}
    end
  end

  def close_rule(%{rule: rule} = st),
    do: %{st | rule: nil, units: [unit(rule, :rule, rule.last) | st.units]}

  # A list item's line: its indent, its content's indent, its kind and its text. A thematic break
  # (`- - -`) isn't one.
  def list_item(line) do
    if Regex.match?(~r/^ {0,3}([-*_])( *\1){2,} *$/, line) do
      nil
    else
      case Regex.run(@list_item, line) do
        [_, spaces, marker] ->
          %{
            indent: String.length(spaces),
            content: String.length(spaces <> marker) + 1,
            kind: list_kind(marker),
            text: ""
          }

        [_, spaces, marker, gap, text] ->
          gap = if String.length(gap) > 4, do: 1, else: String.length(gap)

          %{
            indent: String.length(spaces),
            content: String.length(spaces <> marker) + gap,
            kind: list_kind(marker),
            text: text
          }

        nil ->
          nil
      end
    end
  end

  # Items of one list share a bullet, or an ordered delimiter; another starts a new list.
  defp list_kind(marker), do: if(marker in ["-", "*", "+"], do: marker, else: String.last(marker))

  # An id comment starting a text, `<!-- surfex: ID --> …`: `{id, the rest}`.
  def lead(text) do
    case Regex.run(@lead_comment, String.trim_leading(text), capture: :all_but_first) do
      [id, rest] -> {id, rest}
      nil -> nil
    end
  end

  # A list item that starts with an id comment: `{item, id}`.
  def item_lead(line) do
    with %{} = item <- list_item(line),
         {id, _rest} <- lead(item.text),
         do: {item, id},
         else: (_ -> nil)
  end

  # A paragraph whose first token is an id comment, with text after it on the line.
  def paragraph_lead(line) do
    case indent(line) <= 3 && lead(line) do
      {id, rest} when rest != "" -> id
      _ -> nil
    end
  end
end
