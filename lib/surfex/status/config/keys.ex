defmodule Surfex.Status.Config.Keys do
  @moduledoc false
  # Every `.surfex.exs` key's validator, in one place (§13.14): what form each key takes,
  # checked before anything is scanned. A refusal names the key, the value as written (the
  # user's own term, `inspect`ed, never a normalised one) and the accepted form, and every
  # refusal of a config is gathered, so one run names them all.
  #
  # A key's accessor in `Surfex.Status.Config` (and `Surfex.Goldens.entries!/1`) asks
  # `check!/2` before reading it, so a config built in code is held to the same forms. What
  # needs the file system (a glob matching nothing, a named router the source doesn't
  # define) is checked where it is read.

  alias Surfex.Log.Entry
  alias Surfex.Profile

  @profile Profile.keys() -- [:rules]

  @roles [:section, :block, :test_hint, :table, :row, :rule, :contract]

  # Each key and the form a refusal names.
  @forms %{
    sources: "a non-empty list of globs (strings)",
    exclude: "a list of path prefixes (strings)",
    shape: "a regex",
    token: "a regex",
    known_shape: "a regex or nil",
    normalise: "a list of {regex, replacement} with the replacement a string",
    subjects: "a list of %{file: path or regex, heading: regex, items: [string, …]}",
    table_columns: "a list of strings",
    file_targets: "a list of file names (strings) or :item_files",
    known_external: "a map of name => reason",
    documented_absences: "a map of {name, file} => reason, name and file strings",
    classes: "a list of {class, reason}, both strings",
    rules:
      "a list of %{class: string, kinds: [atom, …]} with name: and parent: regexes and parent_cited: a boolean",
    never_excused: "a list of kinds (atoms)",
    heading_ids:
      ":section_sign, :section_number, a regex with a named capture (?<id>…), or a non-empty list of them",
    rule_ids:
      ":section_sign, :section_number, a regex with a named capture (?<id>…), or a non-empty list of them",
    unit_refs:
      "a list of regexes, each with a named capture (?<id>…) and one of (?<file>…) or (?<chapter>…)",
    fold_paths: "true or false",
    scanner: ":elixir or a module",
    scanner_opts: "a keyword list",
    scanners: "a non-empty list of :elixir, a module or {scanner, opts}",
    namespace: ~s{a string ("MyApp"), a module (MyApp), or a non-empty list of them},
    goldens:
      "a non-empty list of :status, :completeness, {:status | :completeness, output} or {output, module, opts}",
    require: "a keyword list of kind: [type, …]",
    tests: "a list of globs (strings)",
    declares:
      "[verifies: [form, …]], each form {:tag, key} or {:attribute, name}, with [strip: regex] as an option",
    triangle: ":report or :fail",
    require_red: "true or false",
    router: "a module, a non-empty list of modules, or false",
    dispatch: "a list of {Module, :fun, arity}",
    claim_implements: "true or false",
    spec_classes:
      "a list of {name, reason} or {name, reason, files: [glob], headings: regex, marker: regex}",
    issues:
      "[command: argv, state: key, project: name] with argv a non-empty list of strings and state and project strings",
    not_claims: "a list of regexes",
    checks: "a list of checks, each [id:, run:, verifies:, inputs:]",
    adoption: ":reevaluate, :trust or [trust: globs, reevaluate: globs]",
    process: ":print or {:command, argv} with argv a non-empty list of strings",
    completeness: "[min: N] with N from 0 to 100"
  }

  @keys Map.keys(@forms) |> Enum.sort()

  @doc false
  # The keys with a validator: every key a `.surfex.exs` may hold.
  @spec keys() :: [atom]
  def keys, do: @keys

  @doc false
  # Every refusal of `config`'s known keys, in the config's order, then those between keys.
  @spec refusals(keyword) :: [String.t()]
  def refusals(config) do
    own =
      for {key, value} <- config,
          Map.has_key?(@forms, key),
          problem <- check(key, value),
          do: format(key, problem)

    own ++ Enum.map(across(config), fn {key, problem} -> format(key, problem) end)
  end

  @doc false
  # Raises `ArgumentError` with the refusals of one key, one per line.
  @spec check!(keyword, atom) :: :ok
  def check!(config, key) do
    problems =
      case Keyword.fetch(config, key) do
        {:ok, value} -> check(key, value)
        :error -> []
      end

    across = for {^key, problem} <- across(config), do: problem

    case Enum.map(problems ++ across, &format(key, &1)) do
      [] -> :ok
      lines -> raise ArgumentError, Enum.join(lines, "\n")
    end
  end

  @doc false
  # The one shape every refusal takes: `KEY: FORM, got VALUE`, and where only part of the
  # value is wrong, the whole value as written after it.
  @spec format(atom, {String.t(), term} | {String.t(), term, term} | String.t()) :: String.t()
  def format(key, {form, value}), do: "#{key}: #{form}, got #{inspect(value)}"

  def format(key, {form, value, within}),
    do: "#{key}: #{form}, got #{inspect(value)} in #{inspect(within)}"

  def format(key, message) when is_binary(message), do: "#{key}: #{message}"

  # ── One key at a time ───────────────────────────────────────────────────

  # The whole value refused, with the key's form.
  defp whole(key, value), do: [{"must be " <> Map.fetch!(@forms, key), value}]

  defp check(:tests, value), do: if(strings?(value), do: [], else: whole(:tests, value))

  # A rule is checked element by element, so a refusal names the one that is wrong.
  defp check(:rules, value) when is_list(value) do
    for rule <- value, not rule?(rule), do: {"a rule must be " <> rule_form(), rule}
  end

  defp check(:rules, value), do: whole(:rules, value)

  # The other profile keys take the form `Surfex.Profile.new!/1` checks.
  defp check(key, value) when key in @profile,
    do: if(Profile.valid_key?(key, value), do: [], else: whole(key, value))

  defp check(key, value) when key in [:heading_ids, :rule_ids] do
    case value do
      nil -> []
      [] -> whole(key, value)
      list when is_list(list) -> Enum.flat_map(list, &grammar(key, &1, list))
      one -> grammar(key, one, nil)
    end
  end

  defp check(:unit_refs, value) when is_list(value) do
    for ref <- value, problem = unit_ref(ref, value), do: problem
  end

  defp check(:unit_refs, value), do: whole(:unit_refs, value)

  defp check(key, value) when key in [:fold_paths, :require_red, :claim_implements],
    do: if(is_boolean(value), do: [], else: whole(key, value))

  defp check(:scanner, value), do: if(scanner?(value), do: [], else: whole(:scanner, value))

  defp check(:scanner_opts, value),
    do: if(keyword?(value), do: [], else: whole(:scanner_opts, value))

  defp check(:scanners, [_ | _] = list) do
    bad = for entry <- list, not scanner_entry?(entry), do: entry

    twice =
      for {scanner, n} <- list |> Enum.filter(&scanner_entry?/1) |> Enum.frequencies_by(&name/1),
          n > 1,
          do: "names #{inspect(scanner)} twice"

    if bad == [], do: twice, else: whole(:scanners, list)
  end

  defp check(:scanners, value), do: whole(:scanners, value)

  defp check(:namespace, value) do
    case value do
      [_ | _] = list -> if Enum.all?(list, &root?/1), do: [], else: whole(:namespace, value)
      one -> if root?(one), do: [], else: whole(:namespace, value)
    end
  end

  defp check(:goldens, value), do: goldens(value)

  defp check(:require, value) do
    if keyword?(value) do
      Enum.flat_map(value, fn {kind, types} ->
        cond do
          kind not in Entry.kinds() and kind not in @roles ->
            ["#{inspect(kind)} is neither a kind nor a spec role"]

          not (is_list(types) and types != [] and Enum.all?(types, &(&1 in Entry.types()))) ->
            [{"#{kind} must be a non-empty list of #{inspect(Entry.types())}", types}]

          true ->
            []
        end
      end)
    else
      whole(:require, value)
    end
  end

  defp check(:declares, value) do
    case value do
      [] ->
        []

      [verifies: [_ | _] = forms] ->
        for form <- forms, not declared_form?(form) do
          {"a form must be {:tag, key} or {:attribute, name}, a name other than ExUnit's own, " <>
             "with [strip: regex] as its only option", form}
        end

      other ->
        whole(:declares, other)
    end
  end

  defp check(:triangle, value),
    do: if(value in [:report, :fail], do: [], else: whole(:triangle, value))

  defp check(:router, value) do
    case value do
      false -> []
      [_ | _] = list -> if Enum.all?(list, &module?/1), do: [], else: whole(:router, value)
      one -> if module?(one), do: [], else: whole(:router, value)
    end
  end

  defp check(:dispatch, value) do
    valid? =
      is_list(value) and
        Enum.all?(value, fn
          {m, f, a} -> module?(m) and is_atom(f) and is_integer(a) and a >= 0
          _ -> false
        end)

    if valid?, do: [], else: whole(:dispatch, value)
  end

  defp check(:spec_classes, value) when is_list(value) do
    problems = Enum.flat_map(value, &spec_class/1)

    if problems != [] do
      problems
    else
      for {name, classes} <- Enum.group_by(value, &class_name/1),
          reasons = classes |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
          length(reasons) > 1,
          do:
            "#{name} is declared with different reasons: " <>
              Enum.map_join(reasons, " / ", &inspect/1)
    end
  end

  defp check(:spec_classes, value), do: whole(:spec_classes, value)

  defp check(:issues, value) do
    valid? =
      keyword?(value) and Keyword.keys(value) -- [:command, :state, :project] == [] and
        argv?(Keyword.get(value, :command)) and
        Enum.all?([:state, :project], fn key ->
          value |> Keyword.get(key) |> nil_or(&is_binary/1)
        end)

    if valid?, do: [], else: whole(:issues, value)
  end

  defp check(:not_claims, value) do
    if is_list(value) and Enum.all?(value, &regex?/1),
      do: [],
      else: whole(:not_claims, value)
  end

  defp check(:checks, value) when is_list(value) do
    problems = Enum.flat_map(value, &check_entry/1)

    if problems != [] do
      problems
    else
      for {id, n} <- Enum.frequencies_by(value, &Keyword.get(&1, :id)),
          n > 1,
          do: "the id #{inspect(id)} is declared twice"
    end
  end

  defp check(:checks, value), do: whole(:checks, value)

  defp check(:adoption, value) do
    case value do
      setting when setting in [:reevaluate, :trust] ->
        []

      [_ | _] = setting ->
        valid? =
          keyword?(setting) and
            Enum.all?(setting, fn {k, v} -> k in [:trust, :reevaluate] and strings?(v) end)

        if valid?, do: [], else: whole(:adoption, value)

      other ->
        whole(:adoption, other)
    end
  end

  defp check(:process, value) do
    case value do
      :print -> []
      {:command, argv} -> if argv?(argv), do: [], else: whole(:process, value)
      other -> whole(:process, other)
    end
  end

  defp check(:completeness, value) do
    case value do
      [min: min] when is_number(min) and min >= 0 and min <= 100 -> []
      other -> whole(:completeness, other)
    end
  end

  # ── Between keys ────────────────────────────────────────────────────────

  # What no one key can say: two keys that are one setting, and a rule naming a class the
  # config doesn't declare, or excusing a kind it says is never excused.
  defp across(config) do
    scanners =
      cond do
        Keyword.has_key?(config, :scanners) and Keyword.has_key?(config, :scanner) ->
          [{:scanners, "scanners: and scanner: are one setting; give only scanners:"}]

        Keyword.has_key?(config, :scanners) and Keyword.has_key?(config, :scanner_opts) ->
          [
            {:scanner_opts,
             "scanner_opts: belongs to scanner:; with scanners: give {scanner, opts}"}
          ]

        true ->
          []
      end

    scanners ++ rule_classes(config)
  end

  defp rule_classes(config) do
    classes = Keyword.get(config, :classes, [])
    rules = Keyword.get(config, :rules, [])
    never = Keyword.get(config, :never_excused, [])

    if check(:classes, classes) == [] and check(:rules, rules) == [] and
         check(:never_excused, never) == [] do
      known = MapSet.new(classes, &elem(&1, 0))

      Enum.flat_map(rules, fn %{class: class, kinds: kinds} = rule ->
        excused = Enum.filter(kinds, &(&1 in never))

        cond do
          not MapSet.member?(known, class) ->
            [
              {:rules,
               "a rule names class #{inspect(class)}, which classes: lacks: #{inspect(rule)}"}
            ]

          excused != [] ->
            [
              {:rules,
               "a rule for #{inspect(class)} would excuse #{inspect(excused)}, which " <>
                 "never_excused: says can never be excused"}
            ]

          true ->
            []
        end
      end)
    else
      []
    end
  end

  # ── The parts ───────────────────────────────────────────────────────────

  defp nil_or(nil, _valid?), do: true
  defp nil_or(v, valid?), do: valid?.(v)

  defp strings?(v), do: is_list(v) and Enum.all?(v, &is_binary/1)
  defp regex?(v), do: is_struct(v, Regex)
  defp keyword?(v), do: is_list(v) and Keyword.keyword?(v)
  defp argv?(v), do: is_list(v) and v != [] and Enum.all?(v, &is_binary/1)

  # An alias: an atom Elixir names a module by (`MyApp`), never `:my_app`, nil or a boolean.
  defp module?(v), do: is_atom(v) and String.starts_with?(Atom.to_string(v), "Elixir.")

  defp root?(v), do: (is_binary(v) and String.trim(v) != "") or module?(v)

  defp scanner?(v), do: v == :elixir or module?(v)

  defp scanner_entry?({scanner, opts}), do: scanner?(scanner) and keyword?(opts)
  defp scanner_entry?(scanner), do: scanner?(scanner)

  defp name({scanner, _opts}), do: scanner
  defp name(scanner), do: scanner

  defp rule_form,
    do:
      "%{class: string, kinds: [atom, …]} with name: and parent: regexes or nil and parent_cited: a boolean"

  defp rule?(%{class: class, kinds: kinds} = rule) do
    is_binary(class) and is_list(kinds) and kinds != [] and Enum.all?(kinds, &is_atom/1) and
      Enum.all?([:name, :parent], &(Map.get(rule, &1) == nil or regex?(Map.get(rule, &1)))) and
      is_boolean(Map.get(rule, :parent_cited, false))
  end

  defp rule?(_), do: false

  defp grammar(_key, named, _within) when named in [:section_sign, :section_number], do: []

  defp grammar(_key, %Regex{} = regex, within) do
    if "id" in Regex.names(regex),
      do: [],
      else: [problem("a grammar regex needs a named capture (?<id>…)", regex, within)]
  end

  defp grammar(key, other, nil), do: whole(key, other)
  defp grammar(key, _other, within), do: whole(key, within)

  defp unit_ref(%Regex{} = ref, within) do
    names = Regex.names(ref)

    unless "id" in names and Enum.any?(["file", "chapter"], &(&1 in names)),
      do:
        problem(
          "a citation form needs a named capture (?<id>…) and one of (?<file>…) or (?<chapter>…)",
          ref,
          within
        )
  end

  defp unit_ref(_ref, within), do: hd(whole(:unit_refs, within))

  defp problem(form, value, nil), do: {form, value}
  defp problem(form, value, within), do: {form, value, within}

  defp goldens(value) do
    cond do
      not (is_list(value) and value != []) ->
        whole(:goldens, value)

      :trace in value ->
        [
          "the entry :trace was removed in 0.4.0 with the v0.2 trace: the relation log (:status) replaces it"
        ]

      (bad = Enum.reject(value, &golden?/1)) != [] ->
        for entry <- bad, do: {"an entry must be one of " <> golden_entries(), entry}

      true ->
        outputs = Enum.map(value, &golden_output/1)

        case outputs -- Enum.uniq(outputs) do
          [] -> []
          dups -> ["two goldens write #{inspect(Enum.uniq(dups))}"]
        end
    end
  end

  defp golden_entries,
    do: ":status, :completeness, {:status | :completeness, output} or {output, module, opts}"

  defp golden?(:status), do: true
  defp golden?({:status, out}), do: is_binary(out)
  defp golden?(:completeness), do: true
  defp golden?({:completeness, out}), do: is_binary(out)
  defp golden?({out, mod, opts}), do: is_binary(out) and module?(mod) and keyword?(opts)
  defp golden?(_), do: false

  # The file a golden entry writes.
  defp golden_output(:status), do: "RELATIONS.md"
  defp golden_output({:status, out}), do: out
  defp golden_output(:completeness), do: "COMPLETENESS.md"
  defp golden_output({:completeness, out}), do: out
  defp golden_output({out, _mod, _opts}), do: out

  # ExUnit's own tag keys, and the attributes ExUnit reads, are no project's form.
  @not_forms [:verifies, :tag, :describetag, :moduletag, :doc, :moduledoc]

  defp declared_form?({kind, name}), do: declared_form?({kind, name, []})

  defp declared_form?({kind, name, opts})
       when kind in [:tag, :attribute] and is_atom(name) and name not in @not_forms,
       do: opts == [] or match?([strip: %Regex{}], opts)

  defp declared_form?(_), do: false

  @class_name ~r/^[A-Za-z0-9_-]+$/

  # A class's name as a string, the way `spec_classes!/2` reads it.
  defp class_name(class), do: class |> elem(0) |> to_string()

  defp spec_class({name, reason}), do: class_parts(name, reason, [], {name, reason})
  defp spec_class({name, reason, opts} = class), do: class_parts(name, reason, opts, class)

  defp spec_class(other),
    do: [
      {"a class must be {name, reason} or {name, reason, files: [glob], headings: regex, marker: regex}",
       other}
    ]

  defp class_parts(name, reason, opts, class) do
    name? =
      (is_binary(name) or (is_atom(name) and name not in [nil, true, false])) and
        Regex.match?(@class_name, to_string(name))

    reason? = is_binary(reason) and String.trim(reason) != ""

    opts_problems =
      cond do
        not keyword?(opts) ->
          [{"options must be a keyword list of files:, headings: and marker:", opts, class}]

        (unknown = Keyword.keys(opts) -- [:files, :headings, :marker]) != [] ->
          [
            {"unknown option #{Enum.map_join(unknown, ", ", &"#{&1}:")} (expected files:, headings:, marker:)",
             class}
          ]

        true ->
          files = Keyword.get(opts, :files)

          files_problem =
            if files == nil or (is_list(files) and files != [] and Enum.all?(files, &is_binary/1)),
              do: [],
              else: [{"files: must be a non-empty list of globs (strings)", files, class}]

          regex_problems =
            for key <- [:headings, :marker],
                value = Keyword.get(opts, key),
                not regex?(value),
                do: {"#{key}: must be a regex", value, class}

          files_problem ++ regex_problems
      end

    Enum.reject(
      [
        unless(name?,
          do:
            {"a class name must be a string or an atom of letters, digits, - and _", name, class}
        ),
        unless(reason?, do: {"a class's reason must be a non-empty string", reason, class})
      ],
      &is_nil/1
    ) ++ opts_problems
  end

  # A check: a keyword list of `id`, `run`, `verifies` and optionally `inputs` (§11.4).
  @check_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  defp check_entry(check) do
    if keyword?(check) do
      case Keyword.keys(check) -- [:id, :run, :verifies, :inputs] do
        [] ->
          id = Keyword.get(check, :id)
          run = Keyword.get(check, :run)
          verifies = check |> Keyword.get(:verifies) |> List.wrap()
          inputs = Keyword.get(check, :inputs, [])

          [
            unless(is_binary(id) and Regex.match?(@check_id, id),
              do:
                {"id: must be letters, digits and . _ -, starting with a letter or digit", id,
                 check}
            ),
            unless((is_binary(run) and String.trim(run) != "") or argv?(run),
              do:
                {"run: must be a command, a string run through sh -c or an argv (a non-empty " <>
                   "list of strings) run with no shell", run, check}
            ),
            unless(verifies != [] and Enum.all?(verifies, &(is_binary(&1) and &1 != "")),
              do: {"verifies: must be a spec unit or a list of them", check[:verifies], check}
            ),
            unless(strings?(inputs),
              do: {"inputs: must be a list of globs (strings)", inputs, check}
            )
          ]
          |> Enum.reject(&is_nil/1)

        unknown ->
          [
            {"unknown keys #{inspect(unknown)} (expected id:, run:, verifies:, inputs:)", check}
          ]
      end
    else
      [{"each check must be a keyword list", check}]
    end
  end
end
