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
            %{s | body: body, last: Enum.max([s.last | Enum.map(inside, & &1.last)])}
        end
      end

    {kept, owners, errors}
  end
end
