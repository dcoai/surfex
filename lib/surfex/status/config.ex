defmodule Surfex.Status.Config do
  @moduledoc """
  What the relation log's tasks read from `.surfex.exs`: where the spec is, how to scan the
  code, how to read citations (the `Surfex.Profile` keys), and the policies.

    * `:sources` — globs of the markdown spec files (required)
    * `:heading_ids` — the ids the spec's authors write into headings: `:section_sign`
      (`## §Api.3.2 — Limits`), `:section_number` (`## 1.2 Totals`, `## 2a. Checks`), a
      regex with a named capture `id`, or a list of these tried in order
      (`Surfex.Scan.Markdown.heading_grammar/1`)
    * `:rule_ids` — the ids written at the start of a marked list's items
      (`<!-- surfex: rules NAME -->`), in the forms `:heading_ids` takes: `:section_sign`
      reads `1. §Tenancy.1.4 …`, a regex `~r/^(?<id>P\d+)/` reads `P3` (§11.1)
    * `:fold_paths` — `true` to make a heading with no id, inside one that has an id, part of
      that unit rather than a unit of its own (§11.1); by default `true` where `:heading_ids`
      is set and `false` where it isn't
    * `:unit_refs` — the project's own forms of citing a spec unit, as regexes with named
      captures `id` and `file` or `chapter` (a spec file's leading number):
      `~r/^§(?<chapter>\d\d)\.(?<id>[\w.]+)$/` reads `§03.4` (§11.1)
    * `:scanners` — the code scanners whose items are combined (§5.3): each `:elixir`, a
      module implementing `Surfex.Scanner`, or `{scanner, opts}`. `[:elixir]` by default
    * `:scanner`, `:scanner_opts` — one code scanner and its options, the same as
      `scanners: [{scanner, scanner_opts}]`
    * `:require` — `[key: [type, …]]`: a key is a kind (`:spec`, `:code`, `:test`, …) or
      a spec role (`:section`, `:block`, `:test_hint`, `:table`, `:row`, `:rule`, `:contract`), validated with the
      types
    * `:tests` — globs of ExUnit test files, scanned for tests (`Surfex.Scan.ExUnit`)
      when present
    * `:declares` — other forms the test scanner reads as `verifies` declarations, for a
      project that already records them in its own (§11.6):
      `[verifies: [{:tag, :validates, strip: ~r/@[0-9a-f]+$/}]]` reads
      `@tag validates: ["Engine.15.2@abc123"]` as declaring `Engine.15.2`
    * `:triangle` — `:report` (the default) or `:fail`: whether gaps in the spec/test/code
      triangle fail the check or are only reported
    * `:require_red` — `true` to refuse confirming a `tests` relation, by evidence or by
      hand, until its test's current version has failed first (`false` by default)
    * `:claim_implements` — `true` to have `mix surfex.suggest` propose `implements` between
      each claim and the code its verifying tests call directly (§15.1); `false` by
      default until the release that completes claim grain
    * `:router` — the router module (or a list of them) whose routes a test's requests
      resolve through (§11); found from the project's endpoint when not given, and `false`
      turns route resolution off
    * `:dispatch` — the project's dispatch functions, `[{Module, :fun, arity}]`: a call to
      one reaches every handler its module's table lists as literal `{Module, :fun}` pairs
      or `&Module.fun/arity` captures (`dispatch!/1`, §11.10)
    * `:checks` — gates that verify claims: each `[id:, run:, verifies:, inputs:]`, a
      command that can fail (a string run through the shell, or an argv run with none),
      the spec units it verifies, and the files it inspects (`checks!/1`, §11.4)
    * `:spec_classes` — the spec's classes of text that asserts nothing, each
      `{name, reason}` or `{name, reason, files: globs, headings: regex, marker: regex}`
      (`spec_classes!/2`, §11.7)
    * `:issues` — how to ask the project's tracker for an issue's state, so a deferral
      goes stale when its issue closes: `[command: argv, state: key, project: name]`
      (`issues!/1`, `Surfex.Issues`, §13.7)
    * `:not_claims` — the lines of a section's or block's own text that aren't claims, as
      regexes matched against each line (`not_claims!/1`, §13.12):
      `[~r/^Legacy reference: \S+$/]` leaves provenance lines out of what verification and
      completeness read, while versions still cover them
    * `:namespace` — the Elixir scanner's root module, when it isn't the app's: a string,
      a module, or a list of them (`namespace!/1`)

  Every key is validated before anything is scanned (`validate!/1`, §13.14): a refusal
  names the key, the value as written and the form the key takes, and every refusal of a
  config is raised at once.
  """

  alias Surfex.Scan
  alias Surfex.Status.Config.Keys

  @typedoc "A declared check (`checks!/1`, §11.4)."
  @type check :: %{
          id: String.t(),
          run: String.t() | [String.t()],
          verifies: [String.t()],
          inputs: [String.t()]
        }

  # The keys a `.surfex.exs` may hold, besides the profile's (`Surfex.Profile.keys/0`).
  @own [
    :heading_ids,
    :rule_ids,
    :unit_refs,
    :fold_paths,
    :scanner,
    :scanner_opts,
    :scanners,
    :namespace,
    :goldens,
    :require,
    :tests,
    :declares,
    :triangle,
    :require_red,
    :router,
    :dispatch,
    :claim_implements,
    :spec_classes,
    :issues,
    :not_claims,
    :checks,
    :adoption,
    :process,
    :completeness
  ]

  # The v0.2 trace's own keys, removed with it in 0.4.0.
  @removed [
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
    :require_citation,
    :file_labels
  ]

  @doc """
  The keys a `.surfex.exs` may hold: the log's own and the profile's
  (`Surfex.Profile.keys/0`). Each has a validator (§13.14).
  """
  @spec keys() :: [atom]
  def keys, do: @own ++ Surfex.Profile.keys()

  @doc """
  Reads and validates a `.surfex.exs`: it must evaluate to a keyword list of known keys,
  each in its accepted form (`validate!/1`). `claim_grain:`, the transitional switch claim
  grain shipped behind, is refused, saying claim grain is now the only reading (§13.2); a
  key of the removed v0.2 trace is refused saying so; any other unknown key is refused
  naming it. Every refusal is raised at once, one per line (§13.14). Every task reads its
  config through this, so a misspelt key is never ignored.
  """
  @spec read!(String.t()) :: keyword
  def read!(path) do
    config = Surfex.Gate.config!(path)

    claim_grain =
      if Keyword.has_key?(config, :claim_grain),
        do: [
          "claim_grain: is no longer a key: claim grain is now the only reading " <>
            "(spec §13.2). Delete the key; the CHANGELOG's upgrade step says what changes, " <>
            "and `mix surfex.migrate --report` lists the sections to move to claims"
        ],
        else: []

    unknown =
      case Keyword.keys(config) -- [:claim_grain | keys()] do
        [] ->
          []

        unknown ->
          case Enum.split_with(unknown, &(&1 in @removed)) do
            {[], unknown} ->
              ["unknown keys #{inspect(unknown)}"]

            {removed, unknown} ->
              [
                "#{inspect(removed)} belonged to the v0.2 trace, removed in 0.4.0; " <>
                  "delete them (the relation log needs only sources:, the reading keys and its own)"
              ] ++ if(unknown == [], do: [], else: ["unknown keys #{inspect(unknown)}"])
          end
      end

    case claim_grain ++ unknown ++ Keys.refusals(config) do
      [] -> config
      refusals -> raise ArgumentError, refused(path <> ": ", refusals)
    end
  end

  @doc """
  Validates every key of `config` against its accepted form (§13.14), before anything is
  scanned, and gives the config. Every refusal is raised at once, in one `ArgumentError`,
  one per line: the key, the value as written and the form it takes. A key no
  `.surfex.exs` may hold is `read!/1`'s to refuse, and left alone here.
  """
  @spec validate!(keyword) :: keyword
  def validate!(config) do
    case Keys.refusals(config) do
      [] -> config
      refusals -> raise ArgumentError, refused("", refusals)
    end
  end

  defp refused(prefix, [one]), do: prefix <> one

  defp refused(prefix, refusals),
    do: "#{prefix}#{length(refusals)} refusals:\n" <> Enum.map_join(refusals, "\n", &("  " <> &1))

  @doc """
  The items the code scanners find under `root`, combined (§5.3): each of `scanners!/1`
  with its options, the built-in Elixir scanner for `:elixir`. Each item is as its
  scanner gave it. Two scanners giving one key raise, naming both and the key: a key is
  an item's identity, and two scanners can't both own it.
  """
  @spec items(keyword, String.t()) :: [Surfex.Item.t()]
  def items(config, root) do
    scanners = config |> validate!() |> scanners!()
    asked = project_scanners(scanners)

    dispatch = dispatch!(config)

    if dispatch != [] and not elixir_scanner?(config),
      do:
        raise(
          ArgumentError,
          "dispatch: is read by the Elixir scanner, which isn't among scanners:"
        )

    found =
      for {scanner, opts} <- scanners do
        case scanner do
          :elixir ->
            {scanner,
             Surfex.Scanner.Elixir.items(root, opts ++ [call_scanners: asked, dispatch: dispatch])}

          module ->
            {scanner, module!(module).items(root, opts)}
        end
      end

    found
    |> Enum.flat_map(fn {scanner, items} ->
      for key <- items |> Enum.map(&Surfex.Item.key/1) |> Enum.uniq(), do: {key, scanner}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.find(fn {_key, scanners} -> length(scanners) > 1 end)
    |> case do
      nil ->
        Enum.flat_map(found, &elem(&1, 1))

      {key, [first, second | _]} ->
        raise ArgumentError,
              "scanners #{inspect(first)} and #{inspect(second)} both give the key #{inspect(key)}"
    end
  end

  @doc """
  The routes a test's requests resolve through (§11, `Surfex.SourceScan.Routes`): those
  of the routers `router:` names, or, without it, of each router an endpoint in the
  project plugs (`use Phoenix.Endpoint`, then `plug MyAppWeb.Router`). Read from the
  Elixir scanner's source (its `:paths`), never compiled. None when `router: false`, or
  when the Elixir scanner isn't among the scanners and no router is named. A named router
  that the source doesn't define raises, as does a `router:` of any other shape.
  """
  @spec routes(keyword, String.t()) :: [Surfex.SourceScan.Routes.route()]
  def routes(config, root) do
    paths =
      case List.keyfind(scanners!(config), :elixir, 0) do
        {:elixir, opts} -> Keyword.get(opts, :paths, ["lib/**/*.ex"])
        nil -> ["lib/**/*.ex"]
      end

    Keys.check!(config, :router)

    case Keyword.get(config, :router) do
      false ->
        []

      nil ->
        if elixir_scanner?(config),
          do: Surfex.SourceScan.Routes.read(router_files(root, paths, []), :discover),
          else: []

      named ->
        names = router_names!(named)
        Surfex.SourceScan.Routes.read(router_files(root, paths, names), names)
    end
  end

  defp router_names!(named), do: named |> List.wrap() |> Enum.map(&inspect/1)

  # The source files that may hold an endpoint or a router, parsed: only those that say
  # so, so the rest of the code is never read twice.
  defp router_files(root, paths, names) do
    marks = ["Phoenix.Endpoint", "Phoenix.Router", ":router" | names]

    for glob <- paths,
        file <- Path.wildcard(Path.join(root, glob)),
        text = File.read!(file),
        Enum.any?(marks, &String.contains?(text, &1)),
        uniq: true,
        do: {file, Code.string_to_quoted!(text, file: file)}
  end

  @doc """
  The `not_claims:` patterns (§13.12), regexes matched against each line of a section's or
  marked block's own text, in order. `[]` without the key. Anything but a list of regexes
  raises.
  """
  @spec not_claims!(keyword) :: [Regex.t()]
  def not_claims!(config) do
    Keys.check!(config, :not_claims)
    Keyword.get(config, :not_claims, [])
  end

  @doc """
  The declared dispatch functions (§11.10), `dispatch: [{Module, :fun, arity}]`, as call
  ids (`Module.fun/arity`), sorted. None without the key. Anything but a list of such
  triples raises.
  """
  @spec dispatch!(keyword) :: [String.t()]
  def dispatch!(config) do
    Keys.check!(config, :dispatch)

    Keyword.get(config, :dispatch, [])
    |> Enum.map(fn {m, f, a} -> Surfex.SourceScan.Calls.call(inspect(m), f, a) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The project's scanners (`scanners!/1`) other than the built-in one, each with its
  options: those `Surfex.Scanner.c:calls/3` may be asked of (§5.4). Each is checked to
  implement `Surfex.Scanner`.
  """
  @spec call_scanners(keyword) :: [{module, keyword}]
  def call_scanners(config), do: config |> scanners!() |> project_scanners()

  defp project_scanners(scanners),
    do: for({scanner, opts} <- scanners, scanner != :elixir, do: {module!(scanner), opts})

  defp module!(scanner) do
    unless Code.ensure_loaded?(scanner) and function_exported?(scanner, :items, 2),
      do: raise(ArgumentError, "scanner #{inspect(scanner)} does not implement Surfex.Scanner")

    scanner
  end

  @doc """
  The code scanners (§5.3), each with its options: `scanners:`, or `scanner:` with
  `scanner_opts:` as one, else `[{:elixir, []}]`. A scanner is `:elixir`, a module, or
  `{scanner, opts}`. Giving both `scanner:` and `scanners:` raises, as does a list that is
  empty or holds anything else, or one naming a scanner twice.
  """
  @spec scanners!(keyword) :: [{:elixir | module, keyword}]
  def scanners!(config) do
    Enum.each([:scanners, :scanner, :scanner_opts], &Keys.check!(config, &1))

    case {Keyword.fetch(config, :scanners), Keyword.fetch(config, :scanner)} do
      {{:ok, list}, :error} -> Enum.map(list, &scanner_entry/1)
      {:error, {:ok, scanner}} -> [{scanner, Keyword.get(config, :scanner_opts, [])}]
      {:error, :error} -> [{:elixir, Keyword.get(config, :scanner_opts, [])}]
    end
  end

  defp scanner_entry({scanner, opts}), do: {scanner, opts}
  defp scanner_entry(scanner), do: {scanner, []}

  @doc """
  Whether any of the code scanners is the project's own (`scanners!/1`): its module is
  project code, so a task reading the code compiles the project first.
  """
  @spec project_scanner?(keyword) :: boolean
  def project_scanner?(config), do: Enum.any?(scanners!(config), &(elem(&1, 0) != :elixir))

  @doc "Whether the built-in Elixir scanner is among the code scanners (`scanners!/1`)."
  @spec elixir_scanner?(keyword) :: boolean
  def elixir_scanner?(config), do: Enum.any?(scanners!(config), &(elem(&1, 0) == :elixir))

  @doc """
  The options `Surfex.Status.derive/4` takes from `.surfex.exs`: `triangle:`, validated,
  the classes' coverage and the `not_claims:` patterns. Raises `ArgumentError` naming
  what is wrong.
  """
  @spec options!(keyword) :: keyword
  def options!(config) do
    Keys.check!(config, :triangle)
    triangle = Keyword.get(config, :triangle, :report)

    coverage =
      if Keyword.has_key?(config, :classes),
        do: [coverage: Surfex.Profile.coverage!(config)],
        else: []

    not_claims =
      case not_claims!(config) do
        [] -> []
        patterns -> [not_claims: Enum.map(patterns, &inspect/1)]
      end

    [triangle: triangle] ++ coverage ++ not_claims
  end

  @doc "The `require_red:` policy (`false` by default), validated."
  @spec require_red!(keyword) :: boolean
  def require_red!(config) do
    Keys.check!(config, :require_red)
    Keyword.get(config, :require_red, false)
  end

  @doc """
  The `process:` hand-off (§19), validated: `:print` (the default) or `{:command, argv}`
  with a non-empty list of strings.
  """
  @spec process!(keyword) :: :print | {:command, [String.t()]}
  def process!(config) do
    Keys.check!(config, :process)
    Keyword.get(config, :process, :print)
  end

  @doc """
  The status of the project at `root` under `config`, as `mix surfex.status` derives it:
  the scans, the log, the `require:` policy and the options, plus `extra` options. For the
  tasks that need the whole status, so each derives it the same way. An `issues:` given
  as a function is asked, once, for the states of the references the scanned spec's
  deferrals name, and derive gets its answer (§13.7).
  """
  @spec status(keyword, String.t(), String.t(), keyword) :: Surfex.Status.t()
  def status(config, root, namespace, extra),
    do: config |> read_status(root, namespace, extra) |> ok!()

  @doc """
  The status `status/4` derives, as `{:ok, status}`, or `{:error, errors}` when the spec or
  the tests have scan errors (§11.11): every one, sorted by file and line, and no status.
  """
  @spec read_status(keyword, String.t(), String.t(), keyword) ::
          {:ok, Surfex.Status.t()} | {:error, [Scan.Errors.error()]}
  def read_status(config, root, namespace, extra) do
    with {:ok, {scans, options}} <- read(config, root, namespace),
         do: {:ok, derive(config, root, scans, options, extra)}
  end

  defp derive(config, root, scans, options, extra) do
    entries = if File.dir?(Surfex.Log.dir(root)), do: Surfex.Log.load(root), else: []
    adoption = [adoption: adoption!(config, root)]

    extra =
      case Keyword.fetch(extra, :issues) do
        {:ok, ask} when is_function(ask, 1) ->
          # Only issue deferrals: one citing a spec unit has no tracker to ask (§13.13).
          refs =
            for %Scan{kind: :spec, deferred: %{ref: ref} = d} <- scans,
                not Map.has_key?(d, :cites),
                uniq: true,
                do: ref

          Keyword.put(extra, :issues, ask.(refs))

        _ ->
          extra
      end

    Surfex.Status.derive(scans, entries, require!(config), extra ++ adoption ++ options)
  end

  @doc """
  The `completeness: [min: N]` floor (§20), a number from 0 to 100, or `nil` with no key.
  Raises on anything else.
  """
  @spec completeness!(keyword) :: number | nil
  def completeness!(config) do
    Keys.check!(config, :completeness)

    case Keyword.fetch(config, :completeness) do
      :error -> nil
      {:ok, [min: min]} -> min
    end
  end

  @doc """
  The `adoption:` setting (§18.1), validated against the test files under `root`:
  `:reevaluate` (the default), `:trust`, or `[trust: globs, reevaluate: globs]`, whose globs
  lie within `tests:` and don't overlap. Gives the setting and the trusted test files
  (`:all` under `:trust`).
  """
  @spec adoption!(keyword, String.t()) :: %{setting: term, trusted: :all | MapSet.t(String.t())}
  def adoption!(config, root) do
    Keys.check!(config, :adoption)

    case Keyword.get(config, :adoption, :reevaluate) do
      :reevaluate ->
        %{setting: :reevaluate, trusted: MapSet.new()}

      :trust ->
        %{setting: :trust, trusted: :all}

      setting ->
        files = &files(root, Keyword.get(setting, &1, []))
        {trusted, reevaluated} = {files.(:trust), files.(:reevaluate)}
        tests = files(root, Keyword.get(config, :tests, []))

        case MapSet.difference(MapSet.union(trusted, reevaluated), tests) |> Enum.sort() do
          [] ->
            :ok

          outside ->
            raise ArgumentError, "adoption: globs match files outside tests: #{inspect(outside)}"
        end

        case MapSet.intersection(trusted, reevaluated) |> Enum.sort() do
          [] ->
            :ok

          both ->
            raise ArgumentError,
                  "adoption: trust and reevaluate globs overlap on #{inspect(both)}"
        end

        %{setting: setting, trusted: trusted}
    end
  end

  defp files(root, globs) do
    for glob <- globs,
        file <- Path.wildcard(Path.join(root, glob)),
        into: MapSet.new(),
        do: Path.relative_to(file, root)
  end

  @doc "Whether a test file is trusted under an adoption setting (`adoption!/2`)."
  @spec trusted?(%{trusted: :all | MapSet.t(String.t())}, String.t()) :: boolean
  def trusted?(%{trusted: :all}, _file), do: true
  def trusted?(%{trusted: trusted}, file), do: MapSet.member?(trusted, file)

  @doc "The `require:` policy, validated. Raises `ArgumentError` naming what is wrong."
  @spec require!(keyword) :: keyword
  def require!(config) do
    Keys.check!(config, :require)
    Keyword.get(config, :require, [])
  end

  @doc """
  Every scan record under `root`: each markdown section of the `sources`, and each item
  the code scanner finds. Raises when `sources` is missing or matches nothing, since a
  status over no spec would report every relation orphaned without saying why. Scan
  errors in the spec or the tests raise `Surfex.Scan.Errors` once, naming every one
  (§11.11).
  """
  @spec scans(keyword, String.t()) :: [Scan.t()]
  def scans(config, root) do
    case scans(config, root, items(config, root)) do
      {scans, []} -> scans
      {_scans, errors} -> raise Scan.Errors, errors: errors
    end
  end

  # A tagged result's value, or its scan errors raised once.
  defp ok!({:ok, value}), do: value
  defp ok!({:error, errors}), do: raise(Scan.Errors, errors: errors)

  @doc """
  Everything `Surfex.Status.derive/4` needs, scanning the code once: the scans, and the
  options (`options!/1`'s, plus the spec's broken citations, `broken_citations/3`, and the
  `verifies` tags that verify nothing, `Surfex.Scan.ExUnit.inert/2`).
  `namespace` is the Elixir scanner's root module when the config doesn't name one.
  Scan errors raise `Surfex.Scan.Errors` once (`read/3`).
  """
  @spec load(keyword, String.t(), String.t() | nil) :: {[Scan.t()], keyword}
  def load(config, root, namespace), do: config |> read(root, namespace) |> ok!()

  @doc """
  What `load/3` gives, as `{:ok, {scans, options}}`, or `{:error, errors}`: every scan
  error in the spec and the tests (§11.11), sorted by file and line.
  """
  @spec read(keyword, String.t(), String.t() | nil) ::
          {:ok, {[Scan.t()], keyword}} | {:error, [Scan.Errors.error()]}
  def read(config, root, namespace) do
    items = items(config, root)

    case scans(config, root, items) do
      {scans, []} ->
        inert =
          case Keyword.get(config, :tests) do
            nil -> []
            globs -> Scan.ExUnit.inert(root, globs, declares!(config))
          end

        {broken, all} = read_citations(config, items, root, namespace, scans)

        {:ok,
         {arity_warned(scans, Surfex.Cite.Contracts.arities(all, scans)),
          options!(config) ++ [citations: broken, inert: inert]}}

      {_scans, errors} ->
        {:error, errors}
    end
  end

  @doc """
  The spec side alone (§13.16), as `mix surfex.status --spec` reads it: the config
  validated (`validate!/1`), then the spec scanned under `sources:` and nothing else (no
  code scanner, test, check, class or log is read). As `{:ok, status}`, the status derived
  over the spec's units alone, its spec-shape warnings including each citation of an arity
  the spec's own contracts don't state (§13.15); or `{:error, errors}`, the spec's scan
  errors (§11.11), sorted by file and line. The citations are read with no code, so none
  is broken and the contracts are not checked against code (§6.9).
  """
  @spec read_spec(keyword, String.t(), String.t() | nil) ::
          {:ok, Surfex.Status.t()} | {:error, [Scan.Errors.error()]}
  def read_spec(config, root, namespace) do
    config = validate!(config)

    case spec_scans(config, root, []) do
      {spec, []} ->
        all = Surfex.Cite.citations([], profile!(config, namespace, []), root)
        scans = arity_warned(spec, Surfex.Cite.Contracts.arities(all, spec))
        {:ok, Surfex.Status.derive(scans, [], [], options!(config))}

      {_spec, errors} ->
        {:error, Scan.Errors.sorted(errors)}
    end
  end

  @doc """
  The spec's citations that resolve to nothing (`:unresolved`) or to more than one item
  (`:ambiguous`), read with `Surfex.Cite` under the config's profile (`profile!/2`). A
  name the profile declares external, or a documented absence, is not broken, nor is a
  process name the Elixir scanner's source registers (§6.7). The contract units among
  `scans` are citations too, each of its own function (§6.9), sorted in among them.
  """
  @spec broken_citations(keyword, [Surfex.Item.t()], String.t(), String.t() | nil, [Scan.t()]) ::
          [Surfex.Cite.t()]
  def broken_citations(config, items, root, namespace, scans \\ []),
    do: config |> read_citations(items, root, namespace, scans) |> elem(0)

  # The broken citations, and every citation of the spec's text (not the contracts' own).
  defp read_citations(config, items, root, namespace, scans) do
    profile = profile!(config, namespace, items)
    all = Surfex.Cite.citations(items, profile, root, registered: registered_names(config, root))

    broken =
      all
      |> Enum.concat(Surfex.Cite.Contracts.citations(scans, items, profile))
      |> Enum.filter(&(&1.status in [:unresolved, :ambiguous]))
      |> Enum.sort_by(&{&1.file, &1.line, &1.span})

    {broken, all}
  end

  # Each citation of an arity no contract states (§13.15) is a spec-shape warning (§11.12)
  # on the innermost spec unit holding its line.
  defp arity_warned(scans, []), do: scans

  defp arity_warned(scans, arities) do
    spec = Enum.filter(scans, &(&1.kind == :spec))

    by_unit =
      Enum.group_by(
        arities,
        fn %{citation: c} -> Surfex.Scan.at(spec, c.file, c.line).id end,
        fn %{citation: c} = a ->
          %{kind: :contract_arity, line: c.line, message: Surfex.Cite.Contracts.arity_text(a)}
        end
      )

    for scan <- scans do
      case Map.fetch(by_unit, scan.id) do
        {:ok, warnings} when scan.kind == :spec ->
          %{scan | warnings: Enum.sort_by(scan.warnings ++ warnings, & &1.line)}

        _ ->
          scan
      end
    end
  end

  # The process names the Elixir scanner's source registers (its `:paths`); none without
  # the Elixir scanner.
  defp registered_names(config, root) do
    case List.keyfind(scanners!(config), :elixir, 0) do
      {:elixir, opts} ->
        Surfex.SourceScan.Registered.names(root, Keyword.get(opts, :paths, ["lib/**/*.ex"]))

      nil ->
        []
    end
  end

  @doc """
  The citation-reading profile of a config: its profile keys (`Surfex.Profile.keys/0`),
  over the Elixir scanner's defaults for its roots: its namespace (`namespace:` in the
  config, else the one given), and every top-level module the scanned `items` define (a
  module whose name has no dot), when the Elixir scanner is among the code scanners.
  Without it, a project scanner's config gives its own `shape:`.
  """
  @spec profile!(keyword, String.t() | nil, [Surfex.Item.t()]) :: Surfex.Profile.t()
  def profile!(config, namespace, items \\ []) do
    defaults =
      if elixir_scanner?(config) do
        ns =
          namespace!(config) || namespace ||
            raise(ArgumentError, "reading citations needs namespace: for the Elixir scanner")

        roots =
          for %Surfex.Item{kind: :module, name: name} <- items,
              not String.contains?(name, "."),
              do: name

        Surfex.Scanner.Elixir.profile_defaults(List.wrap(ns) ++ roots)
      else
        []
      end

    Surfex.Profile.new!(Keyword.merge(defaults, Keyword.take(config, Surfex.Profile.keys())))
  end

  @doc """
  The config's `namespace:` (§13.14) as root module names, or `nil` without the key: a
  string as written, a module by its name (`MyApp` reads as `"MyApp"`), and a list of
  either as each. Anything else is refused.
  """
  @spec namespace!(keyword) :: [String.t()] | nil
  def namespace!(config) do
    Keys.check!(config, :namespace)

    case Keyword.fetch(config, :namespace) do
      {:ok, ns} -> ns |> List.wrap() |> Enum.map(&root_name/1)
      :error -> nil
    end
  end

  defp root_name(name) when is_binary(name), do: name
  defp root_name(module), do: inspect(module)

  @doc """
  The project's checks (`checks:`, §11.4), validated (§13.14): each
  `%{id, run, verifies, inputs}`, `run` a command string or an argv, `verifies` a list.
  `[]` without the key. Anything else is refused, naming it.
  """
  @spec checks!(keyword) :: [check]
  def checks!(config) do
    Keys.check!(config, :checks)

    for check <- Keyword.get(config, :checks, []) do
      %{
        id: Keyword.fetch!(check, :id),
        run: Keyword.fetch!(check, :run),
        verifies: check |> Keyword.fetch!(:verifies) |> List.wrap(),
        inputs: Keyword.get(check, :inputs, [])
      }
    end
  end

  defp scans(config, root, items) do
    {spec, spec_errors} = spec_scans(config, root, items)

    code = Scan.code(items)
    checks = config |> checks!() |> Scan.Checks.records(root)
    {tests, test_errors} = tests(config, root, code)
    unit_refs = unit_refs!(config)
    declaring = (tests ++ checks) |> rows(spec, unit_refs) |> declared(spec, unit_refs)

    {spec ++ code ++ declaring ++ classes(config), Scan.Errors.sorted(spec_errors ++ test_errors)}
  end

  # The spec's units under `sources:` and their scan errors, each heading's function names
  # read against `items` (none for the spec alone, §13.16).
  defp spec_scans(config, root, items) do
    sources =
      Keyword.get(config, :sources) ||
        raise(ArgumentError, ".surfex.exs needs sources: (the spec's globs)")

    exclude = Keyword.get(config, :exclude, [])

    {spec, spec_errors} =
      Scan.Markdown.read_files(root, sources, exclude,
        heading_ids: Keyword.get(config, :heading_ids),
        rule_ids: Keyword.get(config, :rule_ids),
        subjects: Keyword.get(config, :subjects, []),
        fold_paths: fold_paths!(config),
        spec_classes: spec_classes!(config, Scan.Markdown.files(root, sources, exclude)),
        not_claims: not_claims!(config),
        unit_refs: unit_refs!(config),
        code: Surfex.Cite.Contracts.code(items, rewrites(config))
      )

    if spec == [] and spec_errors == [],
      do: raise(ArgumentError, "no spec sections found in #{inspect(sources)} under #{root}")

    {spec, spec_errors}
  end

  # The profile's `normalise:` rewrites, as profile!/3 gives them, without needing the
  # namespace: the config's, else the Elixir scanner's defaults when it is a code scanner.
  defp rewrites(config) do
    cond do
      Keyword.has_key?(config, :normalise) ->
        Keyword.fetch!(config, :normalise)

      elixir_scanner?(config) ->
        Keyword.fetch!(Surfex.Scanner.Elixir.profile_defaults([]), :normalise)

      true ->
        []
    end
  end

  # A test or a check may verify every row of a marked table at once, `TABLE/*` (§11.16),
  # whatever form declares it (`verifies:`, a `declares:` form, a check's `verifies`) and
  # with or without `unit_refs:`: the declaration is each row's, so a row added to the
  # table is declared with no edit to the tag. A reference whose table isn't one is left
  # as written, so it is reported broken.
  defp rows([], _spec, _unit_refs), do: []

  defp rows(records, spec, unit_refs) do
    resolver = Scan.resolver(spec, unit_refs)
    by_table = spec |> Enum.filter(&(&1.role == :row)) |> Enum.group_by(& &1.within)

    for record <- records do
      declares =
        Enum.flat_map(record.declares, fn {type, ref} = declared ->
          with true <- String.ends_with?(ref, "/*"),
               {:ok, %Scan{role: :table, id: table}} <-
                 Scan.resolve(resolver, String.replace_suffix(ref, "/*", "")) do
            by_table |> Map.get(table, []) |> Enum.map(&{type, &1.id}) |> Enum.sort()
          else
            _ -> [declared]
          end
        end)

      %{record | declares: Enum.uniq(declares)}
    end
  end

  @doc """
  The project's own declaration forms (`declares:`, §11.6), each as
  `%{kind: :tag | :attribute, name: atom, strip: Regex.t() | nil}`; `[]` without the key.
  `declares: [verifies: [form, …]]`, each form `{:tag, KEY}` (an ExUnit tag key, read at
  `@tag`, `@describetag` and `@moduletag` as `verifies:` is) or `{:attribute, NAME}` (a
  module attribute before a test, applying to it as a `@tag` does), optionally with
  `strip: REGEX` as a third element's option, removed from each id. Anything else is
  refused, naming it: a form misread would silently declare nothing.
  """
  @spec declares!(keyword) :: [%{kind: :tag | :attribute, name: atom, strip: Regex.t() | nil}]
  def declares!(config) do
    Keys.check!(config, :declares)

    case Keyword.get(config, :declares, []) do
      [] -> []
      [verifies: forms] -> Enum.map(forms, &declared_form/1)
    end
  end

  defp declared_form({kind, name}), do: declared_form({kind, name, []})
  defp declared_form({kind, name, []}), do: %{kind: kind, name: name, strip: nil}
  defp declared_form({kind, name, [strip: strip]}), do: %{kind: kind, name: name, strip: strip}

  @doc """
  Whether `mix surfex.suggest` proposes a claim's `implements` from what its verifying
  tests call (`claim_implements:`, §15.1): `false` by default; anything but a boolean is
  refused.
  """
  @spec claim_implements?(keyword) :: boolean
  def claim_implements?(config) do
    Keys.check!(config, :claim_implements)
    Keyword.get(config, :claim_implements, false)
  end

  @doc """
  The spec's classes (`spec_classes:`, §11.7), each as
  `%{name, reason, files, headings, marker}`, `[]` without the key. A class is
  `{name, reason}`, or `{name, reason, opts}` with `files:` (globs relative to the root,
  checked against the spec's `files`), `headings:` (a regex over a heading's text) and
  `marker:` (a regex over an own-line comment's inner text). A name is letters, digits,
  `-` and `_`, and its reason isn't empty. Refused, naming it: a malformed class, an option
  other than these, one name with two reasons, and a glob matching none of `files`: a
  misspelt pattern would otherwise class nothing in silence.
  """
  @spec spec_classes!(keyword, [String.t()]) :: [
          %{
            name: String.t(),
            reason: String.t(),
            files: [String.t()] | nil,
            headings: Regex.t() | nil,
            marker: Regex.t() | nil
          }
        ]
  def spec_classes!(config, files) do
    Keys.check!(config, :spec_classes)
    config |> Keyword.get(:spec_classes, []) |> Enum.map(&spec_class!(&1, files))
  end

  defp spec_class!({name, reason}, files), do: spec_class!({name, reason, []}, files)

  defp spec_class!({name, reason, opts}, files) do
    # An atom names the class its string does (`:informative` is `"informative"`).
    name = to_string(name)
    globs = Keyword.get(opts, :files)

    for glob <- globs || [],
        not Enum.any?(files, &Scan.Markdown.glob_match?(glob, &1)),
        do:
          raise(
            ArgumentError,
            "spec_classes: class #{name}'s files: #{inspect(glob)} matches no spec file"
          )

    %{
      name: name,
      reason: reason,
      files: globs,
      headings: Keyword.get(opts, :headings),
      marker: Keyword.get(opts, :marker)
    }
  end

  @doc """
  The tracker resolver (`issues:`, §13.7) as `Surfex.Issues` takes it, or `nil` without
  the key: `command:`, a non-empty list of strings run with no shell, with `{ref}`, `{n}`
  and `{project}` substituted; `state:`, the JSON key holding the state when the output
  is JSON; `project:`, the project of a bare `#123`. Anything else is refused, naming it.
  """
  @spec issues!(keyword) :: Surfex.Issues.resolver() | nil
  def issues!(config) do
    Keys.check!(config, :issues)

    case Keyword.fetch(config, :issues) do
      :error ->
        nil

      {:ok, opts} ->
        %{
          command: Keyword.fetch!(opts, :command),
          state: Keyword.get(opts, :state),
          project: Keyword.get(opts, :project)
        }
    end
  end

  # `fold_paths:` is a boolean; anything else is refused, not read as false. Without it,
  # path headings fold wherever the spec writes ids (`heading_ids:`), and not otherwise
  # (§11.1).
  defp fold_paths!(config) do
    Keys.check!(config, :fold_paths)
    Keyword.get(config, :fold_paths, Keyword.get(config, :heading_ids) != nil)
  end

  @doc """
  The project's `unit_refs:` (`Surfex.Scan.Resolver.unit_refs!/1`), `[]` when it has none.
  """
  @spec unit_refs!(keyword) :: [Regex.t()]
  def unit_refs!(config) do
    Keys.check!(config, :unit_refs)
    Keyword.get(config, :unit_refs, [])
  end

  # A test's declaration in the project's own citation form names the unit by its full id,
  # so everything reading declarations resolves it as it would the id (§11.1).
  defp declared(tests, _spec, []), do: tests

  defp declared(tests, spec, unit_refs) do
    resolver = Scan.resolver(spec, unit_refs)

    for test <- tests do
      declares =
        for {type, ref} <- test.declares do
          case Scan.Resolver.form(resolver, ref) do
            {:ok, unit} -> {type, unit.id}
            _ -> {type, ref}
          end
        end

      %{test | declares: declares}
    end
  end

  # Classes (`classes:` and `rules:`, the profile's keys) are scanned when a project has
  # any: each is a record excusals relate to (`Surfex.Scan.Classes`).
  defp classes(config),
    do: if(Keyword.has_key?(config, :classes), do: Scan.Classes.records(config), else: [])

  # No `tests:` means no test scanning. Globs that match nothing raise, as `sources:` do: a
  # misspelt glob would otherwise report every test relation orphaned. The code says what a
  # test's imported modules define (`Surfex.Scan.ExUnit.tests/3`).
  defp tests(config, root, code) do
    case Keyword.get(config, :tests) do
      nil ->
        {[], []}

      globs ->
        files = Enum.flat_map(globs, &Path.wildcard(Path.join(root, &1)))

        if files == [],
          do: raise(ArgumentError, "tests: #{inspect(globs)} matches no file under #{root}")

        Scan.ExUnit.read_files(
          root,
          globs,
          code,
          call_scanners(config),
          routes(config, root),
          declares!(config)
        )
    end
  end
end
