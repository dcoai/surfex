defmodule Surfex.Trace do
  @moduledoc """
  > **Deprecated.** The relation log (`Surfex.Status`, `mix surfex.status`) replaces the
  > trace: it records which versions of the spec and the code were confirmed to belong
  > together, where the trace records only that they cite each other. The trace still
  > works, and `mix surfex.suggest` reads its citations, until a later release removes it.

  A two-way trace between a spec and the code: what the code declares, which spec
  sections cite each item, and what is wrong with either.

  Code → spec: every item gets a row saying which sections cite it, or which class makes
  the spec's silence expected, or **`GAP`**. Spec → code: every citation resolves, or is
  reported. `render/2` writes this as a surface golden (`Surfex.Golden`), and
  `mix surfex.trace` gates it.

  A trace is defined by data, usually a project's `.surfex.exs` (`load!/2`): every
  `Surfex.Profile` key, plus the keys below.

  ## Where the items come from

    * `:scanner` — `:elixir` (the default, `Surfex.Scanner.Elixir`) or a module
      implementing `Surfex.Scanner`
    * `:scanner_opts` — passed to the scanner
    * `:namespace` — for `:elixir`, the root module whose names are claims about the code.
      `mix surfex.trace` derives it from the app name; set it to override.

  For `:elixir`, `Surfex.Scanner.Elixir.profile_defaults/1` supplies `:shape`, `:token`
  and `:normalise`. Any of them set here wins.

  ## The golden

    * `:output` — its path (default `SPEC_TRACE.md`)
    * `:purpose`, `:task`, `:gate`, `:hardness` — the header block (`Surfex.Golden`).
      `:task` defaults to `surfex.goldens`, the command that regenerates it.
    * `:item_noun` — the stats line's lead: `"464 reference items"` (default `"items"`)
    * `:columns` — any of `"Item"`, `"Kind"`, `"Value"`, `"Version"`, `"Cited by"`,
      `"Locus"`, in order (default: all six; for `:elixir`, all but `"Value"`, since an
      Elixir item has no declared value)
    * `:groups` — `[{kind, heading}]`, the order tables appear in (for `:elixir`:
      Modules, Functions, Macros). A kind not listed still gets a table, after these,
      headed by its name: rows are never dropped.
    * `:locus_prefix` — prepended to each item's file in the `Locus` column
    * `:not_catalogued` — `[{what, why}]`: what the scanner knowingly does not report
    * `:prose` — the text between the header and the stats line, as a list of blocks.
      A string is markdown, printed as written. `{list, heading}` prints `### heading` and
      one of the generated lists, so what the golden says about silence cannot drift from
      the rules that produce it:
        * `:not_catalogued` — `- **what** — why`
        * `:known_external` — `` - `name` — reason ``
        * `:classes` — `- **class** — reason`, in the profile's order
        * `:documented_absences` — `` - `span` in `file` — reason ``, per citation found
      A list with nothing in it is left out, heading and all.

  ## Failures

  `failures/2` lists everything that must fail a gate, all of it, in one pass:

    * an item whose verdict is `GAP`
    * a citation that is `:unresolved` or `:ambiguous`
    * with `:require_citation` (a heading regex), a matching section that cites nothing

  Inputs that would make a golden meaningless raise instead, before anything renders: no
  sources matched, no items scanned, or a `:require_citation` that matches no heading.
  """

  alias Surfex.{Cite, Coverage, Golden, Item, Profile}

  @columns ["Item", "Kind", "Value", "Version", "Cited by", "Locus"]
  @lists [:not_catalogued, :known_external, :classes, :documented_absences]

  @enforce_keys [:profile]
  defstruct profile: nil,
            scanner: :elixir,
            scanner_opts: [],
            namespace: nil,
            output: "SPEC_TRACE.md",
            purpose: "Every item the code declares, and the spec sections that cite it.",
            task: "surfex.goldens",
            gate: "spec-trace-drift",
            hardness: :hard,
            item_noun: "items",
            columns: @columns,
            groups: [],
            locus_prefix: "",
            not_catalogued: [],
            prose: [],
            require_citation: nil

  @type block :: String.t() | {atom, String.t()}

  @type t :: %__MODULE__{
          profile: Profile.t(),
          scanner: :elixir | module,
          scanner_opts: keyword,
          namespace: String.t() | nil,
          output: String.t(),
          purpose: String.t(),
          task: String.t(),
          gate: String.t(),
          hardness: :hard | :advisory,
          item_noun: String.t(),
          columns: [String.t()],
          groups: [{atom, String.t()}],
          locus_prefix: String.t(),
          not_catalogued: [{String.t(), String.t()}],
          prose: [block],
          require_citation: Regex.t() | nil
        }

  @typedoc "What a trace found: the citations, and each item's citing sections and verdict."
  @type analysis :: %{
          items: [Item.t()],
          citations: [Cite.t()],
          by_item: %{String.t() => [String.t()]},
          verdicts: [{Item.t(), Coverage.verdict()}],
          headings: [{String.t(), String.t()}]
        }

  @trace_keys [
    :scanner,
    :scanner_opts,
    :namespace,
    :output,
    :purpose,
    :task,
    :gate,
    :hardness,
    :item_noun,
    :columns,
    :groups,
    :locus_prefix,
    :not_catalogued,
    :prose,
    :require_citation
  ]

  @doc """
  Evaluates a `.surfex.exs` data file, which must return a keyword list, and builds the
  trace from it. `defaults` fills keys the file does not set; `mix surfex.trace` passes
  the namespace it derived. A `goldens:` key belongs to `mix surfex.goldens` and is
  ignored here.
  """
  @spec load!(String.t(), keyword) :: t
  def load!(path, defaults \\ []) do
    config = path |> Surfex.Gate.config!() |> own_keys()
    new!(Keyword.merge(defaults, config))
  end

  # Keys other tools read from the same `.surfex.exs`: `mix surfex.goldens`'s list, and
  # `mix surfex.status`'s policy.
  @other_tools [:goldens, :require]

  @doc "A `.surfex.exs` config without the keys other tools read (`goldens:`, `require:`)."
  @spec own_keys(keyword) :: keyword
  def own_keys(config), do: Keyword.drop(config, @other_tools)

  @doc "A validated trace from a keyword list. Raises `ArgumentError` naming the key."
  @spec new!(keyword) :: t
  def new!(config) do
    {trace, profile} = Keyword.split(config, @trace_keys)
    trace = Keyword.merge(layout_defaults(Keyword.get(trace, :scanner, :elixir)), trace)
    trace = struct!(__MODULE__, Keyword.put(trace, :profile, nil))
    Enum.each(@trace_keys, &check!(&1, Map.fetch!(trace, &1)))
    %{trace | profile: Profile.new!(Keyword.merge(scanner_defaults(trace), profile))}
  end

  # An Elixir trace's tables read Modules / Functions / Macros, and it has no `Value`
  # column, since an Elixir item has no declared value. A project's own keys win.
  defp layout_defaults(:elixir),
    do: [
      groups: [module: "Modules", function: "Functions", macro: "Macros"],
      columns: ["Item", "Kind", "Version", "Cited by", "Locus"]
    ]

  defp layout_defaults(_scanner), do: []

  defp scanner_defaults(%{scanner: :elixir, namespace: nil}),
    do: raise(ArgumentError, "trace key :namespace is required for scanner: :elixir")

  defp scanner_defaults(%{scanner: :elixir, namespace: ns}),
    do: Surfex.Scanner.Elixir.profile_defaults(ns)

  defp scanner_defaults(_trace), do: []

  defp check!(key, value) do
    if valid?(key, value),
      do: :ok,
      else: raise(ArgumentError, "trace key #{inspect(key)} is invalid: #{inspect(value)}")
  end

  defp valid?(:scanner, v), do: is_atom(v) and not is_nil(v)
  defp valid?(:scanner_opts, v), do: Keyword.keyword?(v)
  defp valid?(:namespace, v), do: is_nil(v) or (is_binary(v) and v =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/)
  defp valid?(:hardness, v), do: v in [:hard, :advisory]
  defp valid?(:columns, v), do: is_list(v) and v != [] and Enum.all?(v, &(&1 in @columns))

  defp valid?(:groups, v),
    do: is_list(v) and Enum.all?(v, &match?({k, h} when is_atom(k) and is_binary(h), &1))

  defp valid?(:not_catalogued, v),
    do: is_list(v) and Enum.all?(v, &match?({a, b} when is_binary(a) and is_binary(b), &1))

  defp valid?(:prose, v), do: is_list(v) and Enum.all?(v, &block?/1)
  defp valid?(:require_citation, v), do: is_nil(v) or is_struct(v, Regex)
  defp valid?(_string_key, v), do: is_binary(v)

  defp block?(text) when is_binary(text), do: true
  defp block?({list, heading}) when list in @lists and is_binary(heading), do: true
  defp block?(_), do: false

  @doc "The items the trace's scanner finds under `root`."
  @spec items(t, String.t()) :: [Item.t()]
  def items(%__MODULE__{scanner: :elixir, scanner_opts: opts}, root),
    do: Surfex.Scanner.Elixir.items(root, opts)

  def items(%__MODULE__{scanner: scanner, scanner_opts: opts}, root) do
    unless Code.ensure_loaded?(scanner) and function_exported?(scanner, :items, 2),
      do: raise(ArgumentError, "scanner #{inspect(scanner)} does not implement Surfex.Scanner")

    scanner.items(root, opts)
  end

  @doc """
  Cites `items` from the sources under `root`. Raises when there is nothing to trace: no
  source matched, no item was scanned, or `:require_citation` matches no heading.
  """
  @spec analyse(t, [Item.t()], String.t()) :: analysis
  def analyse(%__MODULE__{profile: profile} = trace, items, root) do
    if Cite.sources(profile, root) == [],
      do: raise(ArgumentError, "no spec sources match #{inspect(profile.sources)} under #{root}")

    if items == [], do: raise(ArgumentError, "the scanner found no items under #{root}")

    headings = Cite.headings(profile, root)

    if trace.require_citation &&
         not Enum.any?(headings, fn {_, h} -> Regex.match?(trace.require_citation, h) end),
       do:
         raise(
           ArgumentError,
           "require_citation #{inspect(trace.require_citation)} matches no heading"
         )

    citations = Cite.citations(items, profile, root)
    by_item = Cite.by_item(citations, profile)

    %{
      items: items,
      citations: citations,
      by_item: by_item,
      verdicts: Coverage.verdicts(items, by_item, profile),
      headings: headings
    }
  end

  @doc "Every reason the trace must fail a gate, as one line each, in a stable order."
  @spec failures(t, analysis) :: [String.t()]
  def failures(%__MODULE__{} = trace, analysis) do
    shared = shared_keys(analysis.items)

    gaps =
      for {item, :gap} <- Enum.sort_by(analysis.verdicts, fn {i, _} -> {Item.key(i), i.kind} end),
          do: "GAP: #{named(item, shared)} is neither cited by the spec nor excused by a class"

    bad =
      for %{status: status} = c <- analysis.citations, status in [:unresolved, :ambiguous] do
        also = if c.items == [], do: "", else: " (could be #{Enum.join(c.items, ", ")})"
        "#{status}: `#{c.span}` at #{c.file}:#{c.line}, #{c.section}#{also}"
      end

    gaps ++ bad ++ uncited(trace, analysis)
  end

  # Keys more than one item shares. A message about one of them names its kind too, since
  # the key alone would not say which item is meant.
  defp shared_keys(items) do
    items
    |> Enum.frequencies_by(&Item.key/1)
    |> Enum.flat_map(fn {key, n} -> if n > 1, do: [key], else: [] end)
    |> MapSet.new()
  end

  defp named(item, shared) do
    key = Item.key(item)

    if MapSet.member?(shared, key),
      do: "`#{key}` (`#{inspect(item.kind)}`)",
      else: "`#{key}`"
  end

  defp uncited(%__MODULE__{require_citation: nil}, _analysis), do: []

  defp uncited(%__MODULE__{require_citation: re}, analysis) do
    citing =
      for %{status: :resolved, file: f, section: s} <- analysis.citations,
          into: MapSet.new(),
          do: {f, s}

    for {file, heading} = section <- analysis.headings,
        Regex.match?(re, heading),
        not MapSet.member?(citing, section),
        do: "uncited: #{file}, #{heading} is a required section and cites no code"
  end

  # ── The golden ──────────────────────────────────────────────────────────

  @doc "The trace's golden. Pure; a stable function of the items, sources and trace."
  @spec render(t, analysis) :: String.t()
  def render(%__MODULE__{} = trace, analysis) do
    rows =
      Enum.map(analysis.verdicts, fn {item, verdict} -> row(item, verdict, trace, analysis) end)

    counts = Enum.frequencies_by(analysis.verdicts, fn {_item, verdict} -> tally(verdict) end)

    statuses = Enum.frequencies_by(analysis.citations, & &1.status)

    Golden.render(%{
      name: Path.basename(trace.output),
      purpose: trace.purpose,
      task: trace.task,
      gate: trace.gate,
      hardness: trace.hardness,
      prose: prose(trace, analysis),
      stats: [
        Golden.stat("#{length(analysis.items)} #{trace.item_noun}", [
          {"cited", Map.get(counts, :cited, 0)},
          {"expected-silent", Map.get(counts, :expected, 0)},
          {"GAPS", Map.get(counts, :gap, 0)},
          {"citations", Map.get(statuses, :resolved, 0)},
          {"unresolved", Map.get(statuses, :unresolved, 0)},
          {"ambiguous", Map.get(statuses, :ambiguous, 0)}
        ])
      ],
      columns: trace.columns,
      groups: groups(rows, trace)
    })
  end

  defp tally({:expected, _}), do: :expected
  defp tally(verdict), do: verdict

  defp row(item, verdict, trace, analysis) do
    key = Item.key(item)

    %{
      "Item" => {:code, key},
      "Kind" => {:atom, item.kind},
      "Value" => {:code, item.value || item.detail || "—"},
      "Version" => {:version, item.hash},
      "Cited by" => cited_by(Map.get(analysis.by_item, key, []), verdict),
      "Locus" => {:locus, locus(trace.locus_prefix, item.file), nil},
      kind: item.kind
    }
  end

  defp cited_by([], :gap), do: {:atom, :GAP}
  defp cited_by([], {:expected, class}), do: {:code, "— #{class}"}
  defp cited_by(sections, _verdict), do: {:code, Enum.join(sections, ", ")}

  defp locus("", file), do: file
  defp locus(prefix, file), do: Path.join(prefix, file)

  defp groups(rows, trace) do
    by_kind = Enum.group_by(rows, & &1.kind)
    listed = Enum.map(trace.groups, &elem(&1, 0))

    unlisted =
      by_kind |> Map.keys() |> Kernel.--(listed) |> Enum.sort() |> Enum.map(&{&1, to_string(&1)})

    for {kind, heading} <- trace.groups ++ unlisted,
        rows = Map.get(by_kind, kind, []),
        rows != [],
        do: %{heading: heading, rows: Enum.map(rows, &Map.delete(&1, :kind))}
  end

  defp prose(trace, analysis) do
    trace.prose
    |> Enum.map(&block(&1, trace, analysis))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      blocks -> Enum.join(blocks, "\n\n")
    end
  end

  defp block(text, _trace, _analysis) when is_binary(text), do: String.trim_trailing(text)

  defp block({list, heading}, trace, analysis) do
    case bullets(list, trace, analysis) do
      [] -> nil
      lines -> "### #{heading}\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp bullets(:not_catalogued, trace, _), do: Enum.map(trace.not_catalogued, &bold/1)
  defp bullets(:classes, trace, _), do: Enum.map(trace.profile.classes, &bold/1)

  defp bullets(:known_external, trace, _) do
    for {name, why} <- Enum.sort(trace.profile.known_external), do: "- `#{name}` — #{why}"
  end

  defp bullets(:documented_absences, trace, analysis) do
    for %{status: :documented_absence, span: span, file: file} <- analysis.citations do
      why = Map.get(trace.profile.documented_absences, {String.trim(span), file}, "")
      "- `#{span}` in `#{file}` — #{why}"
    end
  end

  defp bold({what, why}), do: "- **#{what}** — #{why}"

  @doc """
  What changed between a committed trace golden and a fresh render, naming each changed
  item with the sections citing it: the sections to revisit. `nil` when identical. See
  `Surfex.Gate.drift/2`.
  """
  @spec drift(String.t(), String.t()) :: String.t() | nil
  defdelegate drift(old, new), to: Surfex.Gate
end
