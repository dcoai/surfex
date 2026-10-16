defmodule Surfex.Scan.Markdown.Table do
  @moduledoc false
  # Marked tables (§11): the table's unit and one per row, keyed by its key cells.

  import Surfex.Scan.Markdown.Lines, only: [fail: 3]

  @separator ~r/^ {0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

  # The table's unit (its header and separator) and one unit per row, keyed by its key cell.
  # A table whose header can't be read is a scan error and no unit; a row with an empty key
  # is one, and the other rows are still units.
  def close_table(%{table: table} = st) do
    lines = Enum.reverse(table.lines)

    case lines do
      [_header, {separator, sep_no} | _rows] ->
        if Regex.match?(@separator, separator),
          do: columns(%{st | table: nil}, table, lines),
          else:
            fail(
              %{st | table: nil},
              sep_no,
              "table #{table.id} has no separator row under its header"
            )

      _ ->
        fail(
          %{st | table: nil},
          table.first,
          "table #{table.id} has no separator row under its header"
        )
    end
  end

  # The key and ignored columns, by header: each one missing is an error, as is an ignored
  # key column, and then the table is no unit.
  defp columns(st, table, [{header_line, _} | _] = lines) do
    header = cells(header_line)
    named = if table.key, do: table.key, else: []
    found = Map.new(named ++ table.ignore, &{&1, column(header, &1)})

    missing =
      for name <- Enum.uniq(named ++ table.ignore),
          found[name] == nil,
          do: "table #{table.id} has no column #{inspect(name)}"

    keys = if table.key, do: Enum.map(table.key, &found[&1]), else: [0]

    clashing =
      for name <- table.ignore,
          found[name] != nil and found[name] in keys,
          do: "table #{table.id} can't ignore its key column #{inspect(name)}"

    case missing ++ clashing do
      [] ->
        units(st, table, lines, keys, Enum.map(table.ignore, &found[&1]))

      whys ->
        Enum.reduce(whys, st, &fail(&2, table.first, &1))
    end
  end

  defp units(st, table, [{header, _}, {separator, _} | rows] = lines, keys, ignored) do
    {_, last} = List.last(lines)

    table_unit = %{
      role: :table,
      id: table.id,
      first: table.first,
      last: last,
      body: [header, separator],
      within: table.within
    }

    {st, row_units} =
      Enum.reduce(rows, {st, []}, fn {row, no}, {st, units} ->
        row_cells = cells(row)
        parts = for c <- keys, do: row_cells |> Enum.at(c, "") |> key_text()

        if "" in parts do
          {fail(st, no, "a row of table #{table.id} has an empty key"), units}
        else
          unit = %{
            role: :row,
            id: "#{table.id}/#{Enum.join(parts, "/")}",
            first: no,
            last: no,
            body: row_version(row, row_cells, ignored),
            within: {:table, table.id}
          }

          {st, [unit | units]}
        end
      end)

    %{st | units: row_units ++ [table_unit | st.units]}
  end

  defp column(header, name), do: Enum.find_index(header, &(key_text(&1) == key_text(name)))

  # A row's version covers its cells, less the columns `ignore:` names.
  defp row_version(row, _cells, []), do: [row]

  defp row_version(_row, cells, ignored) do
    kept = for {cell, c} <- Enum.with_index(cells), c not in ignored, do: cell
    [Enum.join(kept, "|")]
  end

  # A marker's text after its id: `key:` and `ignore:`, in either order, each a column
  # header or a bracketed list of them. Anything else is an error, never silently body:
  # `{st, options}`, an option given twice keeping its first value.
  def table_options(st, no, id, text) do
    text
    |> String.trim()
    |> case do
      "" -> []
      text -> Regex.split(~r/\s+(?=(?:key|ignore):)/, text)
    end
    |> Enum.reduce({st, %{}}, fn option, {st, acc} ->
      case Regex.run(~r/^(key|ignore):\s*(\S.*)$/, option, capture: :all_but_first) do
        [name, value] ->
          name = Map.fetch!(%{"key" => :key, "ignore" => :ignore}, name)

          if Map.has_key?(acc, name),
            do: {fail(st, no, "table #{id}'s marker gives #{name}: twice"), acc},
            else: {st, Map.put(acc, name, column_names(value))}

        nil ->
          {fail(
             st,
             no,
             "table #{id}'s marker has text that isn't key: or ignore: (#{inspect(option)})"
           ), acc}
      end
    end)
  end

  defp column_names(value) do
    case Regex.run(~r/^\[(.*)\]$/, value, capture: :all_but_first) do
      [list] -> list |> String.split(",") |> Enum.map(&String.trim/1)
      nil -> [value]
    end
  end

  # A row's cells: split on `|` outside code spans and not escaped, without the outer pipes.
  defp cells(line) do
    line
    |> String.trim()
    |> String.replace_prefix("|", "")
    |> String.replace_suffix("|", "")
    |> String.graphemes()
    |> Enum.reduce({[""], false, false}, fn
      c, {[cell | done], code, true} -> {[cell <> c | done], code, false}
      "\\", {[cell | done], code, false} -> {[cell <> "\\" | done], code, true}
      "`", {[cell | done], code, false} -> {[cell <> "`" | done], not code, false}
      "|", {cells, false, false} -> {["" | cells], false, false}
      c, {[cell | done], code, false} -> {[cell <> c | done], code, false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A key as written, without its code and emphasis marks: `` `:normal` `` is `:normal`.
  defp key_text(cell) do
    text = cell |> String.replace("`", "") |> String.replace("\\|", "|") |> String.trim()
    stripped = Regex.replace(~r/^(\*\*|__|\*|_)(.+)\1$/, text, "\\2")
    if stripped == text, do: text |> String.split() |> Enum.join(" "), else: key_text(stripped)
  end
end
