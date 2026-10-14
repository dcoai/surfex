defmodule Surfex.Gate do
  @moduledoc """
  The write-or-check step every golden shares, so no project writes it again.

  A golden is a pure function of source. The gate either writes the fresh render
  (`--write`) or compares it with the committed bytes and says what changed. The
  comparison reads the committed file, not a re-derivation: it is the committed bytes
  that are being checked.
  """

  @doc """
  Writes `golden` to `path` when `write?`; otherwise checks the file against it. Returns
  the failures, one message each: `[]` when the file is current or was just written.
  `command` is what regenerates it, quoted back to the reader.
  """
  @spec run(String.t(), String.t(), String.t(), boolean) :: [String.t()]
  def run(path, golden, command, write?) do
    name = Path.basename(path)

    cond do
      write? ->
        File.write!(path, golden)
        []

      not File.exists?(path) ->
        ["#{name} does not exist. Run `#{command} --write`."]

      message = drift(File.read!(path), golden) ->
        ["#{name}: #{message}\nRegenerate with `#{command} --write` once the source is right."]

      true ->
        []
    end
  end

  @doc """
  Evaluates a `.surfex.exs`-style data file, which must return a keyword list. Raises
  naming the file when it is missing or is not one.
  """
  @spec config!(String.t()) :: keyword
  def config!(path) do
    unless File.exists?(path), do: raise(ArgumentError, "#{path} does not exist")
    {config, _binding} = Code.eval_file(path)

    unless Keyword.keyword?(config),
      do: raise(ArgumentError, "#{path} must evaluate to a keyword list")

    config
  end

  @doc """
  What changed between a committed golden and a fresh render, or `nil` when they are
  identical: the rows that changed, appeared or went. A changed row names each cell that
  differs, `State :current → :retired`. A change outside every row is reported as such.

  A table is told apart by its `##` heading and its header row. A row is keyed by the cells
  that identify it, read from the table itself: its `Item` column when that names every row
  once on both sides, else the fewest leading columns that do (`End` and `Other end` in a
  relation table, where many rows share an `End`). Rows are compared whole.
  """
  @spec drift(String.t(), String.t()) :: String.t() | nil
  def drift(same, same), do: nil

  def drift(old, new) do
    old_tables = tables(old)
    new_tables = tables(new)
    ids = Enum.uniq(Enum.map(new_tables, &elem(&1, 0)) ++ Enum.map(old_tables, &elem(&1, 0)))

    {changed, added, gone} =
      ids
      |> Enum.map(&compare(&1, rows_of(old_tables, &1), rows_of(new_tables, &1)))
      |> Enum.reduce({[], [], []}, fn {c, a, g}, {cs, as, gs} -> {cs ++ c, as ++ a, gs ++ g} end)

    other =
      if changed == [] and added == [] and gone == [],
        do: ["\nNo row changed: the prose or a stats line did.\n"],
        else: []

    IO.iodata_to_binary([
      "out of date.\n",
      section("Changed", changed),
      section("Added", added),
      section("Gone", gone),
      other
    ])
  end

  defp section(_title, []), do: []
  defp section(title, lines), do: ["\n#{title}:\n", Enum.map(lines, &"  #{&1}\n")]

  # One table's rows on each side, matched by key: what changed (naming the cells), what
  # appeared, what went.
  defp compare({heading, header}, old_rows, new_rows) do
    columns = key_columns(header, old_rows, new_rows)
    old_keyed = keyed(old_rows, columns)
    new_keyed = keyed(new_rows, columns)
    old_map = Map.new(old_keyed)
    new_map = Map.new(new_keyed)

    changed =
      for {key, cells} <- new_keyed,
          match?({:ok, was} when was != cells, Map.fetch(old_map, key)),
          do: "#{name(heading, key)} — #{cell_changes(header, old_map[key], cells)}"

    added = for {key, _} <- new_keyed, not Map.has_key?(old_map, key), do: name(heading, key)
    gone = for {key, _} <- old_keyed, not Map.has_key?(new_map, key), do: name(heading, key)
    {changed, added, gone}
  end

  # The columns that identify a row: `Item`, else the shortest leading run, that names every
  # row once on BOTH sides, so a row keeps its key across the edit being reported. `nil` when
  # none does (identical rows): the whole row is the key, with its occurrence.
  defp key_columns(header, old_rows, new_rows) do
    item = Enum.find_index(header, &(&1 == "Item"))
    leading = for n <- 1..max(length(header), 1), do: Enum.to_list(0..(n - 1))
    candidates = if item, do: [[item] | leading], else: leading

    Enum.find(candidates, fn columns ->
      unique?(old_rows, columns) and unique?(new_rows, columns)
    end)
  end

  defp unique?(rows, columns) do
    keys = Enum.map(rows, &pick(&1, columns))
    length(Enum.uniq(keys)) == length(keys)
  end

  defp pick(cells, columns), do: Enum.map(columns, &Enum.at(cells, &1))

  defp keyed(rows, nil) do
    rows
    |> Enum.map_reduce(%{}, fn cells, seen ->
      n = Map.get(seen, cells, 0)
      {{{cells, n}, cells}, Map.put(seen, cells, n + 1)}
    end)
    |> elem(0)
  end

  defp keyed(rows, columns), do: Enum.map(rows, &{{pick(&1, columns), 0}, &1})

  defp name(heading, {cells, n}) do
    text = cells |> Enum.map(&unquote_code(&1 || "")) |> Enum.join(" · ")
    text = if heading, do: "#{heading}: #{text}", else: text
    if n > 0, do: "#{text} (#{n + 1})", else: text
  end

  defp cell_changes(header, old_cells, new_cells) do
    width = max(length(old_cells), length(new_cells))

    0..(width - 1)
    |> Enum.map(
      &{Enum.at(header, &1) || "column #{&1 + 1}", Enum.at(old_cells, &1), Enum.at(new_cells, &1)}
    )
    |> Enum.reject(fn {_, was, now} -> was == now end)
    |> Enum.map_join("; ", fn {column, was, now} -> "#{column} #{text(was)} → #{text(now)}" end)
  end

  defp text(nil), do: "(none)"
  defp text(cell), do: unquote_code(cell)

  defp rows_of(tables, id), do: for({^id, cells} <- tables, do: cells)

  # Every table row as {{heading, header}, cells}, in order. A `##`-or-deeper heading names
  # the tables under it; a `#` title names none.
  defp tables(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], nil, nil}, fn line, {acc, heading, header} ->
      cells = if String.starts_with?(line, "|"), do: cells(line), else: nil

      cond do
        cells == nil -> {acc, heading_after(line, heading), nil}
        header == nil -> {acc, heading, cells}
        Enum.all?(cells, &(&1 =~ ~r/^:?-+:?$/)) -> {acc, heading, header}
        true -> {[{{heading, header}, cells} | acc], heading, header}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp heading_after(line, heading) do
    case Regex.run(~r/\A(#+) +(.*?) *\z/, line) do
      [_, "#", _] -> nil
      [_, _, text] -> text
      nil -> heading
    end
  end

  # A row's cells as GFM reads them: split on every `|` not escaped as `\|`, the outer
  # pipes dropped.
  defp cells(line) do
    [_lead | cells] = Regex.split(~r/(?<!\\)\|/, String.trim(line))
    cells = if List.last(cells) == "", do: Enum.drop(cells, -1), else: cells
    Enum.map(cells, &String.trim/1)
  end

  # A code span as `Surfex.Golden.code/1` writes it, read back to its text: the N-backtick
  # delimiters, the one-space padding and the `\|` escape undone.
  defp unquote_code(text) do
    case Regex.run(~r/\A(`+)(.*)\1\z/s, text) do
      [_, _fence, inner] -> inner |> unpad() |> String.replace("\\|", "|")
      nil -> text
    end
  end

  defp unpad(" " <> rest = inner) do
    if String.ends_with?(rest, " ") and String.trim(inner, " ") != "",
      do: String.slice(rest, 0..-2//1),
      else: inner
  end

  defp unpad(inner), do: inner
end
