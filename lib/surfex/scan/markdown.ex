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
    * A **rule** is one claim, role `:rule`: a list item or paragraph its author named. An
      id comment on its own line directly before a paragraph or list item names it, as does
      one that starts the item or paragraph (`- <!-- surfex: ID --> text`). A marked list
      (`<!-- surfex: rules NAME -->` before it) makes every top-level item a rule, its id
      its id comment or what the project's `rule_ids:` grammar reads from the item's text.
      A rule's version is its text and nested lines, without its list marker or id comment,
      so renumbering a list changes none. Bold is never read as a claim.

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
  alias Surfex.Scan.Markdown.{ClassMarkers, Contract, Fence, Fold, Ids, Table}

  import Surfex.Scan.Markdown.Lines
  import Surfex.Scan.Markdown.Ids, only: [explicit_id: 3, grammar_id: 3, read_id: 5]

  import Surfex.Scan.Markdown.ClassMarkers,
    only: [class_line: 3, class_unit: 3, section_class: 3, marked: 1, own_marker?: 2]

  import Surfex.Scan.Markdown.Rules

  @open_block ~r/^ {0,3}<!--\s*surfex:\s*(\S+)\s*-->\s*$/
  @close_block ~r/^ {0,3}<!--\s*\/surfex\s*-->\s*$/
  @table_marker ~r/^ {0,3}<!--\s*surfex:\s*table\s+(\S+)(.*?)\s*-->\s*$/
  @table_line ~r/^ {0,3}\|/
  @rules_marker ~r/^ {0,3}<!--\s*surfex:\s*rules\s+(\S+)\s*-->\s*$/

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
    |> cited(Keyword.get(opts, :unit_refs, []))
  end

  # Each deferral that cites a spec unit (§13.13), resolved against the whole spec with the
  # project's `unit_refs:`: its `cites` is the unit's full id. One that names no unit, or
  # several, raises naming its file and line, as a malformed marker does.
  defp cited(scans, unit_refs) do
    if Enum.any?(scans, &cites?/1) do
      resolver = Scan.resolver(scans, unit_refs)

      for scan <- scans do
        if cites?(scan),
          do: %{scan | deferred: %{scan.deferred | cites: cite!(resolver, scan)}},
          else: scan
      end
    else
      scans
    end
  end

  defp cites?(%Scan{deferred: %{cites: nil}}), do: true
  defp cites?(_scan), do: false

  defp cite!(resolver, %Scan{deferred: %{ref: ref, line: line}, location: %{file: file}}) do
    case Scan.resolve(resolver, ref) do
      {:ok, unit} ->
        unit.id

      {:error, :unknown} ->
        raise ArgumentError,
              "#{file}:#{line}: the deferral cites #{inspect(ref)}, which is no spec unit: " <>
                "a deferral names an issue (#123) or a spec unit the spec's sources scan"

      {:error, {:ambiguous, ids}} ->
        raise ArgumentError,
              "#{file}:#{line}: the deferral cites #{inspect(ref)}, which names several spec " <>
                "units (#{Enum.join(ids, ", ")}): cite one by its full id"
    end
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
  The units of one markdown text (sections, marked blocks, test hints, tables, rows and
  rules), as records located in `file`, in the order they start. `heading_ids:` names the
  project's heading grammar (`heading_grammar/1`), and `rule_ids:` the grammar a marked
  list's items are read by, in the same forms. With `fold_paths: true`, a heading with no
  id inside one that has an id is part of that unit. `subjects:` (the profile's, §6.6) says
  which module a contract fence in a subject section is about. `not_claims:` (regexes, §13.12)
  names the lines of a section's or marked block's own text that aren't claims: each unit
  records the lines each pattern matched and whether any own text is left (`not_claims`,
  `claimless?/1`), and its version still covers every line.
  """
  @spec sections(String.t(), String.t(), keyword) :: [Scan.t()]
  def sections(text, file, opts \\ []) do
    grammar = Ids.heading_grammars(Keyword.get(opts, :heading_ids), :heading_ids)
    rule_grammar = Ids.heading_grammars(Keyword.get(opts, :rule_ids), :rule_ids)

    lines = text |> String.split("\n") |> Enum.with_index(1)
    subjects = Keyword.get(opts, :subjects, [])
    classes = Keyword.get(opts, :spec_classes, [])
    patterns = not_claims!(Keyword.get(opts, :not_claims, []))

    {sections, units} =
      split(lines, file, {grammar, rule_grammar, subjects, classes}, unclosed(lines))

    {sections, owners} =
      if Keyword.get(opts, :fold_paths, false) == true,
        do: Fold.fold(sections, file),
        else: {sections, %{}}

    sections =
      sections
      |> Enum.reject(fn s ->
        s.heading == nil and blank?(s.body) and
          not Enum.any?(units, &(&1.within == {:section, s.n}))
      end)
      |> number_duplicates()
      |> Enum.map(&Map.put(&1, :id, "#{file}##{&1.anchor || &1.path}"))

    ids = Map.new(sections, &{&1.n, &1.id})
    ids = Map.merge(ids, Map.new(owners, fn {n, owner} -> {n, Map.fetch!(ids, owner)} end))
    unique!(sections, units, file)

    # A section sits under the section of the nearest heading above it at a higher level
    # (§13.4); one under a folded heading sits under its owner.
    section_records =
      for s <- sections,
          do: %{
            record(file, s.id, s.body, {s.first, s.last}, :section, nil)
            | named: s.anchor != nil,
              under: Map.get(s, :parent) && Map.fetch!(ids, s.parent),
              class: section_class(s, classes, file),
              deferred: marked(s.deferred),
              not_claims: not_claims(s.body, patterns)
          }

    unit_records =
      for u <- units do
        within =
          case u.within do
            {:section, n} -> Map.fetch!(ids, n)
            {:block, id} -> "#{file}##{id}"
            {:table, id} -> "#{file}##{id}"
            {:rule, id} -> "#{file}##{id}"
          end

        %{
          record(file, "#{file}##{u.id}", u.body, {u.first, u.last}, u.role, within)
          | contract: Map.get(u, :contract),
            deferred: marked(Map.get(u, :deferred)),
            not_claims: if(u.role == :block, do: not_claims(u.body, patterns))
        }
      end

    Enum.sort_by(section_records ++ unit_records, &elem(&1.location.lines, 0))
  end

  # The lines of a unit's own text that a `not_claims:` pattern matches (§13.12): each
  # non-blank line is matched as written against the patterns in order, and the first that
  # matches takes it. `nil` when none matches; otherwise the lines each pattern took
  # (by its `inspect/1` form) and whether any own text is left.
  defp not_claims(_body, []), do: nil

  defp not_claims(body, patterns) do
    {taken, rest} =
      body
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> {line, Enum.find(patterns, &Regex.match?(&1, line))} end)
      |> Enum.split_with(fn {_line, pattern} -> pattern != nil end)

    if taken == [],
      do: nil,
      else: %{
        lines: Enum.frequencies_by(taken, fn {_line, pattern} -> inspect(pattern) end),
        own_text: rest != []
      }
  end

  defp not_claims!(patterns) when is_list(patterns) do
    Enum.each(patterns, fn
      %Regex{} ->
        :ok

      other ->
        raise ArgumentError, "not_claims: must be a list of regexes, got #{inspect(other)}"
    end)

    patterns
  end

  defp not_claims!(other),
    do: raise(ArgumentError, "not_claims: must be a list of regexes, got #{inspect(other)}")

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
  # the open hint's, else the open rule's, else the open block's, else the current
  # section's. Markers and a hint's fences belong to none.
  defp split(lines, file, {grammar, rule_grammar, subjects, classes}, unclosed) do
    start = %{
      file: file,
      grammar: grammar,
      rule_grammar: rule_grammar,
      subjects: subjects,
      classes: classes,
      contract: nil,
      unclosed: unclosed,
      done: [],
      cur: section(0, nil, nil, "(preamble)", 1),
      stack: [],
      fence: nil,
      block: nil,
      hint: nil,
      table: nil,
      rule: nil,
      rules: nil,
      pending: nil,
      after_text: false,
      units: []
    }

    st =
      Enum.reduce(lines, start, fn {line, _no} = numbered, st ->
        fence = st.fence
        st = step(numbered, st)
        %{st | after_text: text_line?(st, line, fence, st.fence)}
      end)

    if st.pending, do: names_nothing(st, st.pending)

    st = if st.rule, do: close_rule(st), else: st

    st =
      case st.contract do
        nil -> st
        %{open: true} -> close_contract(st)
        marker -> fail(st, marker.first, "the contract marker has no fence after it")
      end

    if st.rules && st.rules.kind == nil,
      do: fail(st, st.rules.first, "rules #{st.rules.name} has no list after its marker")

    st =
      cond do
        st.table == nil ->
          st

        st.table.lines == [] ->
          fail(st, st.table.first, "table #{st.table.id} has no table after its marker")

        true ->
          Table.close_table(st)
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
    do: %{
      n: n,
      heading: heading,
      anchor: anchor,
      path: path,
      first: first,
      last: first,
      body: [],
      class: nil,
      deferred: nil
    }

  # The line after an id comment of its own: the paragraph or list item it names.
  defp step({line, no}, %{pending: {_marker, id, _why} = pending} = st) when pending != nil do
    st = %{st | pending: nil}

    cond do
      Fence.info(line) != nil or own_marker?(line) or heading(line) != nil ->
        names_nothing(st, pending)

      item = list_item(line) ->
        if lead(item.text), do: fail(st, no, "the list item has two ids, #{id} and its own")
        open_rule(st, id, item, no)

      String.trim(line) != "" and not Regex.match?(@table_line, line) ->
        open_rule(st, id, %{indent: nil, content: nil, text: line}, no)

      true ->
        names_nothing(st, pending)
    end
  end

  # Inside a test hint: every line is its content until its fence closes.
  defp step({line, no}, %{hint: hint} = st) when hint != nil do
    {_prose?, fence} = Fence.step(line, st.fence)
    st = %{st | fence: fence, cur: extend(st.cur, line, no)}

    if fence == nil,
      do: %{st | hint: nil, units: [unit(hint, :test_hint, no) | st.units]},
      else: %{st | hint: %{hint | body: [line | hint.body]}}
  end

  defp step(line, %{table: table} = st) when table != nil, do: table_step(line, st)

  # Inside a contract fence: its lines are its own until it closes.
  defp step({line, no}, %{contract: %{open: true} = contract} = st) do
    {_prose?, fence} = Fence.step(line, st.fence)
    st = %{st | fence: fence, cur: extend(st.cur, line, no)}

    if fence == nil,
      do: close_contract(%{st | contract: %{contract | close: line}}),
      else: %{st | contract: %{contract | lines: [{line, no} | contract.lines]}}
  end

  defp step({line, no}, %{rule: rule} = st) when rule != nil do
    if st.fence == nil and rule_ends?(st, rule, line),
      do: step({line, no}, close_rule(st)),
      else: rule_line(st, line, no)
  end

  defp step({line, no}, st) do
    {prose?, fence} = Fence.step(line, st.fence)
    opened? = st.fence == nil and fence != nil
    classing = if prose?, do: class_line(st, line, no)

    cond do
      # A contract marker's fence: blank lines may come between, nothing else.
      st.contract != nil ->
        cond do
          opened? -> open_contract(%{st | fence: fence}, line, no)
          String.trim(line) == "" -> st
          true -> fail(st, st.contract.first, "the contract marker has no fence after it")
        end

      prose? and contract_marker(st, line, no) != :none ->
        contract = %{module: contract_marker(st, line, no), first: no, within: within(st)}
        %{st | contract: contract, cur: extend(st.cur, line, no)}

      opened? and Contract.info?(Fence.info(line)) ->
        contract = %{module: nil, first: no, within: within(st)}
        open_contract(%{st | fence: fence, contract: contract}, line, no)

      opened? and hint_id(line) != nil ->
        id = checked_id!(st, no, hint_id(line), "test hint")
        hint = %{id: id, first: no, body: [], within: within(st)}
        %{st | fence: fence, hint: hint, cur: extend(st.cur, line, no)}

      # A heading's id comment on the line after it belongs to no body, like a marker.
      prose? and Map.has_key?(st.unclosed, no) and st.cur.heading != nil and
          st.cur.first == no - 1 ->
        %{st | cur: extend(st.cur, line, no)}

      # Any other id comment of its own names the paragraph or list item after it.
      prose? and Map.has_key?(st.unclosed, no) ->
        {id, why} = Map.fetch!(st.unclosed, no)
        id = checked_id!(st, no, id, "rule")
        %{st | pending: {no, id, why}, cur: extend(st.cur, line, no)}

      # A marked list: its items are rules, until something that isn't one of them.
      prose? and st.rules != nil ->
        rules_step({line, no}, st)

      prose? and Regex.match?(@rules_marker, line) ->
        [name] = Regex.run(@rules_marker, line, capture: :all_but_first)
        name = checked_id!(st, no, name, "rules")
        %{st | rules: %{name: name, first: no, kind: nil}, cur: extend(st.cur, line, no)}

      prose? and item_lead(line) != nil ->
        {item, id} = item_lead(line)
        open_rule(st, checked_id!(st, no, id, "rule"), item, no)

      prose? and not st.after_text and list_item(line) == nil and paragraph_lead(line) != nil ->
        id = checked_id!(st, no, paragraph_lead(line), "rule")
        open_rule(st, id, %{indent: nil, content: nil, text: line}, no)

      classing != nil ->
        class_unit(%{st | cur: extend(st.cur, line, no)}, classing, no)

      prose? and heading(line) != nil ->
        if st.block,
          do: fail(st, no, "block #{st.block.id} (line #{st.block.first}) spans a heading")

        new_section(st, heading(line), no)

      prose? and Regex.match?(@table_marker, line) ->
        [id, options] = Regex.run(@table_marker, line, capture: :all_but_first)
        id = checked_id!(st, no, id, "table")
        options = Table.table_options(st, no, id, options)

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

        block = %{id: id, first: no, body: [], within: within(st), deferred: nil}
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
    after_id = with {id, _why} when id != "contract" <- Map.get(st.unclosed, no + 1), do: id

    if explicit && after_id,
      do: fail(st, no + 1, "heading of line #{no} already has a written id, #{explicit}")

    written = explicit || (after_id && checked_id!(st, no + 1, after_id, "heading"))
    anchor = written || grammar_id(st, text, no)

    above = Enum.drop_while(st.stack, fn {l, _, _} -> l >= level end)
    n = st.cur.n + 1
    stack = [{level, text, n} | above]
    path = stack |> Enum.reverse() |> Enum.map_join("/", &elem(&1, 1))
    parent = with [{_, _, p} | _] <- above, do: p, else: (_ -> nil)
    next = Map.put(section(n, text, anchor, path, no), :parent, parent)
    %{st | done: [st.cur | st.done], cur: next, stack: stack}
  end

  # The id comments of their own line that open no block, as %{line => {id, why}}: why is
  # what came before any close marker, `{:heading, line}`, `{:marker, line, id}` (another
  # opening marker) or `:eof`. Such a comment is a heading's id on the line after the
  # heading, and otherwise names the paragraph or list item after it. A marker a close
  # marker follows first opens a block, exactly as before, so a comment is an id only
  # where it was once an error (a block left open, spanning a heading or opening inside
  # another).
  defp unclosed(lines) do
    start = %{fence: nil, pending: nil, ids: %{}}

    st =
      Enum.reduce(lines, start, fn {line, no}, st ->
        {prose?, fence} = Fence.step(line, st.fence)
        st = %{st | fence: fence}

        cond do
          not prose? ->
            st

          heading(line) != nil ->
            resolved(st, {:heading, no})

          Regex.match?(@open_block, line) ->
            [id] = Regex.run(@open_block, line, capture: :all_but_first)
            %{resolved(st, {:marker, no, id}) | pending: {no, id}}

          Regex.match?(@close_block, line) ->
            %{st | pending: nil}

          true ->
            st
        end
      end)

    resolved(st, :eof).ids
  end

  defp resolved(%{pending: nil} = st, _why), do: st

  defp resolved(%{pending: {no, id}} = st, why),
    do: %{st | pending: nil, ids: Map.put(st.ids, no, {id, why})}

  # An id comment of its own with no paragraph or list item after it: as a block's opening
  # marker, the error it always was.
  defp names_nothing(st, {marker, id, why}) do
    named = "; an id comment of its own line names the paragraph or list item after it"

    case why do
      {:heading, no} ->
        fail(st, no, "block #{id} (line #{marker}) spans a heading#{named}")

      {:marker, no, other} ->
        fail(st, no, "block #{other} opens inside block #{id} (line #{marker})#{named}")

      :eof ->
        fail(st, marker, "block #{id} is never closed#{named}")
    end
  end

  @doc """
  The regex a `heading_ids:` setting names, with a named capture `id`: `:section_sign` for
  a leading `§ID` (`§Api.3.2`), `:section_number` for a leading `1.`, `1.2`, `1.2.3`, whose
  last part may end in a letter before its dot (`2a.`), or the project's own regex. Raises
  on anything else, or a regex with no `id` capture. The setting may also be a list of
  these, tried in order.
  """
  @spec heading_grammar(atom | Regex.t() | nil) :: Regex.t() | nil
  defdelegate heading_grammar(setting), to: Ids

  @doc false
  # Whether a glob, as `Path.wildcard/1` reads one relative to the root, matches a relative
  # path: `**` any directories, `*` and `?` within one name, `{a,b}` either, `[…]` a class.
  @spec glob_match?(String.t(), String.t()) :: boolean
  defdelegate glob_match?(glob, path), to: ClassMarkers

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
        step({line, no}, Table.close_table(st))
    end
  end

  # ── Contracts ───────────────────────────────────────────────────────────

  # A contract marker's module (nil when it names none), or :none. The bare marker is
  # also a block's opening marker, and stays one where a close marker makes it a block.
  defp contract_marker(st, line, no) do
    case Contract.marker(line) do
      nil -> if Map.has_key?(st.unclosed, no), do: nil, else: :none
      other -> other
    end
  end

  # The fence opens: its module is the marker's, else the nearest heading's that names one
  # (§11.9). Only a signature its head or a defmodule doesn't place needs it, so a heading
  # naming several is an error only then (close_contract/1).
  defp open_contract(st, line, no) do
    headings = Enum.map(st.stack, &elem(&1, 1))
    module = st.contract.module || Contract.subject(st.subjects, st.file, headings)

    contract =
      Map.merge(st.contract, %{module: module, open: true, open_line: line, lines: [], close: nil})

    %{st | contract: contract, cur: extend(st.cur, line, no)}
  end

  # One unit per function the fence's signatures name; its other lines, and its fences,
  # stay in the body around it.
  defp close_contract(%{contract: contract} = st) do
    lines = Enum.reverse(contract.lines)

    sigs =
      case Contract.signatures(lines, contract.module) do
        {:ok, [], _rest} ->
          fail(
            st,
            contract.first,
            "the contract fence holds no @spec, @callback or @macrocallback"
          )

        {:ok, sigs, rest} ->
          {sigs, rest}

        {:error, no, why} ->
          fail(st, no, "the contract signature #{why}")
      end

    {sigs, rest} = sigs

    units =
      for sig <- sigs do
        %{
          role: :contract,
          id: sig.key,
          first: sig.first,
          last: sig.last,
          body: sig.body,
          within: contract.within,
          contract: sig.contract
        }
      end

    around = [contract.open_line | Enum.map(rest, &elem(&1, 0))] ++ List.wrap(contract.close)
    st = %{st | contract: nil, units: Enum.reverse(units) ++ st.units}

    if st.block,
      do: %{st | block: %{st.block | body: Enum.reverse(around) ++ st.block.body}},
      else: %{st | cur: %{st.cur | body: Enum.reverse(around) ++ st.cur.body}}
  end

  # A marked list's items, each a rule whose id it writes: its id comment, or what the
  # project's rule_ids: grammar reads from its text. Anything else ends the list.
  defp rules_step({line, no}, %{rules: rules} = st) do
    item = list_item(line)

    cond do
      item != nil and rules.kind in [nil, item.kind] ->
        id =
          case lead(item.text) do
            {id, _rest} ->
              id

            nil ->
              read_id(st.rule_grammar, st, String.trim(item.text), no, "rule") ||
                fail(
                  st,
                  no,
                  "an item of rules #{rules.name} has no id: it needs an id comment or an id rule_ids: reads"
                )
          end

        st = %{st | rules: %{rules | kind: item.kind}}
        open_rule(st, checked_id!(st, no, id, "rule"), item, no)

      rules.kind == nil and String.trim(line) == "" ->
        %{st | cur: extend(st.cur, line, no)}

      rules.kind == nil ->
        fail(st, rules.first, "rules #{rules.name} has no list after its marker")

      true ->
        step({line, no}, %{st | rules: nil})
    end
  end

  # Whether a line continues a paragraph: prose text, not a heading, a marker or a fence.
  defp text_line?(st, line, fence_before, fence_after),
    do:
      fence_before == nil and fence_after == nil and String.trim(line) != "" and
        heading(line) == nil and not own_marker?(st, line)

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

  @doc """
  Whether a spec unit has no text of its own: a heading over subsections, whose version is
  that of an empty body. Such a unit carries no claims (§20).
  """
  @spec empty?(Surfex.Scan.t()) :: boolean
  def empty?(%Surfex.Scan{kind: :spec, hash: hash}), do: hash == hash([])

  @doc """
  Whether a spec unit states nothing of its own: it is `empty?/1`, or every line of its own
  text is one a `not_claims:` pattern matched (§13.12). What verification (§13.4) and
  completeness (§20) read as own text; its version still covers every line.
  """
  @spec claimless?(Surfex.Scan.t()) :: boolean
  def claimless?(%Surfex.Scan{kind: :spec, not_claims: %{own_text: false}}), do: true
  def claimless?(%Surfex.Scan{kind: :spec} = scan), do: empty?(scan)

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
