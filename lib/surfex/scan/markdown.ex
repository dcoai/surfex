defmodule Surfex.Scan.Markdown do
  @moduledoc """
  The spec scanner for markdown: one `Surfex.Scan` record per section, per marked block,
  and per test hint.

  A **section** is a heading and the lines under it, up to the next heading of any level.
  Its subsections are sections of their own, so an edit to §3.2 changes §3.2's version and
  not §3's. Text before the first heading is the section `(preamble)`, when it has any.

    * **id** — the one its author wrote, when there is one: an id comment on the line
      after the heading or at its end (`## Adding items <!-- surfex: cart-add -->`), an
      anchor (`{#cart-add}`), or what the project's heading grammars read (`heading_ids:`,
      `heading_grammar/1`), giving
      `spec.md#cart-add`. A written id survives renaming the heading or any heading above
      it. Otherwise the file and the path of headings down to it,
      `spec.md#Carts/Adding items`; two sections with the same path in one file are told
      apart by a suffix, `~2`, `~3`, in order.
    * **hash** — over the section's own body, **not its heading** (nor its anchor), with
      runs of whitespace collapsed. Rewording the body changes it; renaming the heading,
      reflowing a paragraph or adding blank lines doesn't. A renamed heading keeps its
      version under a new id, which is what lets a tool recognise the move.
    * **location** — the file, from the heading's line to the section's last line.

  Finer units sit inside sections, each a record of its own with its own version, and
  each left out of the version of what it sits in, so editing one changes only its own:

    * A **marked block** is a requirement: the lines between `<!-- surfex: ID -->` and
      `<!-- /surfex -->`, each marker on a line of its own. Its id is `file#ID`. A block
      can't nest in another or span a heading, and one left open is an error.
    * A **test hint** says how to test something: a fenced block whose info string is
      exactly `test:ID` or `test ID`. Its id is `file#ID` and its version covers the
      fence's content. ex_doc renders only the first (§11).
      A `test` fence without an id is an ordinary code block.
    * A **marked table** (`<!-- surfex: table ID -->` before a table) is a unit, and so is
      each of its rows, `file#ID/KEY`. The marker may name the key column, or several
      (`key: [Function, Key]`, joined by `/`), and columns left out of a row's version
      (`ignore: [Measured]`).

  Written ids and block, hint and table ids share one namespace per file with the section
  ids: letters, digits and `. _ - :`, starting with a letter or digit. A duplicate is an
  error naming both lines. Every error raises
  `ArgumentError` naming the file and line: a spec that can't be read as written must not
  scan as something else.

  A line inside a fenced code block is never a heading or a marker; the block is part of
  the body. Fences follow CommonMark: backticks or tildes, closed only by the same
  character at least as many times, so a longer fence can quote a shorter one.
  """

  alias Surfex.Scan
  alias Surfex.Scan.Markdown.Fence

  @id "[A-Za-z0-9][A-Za-z0-9._:-]*"
  @anchor ~r/^(.*?)\s*\{#([^}\s]*)\}$/
  @heading_comment ~r/^(.*?)\s*<!--\s*surfex:\s*(\S+)\s*-->$/
  @open_block ~r/^ {0,3}<!--\s*surfex:\s*(\S+)\s*-->\s*$/
  @close_block ~r/^ {0,3}<!--\s*\/surfex\s*-->\s*$/
  @hint ~r/^test(?:\s+|:)(\S+)$/
  @table_marker ~r/^ {0,3}<!--\s*surfex:\s*table\s+(\S+)(.*?)\s*-->\s*$/
  @table_line ~r/^ {0,3}\|/
  @separator ~r/^ {0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

  @doc """
  Every unit of every markdown file of the spec under `root`, in order: the files
  `globs` match, less those under an `exclude` prefix (`files/3`).
  """
  @spec records(String.t(), [String.t()], [String.t()], keyword) :: [Scan.t()]
  def records(root, globs, exclude \\ [], opts \\ []) do
    root
    |> files(globs, exclude)
    |> Enum.flat_map(fn file ->
      root |> Path.join(file) |> File.read!() |> sections(file, opts)
    end)
  end

  @doc """
  The spec's files, relative to `root`, in a stable order: those `globs` match, less any
  whose path starts with an `exclude` prefix. The one answer to which files are the spec,
  for its sections and its citations alike (§8).
  """
  @spec files(String.t(), [String.t()], [String.t()]) :: [String.t()]
  def files(root, globs, exclude) do
    root = Path.expand(root)

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(fn p -> Enum.any?(exclude, &String.starts_with?(p, &1)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The units of one markdown text (sections, marked blocks and test hints), as records
  located in `file`, in the order they start. `heading_ids:` names the project's heading
  grammar (`heading_grammar/1`).
  """
  @spec sections(String.t(), String.t(), keyword) :: [Scan.t()]
  def sections(text, file, opts \\ []) do
    grammar = heading_grammars(Keyword.get(opts, :heading_ids))

    lines = text |> String.split("\n") |> Enum.with_index(1)
    {sections, units} = split(lines, file, grammar, ids_after(lines))

    sections =
      sections
      |> Enum.reject(fn s ->
        s.heading == nil and blank?(s.body) and
          not Enum.any?(units, &(&1.within == {:section, s.n}))
      end)
      |> number_duplicates()
      |> Enum.map(&Map.put(&1, :id, "#{file}##{&1.anchor || &1.path}"))

    ids = Map.new(sections, &{&1.n, &1.id})
    unique!(sections, units, file)

    section_records =
      for s <- sections,
          do: %{
            record(file, s.id, s.body, {s.first, s.last}, :section, nil)
            | named: s.anchor != nil
          }

    unit_records =
      for u <- units do
        within =
          case u.within do
            {:section, n} -> Map.fetch!(ids, n)
            {:block, id} -> "#{file}##{id}"
            {:table, id} -> "#{file}##{id}"
          end

        record(file, "#{file}##{u.id}", u.body, {u.first, u.last}, u.role, within)
      end

    Enum.sort_by(section_records ++ unit_records, &elem(&1.location.lines, 0))
  end

  defp record(file, id, body, lines, role, within),
    do: %Scan{
      kind: :spec,
      id: id,
      hash: hash(body),
      location: %{file: file, lines: lines},
      role: role,
      within: within
    }

  # ── Reading ─────────────────────────────────────────────────────────────

  # Sections in order (%{n, heading, anchor, path, first, last, body}), and the blocks and
  # hints (%{role, id, first, last, body, within}). A line belongs to exactly one body:
  # the open hint's, else the open block's, else the current section's. Markers and a
  # hint's fences belong to none.
  defp split(lines, file, grammar, ids_after) do
    start = %{
      file: file,
      grammar: grammar,
      ids_after: ids_after,
      done: [],
      cur: section(0, nil, nil, "(preamble)", 1),
      stack: [],
      fence: nil,
      block: nil,
      hint: nil,
      table: nil,
      units: []
    }

    st = Enum.reduce(lines, start, &step/2)

    st =
      cond do
        st.table == nil ->
          st

        st.table.lines == [] ->
          fail(st, st.table.first, "table #{st.table.id} has no table after its marker")

        true ->
          close_table(st)
      end

    if st.hint, do: fail(st, st.hint.first, "test hint #{st.hint.id} is never closed")
    if st.block, do: fail(st, st.block.first, "block #{st.block.id} is never closed")

    sections =
      [st.cur | st.done]
      |> Enum.reverse()
      |> Enum.map(&%{&1 | body: Enum.reverse(&1.body)})

    {sections, Enum.reverse(st.units)}
  end

  defp section(n, heading, anchor, path, first),
    do: %{n: n, heading: heading, anchor: anchor, path: path, first: first, last: first, body: []}

  # Inside a test hint: every line is its content until its fence closes.
  defp step({line, no}, %{hint: hint} = st) when hint != nil do
    {_prose?, fence} = Fence.step(line, st.fence)
    st = %{st | fence: fence, cur: extend(st.cur, line, no)}

    if fence == nil,
      do: %{st | hint: nil, units: [unit(hint, :test_hint, no) | st.units]},
      else: %{st | hint: %{hint | body: [line | hint.body]}}
  end

  defp step(line, %{table: table} = st) when table != nil, do: table_step(line, st)

  defp step({line, no}, st) do
    {prose?, fence} = Fence.step(line, st.fence)
    opened? = st.fence == nil and fence != nil

    cond do
      opened? and hint_id(line) != nil ->
        id = checked_id!(st, no, hint_id(line), "test hint")
        hint = %{id: id, first: no, body: [], within: within(st)}
        %{st | fence: fence, hint: hint, cur: extend(st.cur, line, no)}

      # A heading's id comment on the line after it belongs to no body, like a marker.
      prose? and Map.has_key?(st.ids_after, no - 1) ->
        %{st | cur: extend(st.cur, line, no)}

      prose? and heading(line) != nil ->
        if st.block,
          do: fail(st, no, "block #{st.block.id} (line #{st.block.first}) spans a heading")

        new_section(st, heading(line), no)

      prose? and Regex.match?(@table_marker, line) ->
        [id, options] = Regex.run(@table_marker, line, capture: :all_but_first)
        id = checked_id!(st, no, id, "table")
        options = table_options(st, no, id, options)

        table = %{
          id: id,
          key: options[:key],
          ignore: Map.get(options, :ignore, []),
          first: no,
          lines: [],
          within: within(st)
        }

        %{st | table: table, cur: extend(st.cur, line, no)}

      prose? and Regex.match?(@open_block, line) ->
        [id] = Regex.run(@open_block, line, capture: :all_but_first)
        id = checked_id!(st, no, id, "block")

        if st.block,
          do:
            fail(st, no, "block #{id} opens inside block #{st.block.id} (line #{st.block.first})")

        block = %{id: id, first: no, body: [], within: within(st)}
        %{st | block: block, cur: extend(st.cur, line, no)}

      prose? and Regex.match?(@close_block, line) ->
        unless st.block, do: fail(st, no, "<!-- /surfex --> closes no block")

        %{
          st
          | block: nil,
            units: [unit(st.block, :block, no) | st.units],
            cur: extend(st.cur, line, no)
        }

      st.block != nil ->
        %{
          st
          | fence: fence,
            block: %{st.block | body: [line | st.block.body]},
            cur: extend(st.cur, line, no)
        }

      true ->
        cur = extend(st.cur, line, no)
        %{st | fence: fence, cur: %{cur | body: [line | cur.body]}}
    end
  end

  defp new_section(st, {level, text}, no) do
    # An id the author wrote wins: a comment at the end of the heading or on the line after
    # it, or a {#anchor}. Then the project's heading grammar (heading_ids:). Neither: the
    # heading path.
    {text, explicit} = explicit_id(st, text, no)
    after_id = Map.get(st.ids_after, no)

    if explicit && after_id,
      do: fail(st, no + 1, "heading of line #{no} already has a written id, #{explicit}")

    written = explicit || (after_id && checked_id!(st, no + 1, after_id, "heading"))
    anchor = written || grammar_id(st, text, no)

    stack = [{level, text} | Enum.drop_while(st.stack, fn {l, _} -> l >= level end)]
    path = stack |> Enum.reverse() |> Enum.map_join("/", &elem(&1, 1))
    next = section(st.cur.n + 1, text, anchor, path, no)
    %{st | done: [st.cur | st.done], cur: next, stack: stack}
  end

  # The headings whose id comment is on the line after them, as %{heading line => id}. That
  # line is also a block's opening marker, so it is the heading's id only when no close
  # marker makes it a block: when the next marker, heading or the end of the text comes
  # first. Read so, it is a block exactly where it was before, and an id only where it was
  # an error (a block left open, spanning a heading or opening inside itself).
  defp ids_after(lines) do
    start = %{fence: nil, heading: nil, pending: nil, ids: %{}}

    st =
      Enum.reduce(lines, start, fn {line, no}, st ->
        {prose?, fence} = Fence.step(line, st.fence)
        st = %{st | fence: fence}

        cond do
          not prose? ->
            %{st | heading: nil}

          heading(line) != nil ->
            %{after_marker(st, :id) | heading: no}

          st.heading == no - 1 and Regex.match?(@open_block, line) ->
            [id] = Regex.run(@open_block, line, capture: :all_but_first)
            %{st | heading: nil, pending: {no - 1, id}}

          Regex.match?(@open_block, line) ->
            %{after_marker(st, :id) | heading: nil}

          Regex.match?(@close_block, line) ->
            %{after_marker(st, :block) | heading: nil}

          true ->
            %{st | heading: nil}
        end
      end)

    after_marker(st, :id).ids
  end

  defp after_marker(%{pending: nil} = st, _read), do: st
  defp after_marker(st, :block), do: %{st | pending: nil}

  defp after_marker(%{pending: {heading, id}} = st, :id),
    do: %{st | pending: nil, ids: Map.put(st.ids, heading, id)}

  defp explicit_id(st, text, no) do
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
  defp grammar_id(%{grammar: grammars} = st, text, no) do
    Enum.find_value(grammars, fn grammar ->
      case Regex.named_captures(grammar, text) do
        %{"id" => id} -> checked_id!(st, no, id, "heading")
        nil -> nil
      end
    end)
  end

  # `heading_ids:` is one grammar or a list of them, tried in order.
  defp heading_grammars(nil), do: []
  defp heading_grammars(list) when is_list(list), do: Enum.map(list, &heading_grammar!/1)
  defp heading_grammars(one), do: [heading_grammar!(one)]

  defp heading_grammar!(grammar),
    do: heading_grammar(grammar) || raise(ArgumentError, "heading_ids: a list can't hold nil")

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

  # ── Tables ──────────────────────────────────────────────────────────────

  # Inside a marked table: its lines are its own, until the first line that isn't one.
  # Blank lines may sit between the marker and the table; nothing else may.
  defp table_step({line, no}, st) do
    table = st.table

    cond do
      Regex.match?(@table_line, line) ->
        %{st | table: %{table | lines: [{line, no} | table.lines]}, cur: extend(st.cur, line, no)}

      table.lines == [] and String.trim(line) == "" ->
        st

      table.lines == [] ->
        fail(st, table.first, "table #{table.id} has no table after its marker")

      true ->
        step({line, no}, close_table(st))
    end
  end

  # The table's unit (its header and separator) and one unit per row, keyed by its key cell.
  defp close_table(%{table: table} = st) do
    lines = Enum.reverse(table.lines)

    case lines do
      [{header, _}, {separator, sep_no} | rows] ->
        unless Regex.match?(@separator, separator),
          do: fail(st, sep_no, "table #{table.id} has no separator row under its header")

        header = cells(header)
        keys = if table.key, do: Enum.map(table.key, &column!(st, table, header, &1)), else: [0]
        ignored = Enum.map(table.ignore, &column!(st, table, header, &1))

        for {name, c} <- Enum.zip(table.ignore, ignored),
            c in keys,
            do:
              fail(
                st,
                table.first,
                "table #{table.id} can't ignore its key column #{inspect(name)}"
              )

        {_, last} = List.last(lines)

        table_unit = %{
          role: :table,
          id: table.id,
          first: table.first,
          last: last,
          body: [header, separator],
          within: table.within
        }

        row_units =
          for {row, no} <- rows do
            row_cells = cells(row)
            parts = for c <- keys, do: row_cells |> Enum.at(c, "") |> key_text()
            if "" in parts, do: fail(st, no, "a row of table #{table.id} has an empty key")

            %{
              role: :row,
              id: "#{table.id}/#{Enum.join(parts, "/")}",
              first: no,
              last: no,
              body: row_version(row, row_cells, ignored),
              within: {:table, table.id}
            }
          end

        %{st | table: nil, units: Enum.reverse(row_units) ++ [table_unit | st.units]}

      _ ->
        fail(st, table.first, "table #{table.id} has no separator row under its header")
    end
  end

  defp column!(st, table, header, name) do
    Enum.find_index(header, &(key_text(&1) == key_text(name))) ||
      fail(st, table.first, "table #{table.id} has no column #{inspect(name)}")
  end

  # A row's version covers its cells, less the columns `ignore:` names.
  defp row_version(row, _cells, []), do: [row]

  defp row_version(_row, cells, ignored) do
    kept = for {cell, c} <- Enum.with_index(cells), c not in ignored, do: cell
    [Enum.join(kept, "|")]
  end

  # A marker's text after its id: `key:` and `ignore:`, in either order, each a column
  # header or a bracketed list of them. Anything else is an error, never silently body.
  defp table_options(st, no, id, text) do
    text
    |> String.trim()
    |> case do
      "" -> []
      text -> Regex.split(~r/\s+(?=(?:key|ignore):)/, text)
    end
    |> Enum.reduce(%{}, fn option, acc ->
      case Regex.run(~r/^(key|ignore):\s*(\S.*)$/, option, capture: :all_but_first) do
        [name, value] ->
          name = Map.fetch!(%{"key" => :key, "ignore" => :ignore}, name)

          if Map.has_key?(acc, name),
            do: fail(st, no, "table #{id}'s marker gives #{name}: twice")

          Map.put(acc, name, columns(value))

        nil ->
          fail(
            st,
            no,
            "table #{id}'s marker has text that isn't key: or ignore: (#{inspect(option)})"
          )
      end
    end)
  end

  defp columns(value) do
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

  # What a block or hint opened now sits in.
  defp within(%{block: %{id: id}}), do: {:block, id}
  defp within(%{cur: %{n: n}}), do: {:section, n}

  defp unit(open, role, last),
    do: %{
      role: role,
      id: open.id,
      first: open.first,
      last: last,
      body: Enum.reverse(open.body),
      within: open.within
    }

  # A section's last line is its last non-blank line, so trailing blank lines before the
  # next heading are not counted as its content.
  defp extend(cur, line, no), do: if(String.trim(line) == "", do: cur, else: %{cur | last: no})

  defp hint_id(line) do
    with info when is_binary(info) <- Fence.info(line),
         [id] <- Regex.run(@hint, info, capture: :all_but_first),
         do: id,
         else: (_ -> nil)
  end

  defp checked_id!(st, no, id, what) do
    if Regex.match?(~r/^#{@id}$/, id),
      do: id,
      else:
        fail(
          st,
          no,
          "#{what} id #{inspect(id)} must be letters, digits and . _ - :, starting with a letter or digit"
        )
  end

  defp heading(line) do
    case Regex.run(~r/^(#+)\s+(.+?)\s*#*\s*$/, line, capture: :all_but_first) do
      [hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  defp blank?(body), do: Enum.all?(body, &(String.trim(&1) == ""))

  # Only heading paths are numbered: an anchored section is named by its anchor.
  defp number_duplicates(sections) do
    {numbered, _seen} =
      Enum.map_reduce(sections, %{}, fn
        %{anchor: nil} = s, seen ->
          n = Map.get(seen, s.path, 0) + 1
          path = if n == 1, do: s.path, else: "#{s.path}~#{n}"
          {%{s | path: path}, Map.put(seen, s.path, n)}

        s, seen ->
          {s, seen}
      end)

    numbered
  end

  defp unique!(sections, units, file) do
    named =
      Enum.map(sections, &{&1.id, &1.first}) ++ Enum.map(units, &{"#{file}##{&1.id}", &1.first})

    named
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find(fn {_id, lines} -> length(lines) > 1 end)
    |> case do
      nil ->
        :ok

      {id, [first, second | _]} ->
        raise ArgumentError, "#{file}:#{second}: #{id} is already the id of line #{first}"
    end
  end

  defp fail(st, no, why), do: raise(ArgumentError, "#{st.file}:#{no}: #{why}")

  @doc """
  Whether a spec unit has no text of its own: a heading over subsections, whose version is
  that of an empty body. Such a unit carries no claims (§20).
  """
  @spec empty?(Surfex.Scan.t()) :: boolean
  def empty?(%Surfex.Scan{kind: :spec, hash: hash}), do: hash == hash([])

  # Whitespace carries no meaning in prose: collapse it, so reflowing a paragraph or adding
  # blank lines is not a change.
  defp hash(body) do
    body
    |> Enum.join("\n")
    |> String.split()
    |> Enum.join(" ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
