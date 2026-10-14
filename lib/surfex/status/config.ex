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
      that unit rather than a unit of its own (§11.1); `false` by default until 0.8
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
    * `:checks` — gates that verify claims: each `[id:, run:, verifies:, inputs:]`, a
      command that can fail, the spec units it verifies, and the files it inspects
      (`Surfex.Scan.Checks`, §11.4)
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @roles [:section, :block, :test_hint, :table, :row, :rule, :contract]

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
    :triangle,
    :require_red,
    :router,
    :claim_implements,
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
  Reads and validates a `.surfex.exs`: it must evaluate to a keyword list of known keys.
  A key of the removed v0.2 trace raises saying so; any other unknown key raises naming
  it. Every task reads its config through this, so a misspelt key is never ignored.
  """
  @spec read!(String.t()) :: keyword
  def read!(path) do
    config = Surfex.Gate.config!(path)

    case Keyword.keys(config) -- (@own ++ Surfex.Profile.keys()) do
      [] ->
        config

      unknown ->
        case Enum.filter(unknown, &(&1 in @removed)) do
          [] ->
            raise ArgumentError, "#{path}: unknown keys #{inspect(unknown)}"

          removed ->
            raise ArgumentError,
                  "#{path}: #{inspect(removed)} belonged to the v0.2 trace, removed in 0.4.0; " <>
                    "delete them (the relation log needs only sources:, the reading keys and its own)"
        end
    end
  end

  @doc """
  The items the code scanners find under `root`, combined (§5.3): each of `scanners!/1`
  with its options, the built-in Elixir scanner for `:elixir`. Each item is as its
  scanner gave it. Two scanners giving one key raise, naming both and the key: a key is
  an item's identity, and two scanners can't both own it.
  """
  @spec items(keyword, String.t()) :: [Surfex.Item.t()]
  def items(config, root) do
    scanners = scanners!(config)
    asked = project_scanners(scanners)

    found =
      for {scanner, opts} <- scanners do
        case scanner do
          :elixir -> {scanner, Surfex.Scanner.Elixir.items(root, opts ++ [call_scanners: asked])}
          module -> {scanner, module!(module).items(root, opts)}
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

  defp router_names!(named) do
    list = List.wrap(named)

    if list != [] and Enum.all?(list, &(is_atom(&1) and &1 not in [nil, true, false])),
      do: Enum.map(list, &inspect/1),
      else:
        raise(
          ArgumentError,
          "router: must be a module, a list of modules, or false, got #{inspect(named)}"
        )
  end

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
    scanners =
      case {Keyword.fetch(config, :scanners), Keyword.fetch(config, :scanner)} do
        {{:ok, _}, {:ok, _}} ->
          raise ArgumentError, "scanners: and scanner: are one setting; give only scanners:"

        {{:ok, [_ | _] = list}, :error} ->
          if Keyword.has_key?(config, :scanner_opts),
            do:
              raise(
                ArgumentError,
                "scanner_opts: belongs to scanner:; with scanners: give {scanner, opts}"
              )

          Enum.map(list, &scanner_entry!/1)

        {{:ok, other}, :error} ->
          bad_scanners(other)

        {:error, {:ok, scanner}} ->
          [scanner_entry!({scanner, Keyword.get(config, :scanner_opts, [])})]

        {:error, :error} ->
          [{:elixir, Keyword.get(config, :scanner_opts, [])}]
      end

    case scanners |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.filter(&(elem(&1, 1) > 1)) do
      [] -> scanners
      [{twice, _} | _] -> raise ArgumentError, "scanners: names #{inspect(twice)} twice"
    end
  end

  defp scanner_entry!({scanner, opts}) when is_atom(scanner) and is_list(opts) do
    if Keyword.keyword?(opts), do: {scanner, opts}, else: bad_scanners({scanner, opts})
  end

  defp scanner_entry!(scanner)
       when is_atom(scanner) and not is_nil(scanner) and not is_boolean(scanner),
       do: {scanner, []}

  defp scanner_entry!(other), do: bad_scanners(other)

  defp bad_scanners(value),
    do:
      raise(
        ArgumentError,
        "scanners: must be a non-empty list of :elixir, a module or {scanner, opts}, got #{inspect(value)}"
      )

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
  The options `Surfex.Status.derive/4` takes from `.surfex.exs`: `triangle:`, validated.
  Raises `ArgumentError` naming what is wrong.
  """
  @spec options!(keyword) :: keyword
  def options!(config) do
    triangle = Keyword.get(config, :triangle, :report)

    unless triangle in [:report, :fail],
      do: raise(ArgumentError, "triangle: must be :report or :fail, got #{inspect(triangle)}")

    coverage =
      if Keyword.has_key?(config, :classes),
        do: [coverage: Surfex.Profile.coverage!(config)],
        else: []

    [triangle: triangle] ++ coverage
  end

  @doc "The `require_red:` policy (`false` by default), validated."
  @spec require_red!(keyword) :: boolean
  def require_red!(config) do
    case Keyword.get(config, :require_red, false) do
      flag when is_boolean(flag) -> flag
      other -> raise ArgumentError, "require_red: must be true or false, got #{inspect(other)}"
    end
  end

  @doc """
  The `process:` hand-off (§19), validated: `:print` (the default) or `{:command, argv}`
  with a non-empty list of strings.
  """
  @spec process!(keyword) :: :print | {:command, [String.t()]}
  def process!(config) do
    case Keyword.get(config, :process, :print) do
      :print ->
        :print

      {:command, [_ | _] = argv} = process ->
        if Enum.all?(argv, &is_binary/1), do: process, else: bad_process(process)

      other ->
        bad_process(other)
    end
  end

  defp bad_process(value),
    do:
      raise(
        ArgumentError,
        "process: must be :print or {:command, argv} with argv a list of strings, got #{inspect(value)}"
      )

  @doc """
  The status of the project at `root` under `config`, as `mix surfex.status` derives it:
  the scans, the log, the `require:` policy and the options, plus `extra` options. For the
  tasks that need the whole status, so each derives it the same way.
  """
  @spec status(keyword, String.t(), String.t(), keyword) :: Surfex.Status.t()
  def status(config, root, namespace, extra) do
    entries = if File.dir?(Surfex.Log.dir(root)), do: Surfex.Log.load(root), else: []
    {scans, options} = load(config, root, namespace)
    adoption = [adoption: adoption!(config, root)]
    Surfex.Status.derive(scans, entries, require!(config), extra ++ adoption ++ options)
  end

  @doc """
  The `completeness: [min: N]` floor (§20), a number from 0 to 100, or `nil` with no key.
  Raises on anything else.
  """
  @spec completeness!(keyword) :: number | nil
  def completeness!(config) do
    case Keyword.fetch(config, :completeness) do
      :error ->
        nil

      {:ok, [min: min]} when is_number(min) and min >= 0 and min <= 100 ->
        min

      {:ok, other} ->
        raise ArgumentError,
              "completeness: must be [min: N] with N from 0 to 100, got #{inspect(other)}"
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
    case Keyword.get(config, :adoption, :reevaluate) do
      :reevaluate ->
        %{setting: :reevaluate, trusted: MapSet.new()}

      :trust ->
        %{setting: :trust, trusted: :all}

      setting ->
        unless Keyword.keyword?(setting) and setting != [] and
                 Enum.all?(setting, fn {k, v} ->
                   k in [:trust, :reevaluate] and is_list(v) and Enum.all?(v, &is_binary/1)
                 end),
               do: bad_adoption(setting)

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

  defp bad_adoption(value),
    do:
      raise(
        ArgumentError,
        "adoption: must be :reevaluate, :trust or [trust: globs, reevaluate: globs], got #{inspect(value)}"
      )

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
    policy = Keyword.get(config, :require, [])

    unless Keyword.keyword?(policy),
      do:
        raise(
          ArgumentError,
          "require: must be a keyword list of kind: [type, …], got #{inspect(policy)}"
        )

    for {kind, types} <- policy do
      unless kind in Entry.kinds() or kind in @roles,
        do: raise(ArgumentError, "require: #{inspect(kind)} is neither a kind nor a spec role")

      unless is_list(types) and types != [] and Enum.all?(types, &(&1 in Entry.types())),
        do:
          raise(
            ArgumentError,
            "require: #{kind} needs a non-empty list of #{inspect(Entry.types())}"
          )
    end

    policy
  end

  @doc """
  Every scan record under `root`: each markdown section of the `sources`, and each item
  the code scanner finds. Raises when `sources` is missing or matches nothing, since a
  status over no spec would report every relation orphaned without saying why.
  """
  @spec scans(keyword, String.t()) :: [Scan.t()]
  def scans(config, root), do: scans(config, root, items(config, root))

  @doc """
  Everything `Surfex.Status.derive/4` needs, scanning the code once: the scans, and the
  options (`options!/1`'s, plus the spec's broken citations, `broken_citations/3`, and the
  `verifies` tags that verify nothing, `Surfex.Scan.ExUnit.inert/2`).
  `namespace` is the Elixir scanner's root module when the config doesn't name one.
  """
  @spec load(keyword, String.t(), String.t() | nil) :: {[Scan.t()], keyword}
  def load(config, root, namespace) do
    items = items(config, root)

    inert =
      case Keyword.get(config, :tests) do
        nil -> []
        globs -> Scan.ExUnit.inert(root, globs)
      end

    {scans(config, root, items),
     options!(config) ++
       [citations: broken_citations(config, items, root, namespace), inert: inert]}
  end

  @doc """
  The spec's citations that resolve to nothing (`:unresolved`) or to more than one item
  (`:ambiguous`), read with `Surfex.Cite` under the config's profile (`profile!/2`). A
  name the profile declares external, or a documented absence, is not broken.
  """
  @spec broken_citations(keyword, [Surfex.Item.t()], String.t(), String.t() | nil) :: [
          Surfex.Cite.t()
        ]
  def broken_citations(config, items, root, namespace) do
    items
    |> Surfex.Cite.citations(profile!(config, namespace, items), root)
    |> Enum.filter(&(&1.status in [:unresolved, :ambiguous]))
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
          Keyword.get(config, :namespace, namespace) ||
            raise(ArgumentError, "reading citations needs namespace: for the Elixir scanner")

        roots =
          for %Surfex.Item{kind: :module, name: name} <- items,
              not String.contains?(name, "."),
              do: name

        Surfex.Scanner.Elixir.profile_defaults([ns | roots])
      else
        []
      end

    Surfex.Profile.new!(Keyword.merge(defaults, Keyword.take(config, Surfex.Profile.keys())))
  end

  defp scans(config, root, items) do
    sources =
      Keyword.get(config, :sources) ||
        raise(ArgumentError, ".surfex.exs needs sources: (the spec's globs)")

    spec =
      Scan.Markdown.records(root, sources, Keyword.get(config, :exclude, []),
        heading_ids: Keyword.get(config, :heading_ids),
        rule_ids: Keyword.get(config, :rule_ids),
        subjects: Keyword.get(config, :subjects, []),
        fold_paths: fold_paths!(config)
      )

    if spec == [],
      do: raise(ArgumentError, "no spec sections found in #{inspect(sources)} under #{root}")

    code = Scan.code(items)
    checks = config |> Scan.Checks.records(root) |> rows(spec, unit_refs!(config))

    spec ++
      code ++
      declared(tests(config, root, code) ++ checks, spec, unit_refs!(config)) ++
      classes(config)
  end

  # A check may verify every row of a marked table at once, `TABLE/*` (§11.4): the
  # declaration is each row's. A reference whose table isn't one is left as written, so it
  # is reported broken.
  defp rows([], _spec, _unit_refs), do: []

  defp rows(checks, spec, unit_refs) do
    resolver = Scan.resolver(spec, unit_refs)
    by_table = spec |> Enum.filter(&(&1.role == :row)) |> Enum.group_by(& &1.within)

    for check <- checks do
      declares =
        Enum.flat_map(check.declares, fn {type, ref} = declared ->
          with true <- String.ends_with?(ref, "/*"),
               {:ok, %Scan{role: :table, id: table}} <-
                 Scan.resolve(resolver, String.replace_suffix(ref, "/*", "")) do
            by_table |> Map.get(table, []) |> Enum.map(&{type, &1.id}) |> Enum.sort()
          else
            _ -> [declared]
          end
        end)

      %{check | declares: Enum.uniq(declares)}
    end
  end

  @doc """
  Whether `mix surfex.suggest` proposes a claim's `implements` from what its verifying
  tests call (`claim_implements:`, §15.1): `false` by default; anything but a boolean is
  refused.
  """
  @spec claim_implements?(keyword) :: boolean
  def claim_implements?(config) do
    case Keyword.get(config, :claim_implements, false) do
      flag when is_boolean(flag) ->
        flag

      other ->
        raise ArgumentError, "claim_implements: must be true or false, got #{inspect(other)}"
    end
  end

  # `fold_paths:` is a boolean; anything else is refused, not read as false.
  defp fold_paths!(config) do
    case Keyword.get(config, :fold_paths, false) do
      flag when is_boolean(flag) -> flag
      other -> raise ArgumentError, "fold_paths: must be true or false, got #{inspect(other)}"
    end
  end

  @doc """
  The project's `unit_refs:` (`Surfex.Scan.Resolver.unit_refs!/1`), `[]` when it has none.
  """
  @spec unit_refs!(keyword) :: [Regex.t()]
  def unit_refs!(config), do: config |> Keyword.get(:unit_refs, []) |> Scan.Resolver.unit_refs!()

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
        []

      globs ->
        files = Enum.flat_map(globs, &Path.wildcard(Path.join(root, &1)))

        if files == [],
          do: raise(ArgumentError, "tests: #{inspect(globs)} matches no file under #{root}")

        Scan.ExUnit.records(root, globs, code, call_scanners(config), routes(config, root))
    end
  end
end
