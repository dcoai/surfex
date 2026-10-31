defmodule Surfex.Scan.Markdown.Table do
  @moduledoc false
  # Marked tables (§11): the table's unit and one per row, keyed by its key cells.

  import Surfex.Scan.Markdown.Lines, only: [fail: 3]

  alias Surfex.Golden.Span

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
    header = Span.cells(header_line)
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
      body: table_version(header, separator),
      within: table.within
    }

    {st, row_units} =
      Enum.reduce(rows, {st, []}, fn {row, no}, {st, units} ->
        row_cells = Span.cells(row)
        key_cells = for c <- keys, do: Enum.at(row_cells, c, "")
        parts = Enum.map(key_cells, &key_text/1)

        if "" in parts do
          {fail(st, no, "a row of table #{table.id} has an empty key"), units}
        else
          id = "#{table.id}/#{Enum.join(parts, "/")}"

          unit = %{
            role: :row,
            id: id,
            first: no,
            last: no,
            body: row_version(row, ignored),
            within: {:table, table.id},
            warnings: key_warnings(key_cells, no, id)
          }

          {st, [unit | units]}
        end
      end)

    %{st | units: row_units ++ [table_unit | st.units]}
  end

  defp column(header, name), do: Enum.find_index(header, &(key_text(&1) == key_text(name)))

  # What a row's key cells say that is probably a mistake (§11.12), each a warning on the
  # row; the row is keyed as written either way. A `/` outside code spans and not spaced
  # as ` / ` (a list, §11.2) makes the id read as a path one level deeper (`:slash_key`);
  # one inside a code span, `f/2` or `lib/`, is a name written as code. A key cell that is
  # a code span followed by prose probably means the span alone (`:span_key`).
  defp key_warnings(cells, no, id) do
    slash =
      for cell <- cells, slash?(cell) do
        %{
          kind: :slash_key,
          line: no,
          message:
            "row #{id}: its key #{inspect(key_text(cell))} holds a / outside a code span, " <>
              "so the id reads as a path one level deeper (TABLE/KEY still resolves it)"
        }
      end

    span =
      for cell <- cells, probable = spanned(cell) do
        %{
          kind: :span_key,
          line: no,
          message:
            "row #{id}: its key is a code span followed by prose; " <>
              "the span alone, #{inspect(probable)}, is probably the key"
        }
      end

    slash ++ span
  end

  defp slash?(cell) do
    text =
      Enum.map_join(Span.inline(cell), fn
        {:code, _} -> "x"
        {:text, t} -> t
      end)

    Regex.match?(~r{(?<! )/|/(?! )}, text)
  end

  # The span's text when the cell is a code span followed by prose, not by a list's
  # separator or another span; else nil.
  defp spanned(cell) do
    with [{:code, code}, {:text, text}] <- Span.inline(cell),
         rest = String.trim(text),
         true <- rest != "" and not Regex.match?(~r{\A(,|/|and\s)}, rest) do
      code |> String.split() |> Enum.join(" ")
    else
      _ -> nil
    end
  end

  # The versions of a table's units are kept as 0.10.0 released them (§23.3): a change to
  # what they cover re-versions every relation to them on an upgrade. Each is read from the
  # cells as written (`Span.written_cells/1`), untrimmed, so the whitespace around a pipe
  # stays a word break when `hash/1` collapses it.
  #
  # A table's version covers its header's cells, joined with nothing between them (the
  # pipes are not part of it), and its separator row.
  defp table_version(header, separator), do: [Enum.join(Span.written_cells(header)), separator]

  # A row's version covers its cells, less the columns `ignore:` names: then its kept cells
  # joined by `|`.
  defp row_version(row, []), do: [row]

  defp row_version(row, ignored) do
    kept = for {cell, c} <- Enum.with_index(Span.written_cells(row)), c not in ignored, do: cell
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

  # A key as a reader sees it (§11.15): code spans' text as written, backslash escapes
  # outside them undone, emphasis that CommonMark reads as emphasis dropped, whitespace
  # collapsed. `` `:normal` `` is `:normal`, `*Mode*` is `Mode`, `snake_case` is itself.
  defp key_text(cell) do
    tokens = cell |> Span.inline() |> Enum.flat_map(&tokens/1) |> List.to_tuple()

    tokens
    |> emphasis()
    |> Enum.map_join(fn
      {:delim, ch, n} -> String.duplicate(ch, n)
      {_, text} -> text
    end)
    |> String.split()
    |> Enum.join(" ")
  end

  # A cell's tokens: a code span is one token, a backslash escape of punctuation its
  # character, a run of `*` or `_` one delimiter run, anything else a character.
  defp tokens({:code, text}), do: [{:code, text}]
  defp tokens({:text, text}), do: text_tokens(text, [])

  defp text_tokens("", acc), do: Enum.reverse(acc)

  defp text_tokens(<<"\\", c, rest::binary>>, acc)
       when c in ~c"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
       do: text_tokens(rest, [{:escaped, <<c>>} | acc])

  defp text_tokens(<<ch, _::binary>> = text, acc) when ch in [?*, ?_] do
    [run] = Regex.run(~r/\A#{Regex.escape(<<ch>>)}+/, text)
    n = byte_size(run)
    text_tokens(binary_part(text, n, byte_size(text) - n), [{:delim, <<ch>>, n} | acc])
  end

  defp text_tokens(<<c::utf8, rest::binary>>, acc),
    do: text_tokens(rest, [{:char, <<c::utf8>>} | acc])

  # CommonMark's emphasis (its "process emphasis", bounded to `*` and `_`): each closing
  # run pairs with the nearest opener of its character before it, two delimiters at a time
  # where both have two, under the rule of 3; runs between a pair become literal; what is
  # left unpaired stays literal. The tokens come back with each run's unpaired count.
  defp emphasis(tokens) do
    runs =
      for i <- 0..(tuple_size(tokens) - 1)//1,
          {:delim, ch, n} <- [elem(tokens, i)],
          into: %{} do
        {open, close} = flanking(tokens, i, ch)
        {i, %{ch: ch, n: n, orig: n, open: open, close: close, active: true}}
      end

    order = runs |> Map.keys() |> Enum.sort()
    runs = Enum.reduce(order, runs, &close_run(&1, &2, order))

    for i <- 0..(tuple_size(tokens) - 1)//1 do
      case elem(tokens, i) do
        {:delim, ch, _} -> {:delim, ch, runs[i].n}
        token -> token
      end
    end
  end

  defp close_run(c, runs, order) do
    closer = runs[c]

    if closer.active and closer.close and closer.n > 0 do
      opener =
        order
        |> Enum.filter(&(&1 < c))
        |> Enum.reverse()
        |> Enum.find(fn o ->
          r = runs[o]
          r.active and r.open and r.n > 0 and r.ch == closer.ch and rule_of_3?(r, closer)
        end)

      case opener do
        nil ->
          if closer.open, do: runs, else: Map.update!(runs, c, &%{&1 | active: false})

        o ->
          k = if runs[o].n >= 2 and closer.n >= 2, do: 2, else: 1

          runs =
            order
            |> Enum.filter(&(&1 > o and &1 < c))
            |> Enum.reduce(runs, fn between, acc ->
              Map.update!(acc, between, &%{&1 | active: false})
            end)
            |> Map.update!(o, &%{&1 | n: &1.n - k, active: &1.n - k > 0})
            |> Map.update!(c, &%{&1 | n: &1.n - k})

          close_run(c, runs, order)
      end
    else
      runs
    end
  end

  # When either run can both open and close, the pair's lengths must not sum to a multiple
  # of 3 unless both are multiples of 3.
  defp rule_of_3?(opener, closer) do
    sum = opener.orig + closer.orig

    not ((opener.open and opener.close) or (closer.open and closer.close)) or
      rem(sum, 3) != 0 or (rem(opener.orig, 3) == 0 and rem(closer.orig, 3) == 0)
  end

  # Whether the run at `i` can open and close: left- and right-flanking by the characters
  # around it in the source (a code span's are its backticks, an escape's its backslash and
  # character; the cell's ends count as whitespace), and for `_`, not inside a word.
  defp flanking(tokens, i, ch) do
    before = if i == 0, do: " ", else: tokens |> elem(i - 1) |> edge(:right)
    next = if i == tuple_size(tokens) - 1, do: " ", else: tokens |> elem(i + 1) |> edge(:left)
    left = not space?(next) and (not punct?(next) or space?(before) or punct?(before))
    right = not space?(before) and (not punct?(before) or space?(next) or punct?(next))

    case ch do
      "*" -> {left, right}
      "_" -> {left and (not right or punct?(before)), right and (not left or punct?(next))}
    end
  end

  defp edge({:code, _}, _side), do: "`"
  defp edge({:escaped, _}, :left), do: "\\"
  defp edge({:escaped, c}, :right), do: c
  defp edge({:char, c}, _side), do: c
  defp edge({:delim, ch, _}, _side), do: ch

  defp space?(c), do: Regex.match?(~r/\A\s\z/u, c)
  defp punct?(c), do: Regex.match?(~r/\A[\p{P}\p{S}]\z/u, c)
end
