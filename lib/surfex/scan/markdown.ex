defmodule Surfex.Scan.Markdown do
  @moduledoc """
  The spec scanner for markdown: one `Surfex.Scan` record per section, per marked block,
  and per test hint.

  A **section** is a heading and the lines under it, up to the next heading of any level.
  Its subsections are sections of their own, so an edit to §3.2 changes §3.2's version and
  not §3's. Text before the first heading is the section `(preamble)`, when it has any.

    * **id** — the file and the path of headings down to it:
      `spec.md#Carts/Adding items`. Two sections with the same path in one file are told
      apart by a suffix, `~2`, `~3`, in order. A heading **anchor**,
      `## Adding items {#cart-add}`, gives the section the id `spec.md#cart-add` instead,
      which survives renaming the heading or any heading above it.
    * **hash** — over the section's own body, **not its heading** (nor its anchor), with
      runs of whitespace collapsed. Rewording the body changes it; renaming the heading,
      reflowing a paragraph or adding blank lines doesn't. A renamed heading keeps its
      version under a new id, which is what lets a tool recognise the move.
    * **location** — the file, from the heading's line to the section's last line.

  Two finer units sit inside sections, each a record of its own with its own version, and
  each left out of the version of what it sits in, so editing one changes only its own:

    * A **marked block** is a requirement: the lines between `<!-- surfex: ID -->` and
      `<!-- /surfex -->`, each marker on a line of its own. Its id is `file#ID`. A block
      can't nest in another or span a heading, and one left open is an error.
    * A **test hint** says how to test something: a fenced block whose info string is
      exactly `test ID`. Its id is `file#ID` and its version covers the fence's content.
      A `test` fence without an id is an ordinary code block.

  Anchors, block ids and hint ids share one namespace per file with the section ids, and
  are `[a-z0-9][a-z0-9-]*`. A duplicate is an error naming both lines. Every error raises
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
  @hint ~r/^test\s+(\S+)$/

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
    grammar = heading_grammar(Keyword.get(opts, :heading_ids))

    {sections, units} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> split(file, grammar)

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
  defp split(lines, file, grammar) do
    start = %{
      file: file,
      grammar: grammar,
      done: [],
      cur: section(0, nil, nil, "(preamble)", 1),
      stack: [],
      fence: nil,
      block: nil,
      hint: nil,
      units: []
    }

    st = Enum.reduce(lines, start, &step/2)

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

  defp step({line, no}, st) do
    {prose?, fence} = Fence.step(line, st.fence)
    opened? = st.fence == nil and fence != nil

    cond do
      opened? and hint_id(line) != nil ->
        id = checked_id!(st, no, hint_id(line), "test hint")
        hint = %{id: id, first: no, body: [], within: within(st)}
        %{st | fence: fence, hint: hint, cur: extend(st.cur, line, no)}

      prose? and heading(line) != nil ->
        if st.block,
          do: fail(st, no, "block #{st.block.id} (line #{st.block.first}) spans a heading")

        new_section(st, heading(line), no)

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
    # An id the author wrote wins: a comment at the end of the heading, or a {#anchor}. Then
    # the project's heading grammar (heading_ids:). Neither: the heading path.
    {text, explicit} = explicit_id(st, text, no)
    anchor = explicit || grammar_id(st, text, no)

    stack = [{level, text} | Enum.drop_while(st.stack, fn {l, _} -> l >= level end)]
    path = stack |> Enum.reverse() |> Enum.map_join("/", &elem(&1, 1))
    next = section(st.cur.n + 1, text, anchor, path, no)
    %{st | done: [st.cur | st.done], cur: next, stack: stack}
  end

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

  defp grammar_id(%{grammar: nil}, _text, _no), do: nil

  defp grammar_id(%{grammar: grammar} = st, text, no) do
    case Regex.named_captures(grammar, text) do
      %{"id" => id} -> checked_id!(st, no, id, "heading")
      nil -> nil
    end
  end

  @doc """
  The regex a `heading_ids:` setting names, with a named capture `id`: `:section_sign` for
  a leading `§ID` (`§Api.3.2`), `:section_number` for a leading `1.`, `1.2`, `1.2.3`, or
  the project's own regex. Raises on anything else, or a regex with no `id` capture.
  """
  @spec heading_grammar(atom | Regex.t() | nil) :: Regex.t() | nil
  def heading_grammar(nil), do: nil

  def heading_grammar(:section_sign),
    do: ~r/^§\s*(?<id>[A-Za-z0-9][A-Za-z0-9._:-]*?)[.:]?(?=\s|$)/u

  def heading_grammar(:section_number), do: ~r/^(?<id>\d+(?:\.\d+)*)\.?(?=\s|$)/

  def heading_grammar(%Regex{} = regex) do
    if "id" in Regex.names(regex),
      do: regex,
      else: raise(ArgumentError, "heading_ids: #{inspect(regex)} needs a named capture (?<id>…)")
  end

  def heading_grammar(other),
    do:
      raise(
        ArgumentError,
        "heading_ids: must be :section_sign, :section_number or a regex with (?<id>…), got #{inspect(other)}"
      )

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
