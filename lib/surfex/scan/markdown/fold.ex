defmodule Surfex.Scan.Markdown.Fold do
  @moduledoc false
  # Folding path headings into the id'd section above them (`fold_paths:`, §11.1).

  # With fold_paths: a section with no id, inside a section that has one (through any path
  # sections between), is part of that section: its heading line and body join the id'd
  # section's body, which runs to its last line. The sections left, %{folded n =>
  # owner n} for what sat in a folded one, and the scan errors.
  def fold(sections, file) do
    by_n = Map.new(sections, &{&1.n, &1})

    owner = fn s ->
      Stream.iterate(s.parent, &(&1 && by_n[&1].parent))
      |> Enum.find(fn p -> p == nil or by_n[p].anchor != nil end)
    end

    owners =
      for s <- sections,
          s.heading != nil,
          s.anchor == nil,
          o = owner.(s),
          o != nil,
          into: %{},
          do: {s.n, o}

    folded =
      sections
      |> Enum.filter(&Map.has_key?(owners, &1.n))
      |> Enum.group_by(&Map.fetch!(owners, &1.n))

    # A class or deferral marker under a folded heading would class the unit it folds into,
    # which its author didn't mark (§11.7): a scan error.
    errors =
      for {owner, inside} <- folded,
          s <- inside,
          %{line: line} <- [s.class, s.deferred] do
        %{
          file: file,
          line: line,
          message:
            "the marker sits under \"#{s.heading}\", which fold_paths: folds " <>
              "into \"#{by_n[owner].heading}\": it would class that unit; give the heading an " <>
              "id of its own or move the marker"
        }
      end

    kept =
      for s <- sections, not Map.has_key?(owners, s.n) do
        case Map.get(folded, s.n, []) do
          [] ->
            s

          inside ->
            body = s.body ++ Enum.flat_map(inside, &[&1.heading | &1.body])
            [{first, last} | _] = ranges = ranges(s, inside)
            Map.merge(s, %{body: body, first: first, last: last, ranges: ranges})
        end
      end

    {kept, owners, errors}
  end

  # A folded unit's lines (§11.13): its own, then each folded section's, one range where no
  # other unit sits between (the next section in order is the one folded), so the unit
  # never claims the lines of a sibling unit between its parts.
  defp ranges(owner, inside) do
    inside
    |> Enum.reduce([{owner.n, owner.first, owner.last}], fn s, [{n, first, last} | done] ->
      if s.n == n + 1,
        do: [{s.n, first, max(last, s.last)} | done],
        else: [{s.n, s.first, s.last}, {n, first, last} | done]
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_n, first, last} -> {first, last} end)
  end

  # A heading with no id among siblings (the same level, under the same parent) the heading
  # grammar numbered is almost always a missed id, not a subsection (§11.12): each is a
  # warning on the unit it reads as, its owner where fold_paths: folds it, else its own.
  # %{unit id => [%{kind: :path_heading, line, message}]}.
  def path_headings(sections, ids, owners) do
    for s <- sections,
        s.heading != nil and s.anchor == nil,
        siblings = numbered_siblings(sections, s),
        siblings != [],
        unit = Map.fetch!(ids, Map.get(owners, s.n, s.n)),
        reduce: %{} do
      acc ->
        warning = %{
          kind: :path_heading,
          line: s.first,
          message: path_message(s, siblings, owners, unit)
        }

        Map.update(acc, unit, [warning], &(&1 ++ [warning]))
    end
  end

  defp numbered_siblings(sections, s),
    do:
      Enum.filter(
        sections,
        &(&1.n != s.n and Map.get(&1, :numbered) == true and Map.get(&1, :parent) == s.parent and
            Map.get(&1, :level) == s.level)
      )

  # Names the numbered siblings nearest it, before and after.
  defp path_message(s, siblings, owners, unit) do
    {before, later} = Enum.split_with(siblings, &(&1.n < s.n))
    near = Enum.reject([List.last(before), List.first(later)], &is_nil/1)
    named = Enum.map_join(near, ", ", &"#{&1.anchor}")

    reads =
      if Map.has_key?(owners, s.n),
        do: "fold_paths: folds it into #{unit}",
        else: "it is a unit of its own, #{unit}"

    "\"#{String.duplicate("#", s.level)} #{s.heading}\" has no id among numbered siblings " <>
      "(#{named}): a missed id? #{reads}"
  end
end
