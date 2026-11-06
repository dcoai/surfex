defmodule Surfex.Cite do
  @moduledoc """
  Finds a spec's citations of the code and resolves them against the items a scanner
  found.

  **No new notation.** A spec already cites code in prose: a code span naming a function,
  a struct, a constant or a file. Those spans are the machine-readable form. Markers would
  churn every chapter to say what the prose already says, and a notation nobody reads
  while writing is a notation that rots.

  **A span is a citation when it resolves.** A span that names an item is a citation of
  it, and the item's golden row gains the section the span sits under. A span that does
  not resolve, but has the profile's `:shape`, is an **unresolved** citation: the code
  renamed or removed it, or it was never there. Anything else in backticks (`:ok`, a shell
  command, another project's module) is prose, not a claim about this code.

  Every citation ends in exactly one status:

  - `:resolved` — the span names one item (or, for a member path, one item per step)
  - `:ambiguous` — it names more than one. Reported, never guessed: a coverage document
    that picks one of two meanings is worse than one that says it cannot tell
  - `:unresolved` — it has the shape of a claim about the code and names nothing
  - `:external` — it names something real outside the scanned tree (`:known_external`)
  - `:documented_absence` — a section names it *because* the code does not have it
  - `:registered_name` — it names exactly a process name the source registers
    (`name: MyApp.Sessions`) and no module (`citations/4`'s `:registered`)
  - `:test_support` — it names a module, function or type in the project's test support
    (`citations/4`'s `:support`)

  ## What is read

  - **Code spans**, line by line, credited to the nearest heading above them (a markdown
    `#` heading, or the `defmodule` in an `.ex` source), or `(preamble)` before the first.
  - **Headings of subject sections** (`Surfex.Profile` `:subjects`), which cite the items
    the section is about.
  - **Table cells** under the profile's `:table_columns`, backticked or not, a row split
    into cells as GFM splits it (an escaped `\\|` stays in its cell).
  - **Fenced code blocks**, whose shape-matching tokens are credited to `(code block)` at
    their line, once per fence. A fence is CommonMark's (`Surfex.Scan.Markdown.Fence`): any
    info string opens one, and only a matching closer closes it, so prose is never read as
    code. Inside a fence nothing else is read: a `# comment` in a code block is not a
    heading and a backtick in code is not a span.

  Everything that differs between projects (what a claim looks like, how the spec is
  laid out) is `Surfex.Profile` data.
  """

  alias Surfex.{Item, Profile}
  alias Surfex.Golden.Span
  alias Surfex.Scan.Markdown.Fence

  @type status ::
          :resolved
          | :unresolved
          | :ambiguous
          | :external
          | :documented_absence
          | :registered_name
          | :test_support

  @typedoc """
  How a citation was made (§6.10): `:span`, a code span in prose or a token in a fenced
  code block; `:subject`, a subject section's heading (§6.6) or a contract's own key
  (§6.9), naming what the unit is about; `:cell`, a cell under a citing column, naming
  its row's subject as a heading does.
  """
  @type kind :: :span | :subject | :cell

  @typedoc """
  One citation: the span as written, how it was made (`kind`), where it is, and what it
  resolved to. A contract's citation of its own function (§6.9) that names nothing says
  why, `why`, and an external citation carries its `known_external` reason as `why`
  (§6.11): a golden's names, the golden's path.
  """
  @type t :: %{
          optional(:why) => String.t(),
          span: String.t(),
          kind: kind,
          file: String.t(),
          section: String.t(),
          line: pos_integer,
          status: status,
          items: [String.t()]
        }

  @typedoc "Citation key => every item with that key. More than one is what `:ambiguous` is."
  @type index :: %{String.t() => [Item.t()]}

  @doc """
  Every citation in the profile's sources under `root`, resolved against `items`, sorted
  by file, line and span.

  `opts`: `:registered`, the process names the source registers that are no module
  (spec §6.7). A span naming exactly one of them, and nothing else, is a
  `:registered_name`; a function or member on it still names nothing.
  """
  @spec citations([Item.t()], Profile.t(), String.t(), keyword) :: [t]
  def citations(items, %Profile{} = profile, root, opts \\ []) do
    base = %{
      index: index(items, profile),
      aliases: aliases(items),
      profile: profile,
      registered: opts |> Keyword.get(:registered, []) |> MapSet.new(),
      support: opts |> Keyword.get(:support, []) |> MapSet.new()
    }

    profile
    |> sources(root)
    |> Enum.flat_map(&citations_in(&1, root, Map.put(base, :path, &1)))
    |> Enum.sort_by(&{&1.file, &1.line, &1.span})
  end

  @doc "The source files scanned, relative to `root`, in a stable order."
  @spec sources(Profile.t(), String.t()) :: [String.t()]
  def sources(%Profile{sources: globs, exclude: exclude}, root),
    do: Surfex.Scan.Markdown.files(root, globs, exclude)

  @doc """
  Key => items. Every item is indexed by `Item.key/1`, so a member is reached only through
  its parent (`struct.field`), a subject section, or a member path, never by its bare
  name: a bare `offset` naming three structs' fields is scanner noise, not spec
  imprecision. Each `:file_targets` name is indexed as a `:file` item.
  """
  @spec index([Item.t()], Profile.t()) :: index
  def index(items, %Profile{file_targets: targets}) do
    by_key = Enum.group_by(items, &Item.key/1)

    by_file =
      targets
      |> Enum.flat_map(fn
        :item_files -> Enum.map(items, & &1.file)
        file -> [file]
      end)
      |> Enum.uniq()
      |> Map.new(&{&1, [%Item{kind: :file, name: &1, file: &1, hash: "—"}]})

    Map.merge(by_key, by_file)
  end

  # Alias => every item declaring it: a family, cited together.
  defp aliases(items) do
    for item <- items, alias <- item.aliases, reduce: %{} do
      acc -> Map.update(acc, alias, [item], &[item | &1])
    end
  end

  # ── Scanning ────────────────────────────────────────────────────────────

  defp citations_in(path, root, ctx), do: lines(File.read!(Path.join(root, path)), ctx)

  # The line scan's state: the heading stack (`{level, heading, subject keys}`, deepest
  # first), the fence we are inside (`Fence.state/0`) and the tokens it already credited,
  # and the table being read (the previous row's cells until a separator row confirms them
  # as a header).
  @start %{stack: [], fence: nil, seen: MapSet.new(), prev: nil, columns: nil}

  defp lines(text, ctx) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map_reduce(@start, fn {line, no}, st -> step(line, no, st, ctx) end)
    |> elem(0)
  end

  defp step(line, no, %{fence: {_, _} = fence} = st, ctx) do
    case Fence.step(line, fence) do
      {false, nil} -> {[], %{st | fence: nil, seen: MapSet.new()}}
      {false, fence} -> fenced(line, no, %{st | fence: fence}, ctx)
    end
  end

  defp step(line, no, st, ctx) do
    case Fence.step(line, nil) do
      {false, fence} -> {[], %{st | fence: fence, prev: nil, columns: nil}}
      {true, nil} -> prose(line, no, st, ctx)
    end
  end

  # A fenced block quoting code documents it as surely as prose does. Only shape-matching
  # tokens are credited, so a block of the project's own code is not mistaken for claims,
  # and each once per fence, at the line it first appears on.
  defp fenced(line, no, st, ctx) do
    tokens =
      line
      |> tokens(ctx.profile)
      |> Enum.filter(&shaped?(&1, ctx.profile))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(st.seen, &1))

    cites =
      Enum.flat_map(tokens, fn token ->
        case named(token, token, ctx) do
          nil -> []
          found -> [citation(found, :span, ctx.path, "(code block)", no)]
        end
      end)

    {cites, %{st | seen: MapSet.union(st.seen, MapSet.new(tokens))}}
  end

  defp prose(line, no, st, ctx) do
    cond do
      heading = heading(ctx.path, line) ->
        {level, text} = heading
        subjects = subjects(ctx.path, text, ctx.profile)
        stack = [{level, text, subjects} | Enum.drop_while(st.stack, &(elem(&1, 0) >= level))]
        st = %{st | stack: stack, prev: nil, columns: nil}
        {subject_cites(subjects, text, no, ctx) ++ span_cites(line, no, st, ctx), st}

      table_row?(line) ->
        cells = Span.cells(line)
        spans = span_cites(line, no, st, ctx)

        cond do
          separator?(cells) and st.prev != nil -> {spans, %{st | columns: st.prev, prev: nil}}
          st.columns != nil -> {spans ++ cell_cites(cells, st.columns, no, st, ctx), st}
          true -> {spans, %{st | prev: cells}}
        end

      true ->
        {span_cites(line, no, st, ctx), %{st | prev: nil, columns: nil}}
    end
  end

  defp section([{_, text, _} | _]), do: text
  defp section([]), do: "(preamble)"

  defp scopes(stack), do: Enum.flat_map(stack, &elem(&1, 2))

  defp span_cites(line, no, st, ctx) do
    ~r/`([^`\n]+)`/
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.flat_map(fn [span] -> resolve(span, scopes(st.stack), ctx) end)
    |> Enum.map(&citation(&1, :span, ctx.path, section(st.stack), no))
  end

  # A subject section's heading cites what it is about. A subject key that names nothing
  # is unresolved: the profile points at an item the code no longer has.
  defp subject_cites(keys, heading, no, ctx) do
    Enum.map(keys, fn key ->
      found =
        case Map.fetch(ctx.index, key) do
          {:ok, items} -> found(heading, items)
          :error -> {heading, :unresolved, []}
        end

      citation(found, :subject, ctx.path, heading, no)
    end)
  end

  defp subjects(path, heading, %Profile{subjects: subjects}) do
    Enum.flat_map(subjects, fn %{file: file, heading: re, items: items} ->
      if file_matches?(file, path) and Regex.match?(re, heading), do: items, else: []
    end)
  end

  defp file_matches?(file, path) when is_binary(file), do: file == path
  defp file_matches?(re, path), do: Regex.match?(re, path)

  # A cell under a citing column names the row's subject; it needs no backticks. One that
  # has a code span was already cited by the span scan.
  defp cell_cites(cells, columns, no, st, ctx) do
    cols = MapSet.new(ctx.profile.table_columns)

    columns
    |> Enum.zip(cells)
    |> Enum.filter(fn {col, cell} ->
      MapSet.member?(cols, strip(col)) and cell != "" and not String.contains?(cell, "`")
    end)
    |> Enum.flat_map(fn {_col, cell} -> resolve(strip(cell), scopes(st.stack), ctx) end)
    |> Enum.map(&citation(&1, :cell, ctx.path, section(st.stack), no))
  end

  # An external citation carries its reason, `why` (§6.11).
  defp citation({span, status, items, why}, kind, file, section, line),
    do: Map.put(citation({span, status, items}, kind, file, section, line), :why, why)

  defp citation({span, status, items}, kind, file, section, line),
    do: %{
      span: span,
      kind: kind,
      file: file,
      section: section,
      line: line,
      status: status,
      items: items
    }

  defp heading(path, line) do
    cond do
      String.ends_with?(path, ".md") ->
        # An anchor, `{#id}`, names the section for the relation log (§11); it is not the
        # heading's text.
        case Regex.run(~r/^(#+)\s+(.+?)(?:\s*\{#[^}\s]*\})?\s*$/, line, capture: :all_but_first) do
          [hashes, text] -> {String.length(hashes), text}
          _ -> nil
        end

      String.ends_with?(path, ".ex") ->
        case Regex.run(~r/^defmodule\s+([\w.]+)/, line, capture: :all_but_first) do
          [module] -> {1, module}
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp table_row?(line), do: String.starts_with?(String.trim_leading(line), "|")

  defp separator?(cells), do: cells != [] and Enum.all?(cells, &Regex.match?(~r/^:?-+:?$/, &1))

  # Emphasis is presentation, not part of the name.
  defp strip(cell), do: cell |> String.replace("*", "") |> String.trim()

  # ── Resolution ──────────────────────────────────────────────────────────

  defp resolve(span, scopes, %{index: index, path: file, profile: profile} = ctx) do
    name = normalise(span, profile)

    cond do
      Map.has_key?(profile.documented_absences, {name, file}) ->
        [{span, :documented_absence, []}]

      Map.has_key?(profile.known_external, name) ->
        [{span, :external, [], Map.fetch!(profile.known_external, name)}]

      # Inside a section about a structure, its member wins over a global of the same name:
      # that is what declaring the subject says.
      key = scoped(name, scopes, index) ->
        [found(span, Map.fetch!(index, key))]

      found = named(span, name, ctx) ->
        [found]

      keys = member_path(name, scopes, index) ->
        [{span, :resolved, keys}]

      # Something real the source names, not code: listed under its own status, so it
      # never hides a misspelt module (§6.7).
      MapSet.member?(ctx.registered, name) ->
        [{span, :registered_name, []}]

      MapSet.member?(ctx.support, name) ->
        [{span, :test_support, []}]

      shaped?(name, profile) ->
        [{span, :unresolved, []}]

      true ->
        inner(span, ctx)
    end
  end

  # A bare name inside a subject section: the first subject that has it as a member.
  defp scoped(name, scopes, index) do
    Enum.find_value(scopes, fn subject ->
      key = "#{subject}.#{name}"
      if Map.has_key?(index, key), do: key
    end)
  end

  # `field.member`: resolve the longest prefix that names an item (directly or through a
  # subject), then each further step as a member of the previous item's `:type`, or of the
  # item itself when it has none. Every step from the prefix on is cited: the row documents
  # the embedded structure's member *and* the field that embeds it. A step that does not
  # name exactly one item makes the whole path fall through, to be judged by its shape like
  # any other span.
  defp member_path(name, scopes, index) do
    segments = String.split(name, ".")

    with [_, _ | _] <- segments,
         {key, rest} <- prefix(segments, scopes, index),
         [item] <- Map.fetch!(index, key) do
      walk(rest, item, [key], index)
    else
      _ -> nil
    end
  end

  defp prefix(segments, scopes, index) do
    Enum.find_value((length(segments) - 1)..1//-1, fn n ->
      {head, rest} = Enum.split(segments, n)
      name = Enum.join(head, ".")
      key = (Map.has_key?(index, name) && name) || scoped(name, scopes, index)
      if key, do: {key, rest}
    end)
  end

  defp walk([], _item, keys, _index), do: Enum.reverse(keys)

  defp walk([step | rest], item, keys, index) do
    key = "#{item.type || Item.key(item)}.#{step}"

    case Map.get(index, key) do
      [next] -> walk(rest, next, [key | keys], index)
      _ -> nil
    end
  end

  # A span can carry a name rather than be one: `setsockopt(fd, SO_APP_SERVER, int)` cites
  # `SO_APP_SERVER`. Only shaped or known-shaped tokens are tried, so `fd` and `int` inside
  # such a span are not mistaken for citations.
  defp inner(span, ctx) do
    span
    |> tokens(ctx.profile)
    |> Enum.filter(&(shaped?(&1, ctx.profile) or known?(&1, ctx)))
    |> Enum.uniq()
    |> Enum.flat_map(fn token ->
      case named(span, token, ctx) do
        nil -> []
        found -> [found]
      end
    end)
  end

  # A name that is a key names its items (ambiguous if several); one that is an alias names
  # its family, all of which it cites.
  defp named(span, name, %{index: index, aliases: aliases}) do
    case {Map.get(index, name), Map.get(aliases, name)} do
      {[_ | _] = items, _} -> found(span, items)
      {nil, [_ | _] = family} -> {span, :resolved, family |> Enum.map(&Item.key/1) |> Enum.sort()}
      {nil, nil} -> nil
    end
  end

  defp found(span, [item]), do: {span, :resolved, [Item.key(item)]}
  defp found(span, many), do: {span, :ambiguous, many |> Enum.map(&Item.key/1) |> Enum.sort()}

  defp tokens(text, %Profile{token: re}),
    do: re |> Regex.scan(text, capture: :all_but_first) |> List.flatten()

  defp normalise(span, %Profile{normalise: rewrites}),
    do: Enum.reduce(rewrites, String.trim(span), fn {re, rep}, s -> Regex.replace(re, s, rep) end)

  defp shaped?(name, %Profile{shape: re}), do: Regex.match?(re, name)

  defp known?(_token, %{profile: %Profile{known_shape: nil}}), do: false

  defp known?(token, %{profile: %Profile{known_shape: re}} = ctx),
    do: Regex.match?(re, token) and named(token, token, ctx) != nil
end
