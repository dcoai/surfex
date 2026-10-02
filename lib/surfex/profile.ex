defmodule Surfex.Profile do
  @moduledoc """
  Everything project-specific about reading a spec's citations and excusing code, **as
  data**. `Surfex.Cite` and
  `Surfex.Coverage` are generic; a profile is what makes them read one project's spec
  against one project's code. A profile holds no functions, so it can live in a data file
  and be read in review like any other configuration.

  Build one with `new!/1`. It rejects an unknown key, a wrong type, and a rule that is
  inconsistent with the rest of the profile, **loudly and before anything is scanned**: a
  misconfigured check must never pass.

  ## Where the spec is

    * `:sources` — globs, relative to the root, of the files whose prose cites the code
    * `:exclude` — path prefixes to drop from those (a vendored tree is not a citation of
      itself)

  ## What a citation looks like

  A code span (`` `x` ``) in a source is a citation when it names an item. The shape keys
  decide what happens when it does not:

    * `:shape` — a regex for "this looks like a claim about the code". A span of this
      shape that names nothing is **unresolved**: a rename, a removal, or a name that was
      never there. Anything else in backticks is prose and is ignored.
    * `:token` — (default: an identifier, `[A-Za-z_][A-Za-z0-9_]*`) how a span, or a
      fenced code block, is split into names when the whole span is not a name
      (`ioctl(fd, APP_IOC_ABORT, …)` cites `APP_IOC_ABORT`)
    * `:known_shape` — tokens trusted *only* when they resolve (all-caps constants, say):
      tried inside spans, never reported as unresolved
    * `:normalise` — `{regex, replacement}` rewrites applied in order after trimming, so
      `` `struct x` ``, `` `x()` `` and `` `x[8]` `` all name `x`

  ## How the spec is laid out

    * `:subjects` — `[%{file: path | regex, heading: regex, items: [key]}]`. A section
      whose heading matches is *about* those items. Its heading cites them, and a bare
      member name anywhere inside it (until a heading of the same or higher level)
      resolves as `item.name`, trying each subject in order. A spec that documents a
      structure section by section then needs no qualified names.
    * `:table_columns` — table header names (`"Field"`, `"Type"`) whose cells are
      citations even without backticks, because the cell is the row's subject rather than
      a code reference. A cell holding a code span is already cited as one.
    * `:file_targets` — file names that are citation targets in their own right.
      `:item_files` in the list adds every file an item is declared in.
    * `:known_external` — `%{name => reason}`: real, but outside the scanned tree
    * `:documented_absences` — `%{{name, file} => reason}`: a section that names something
      deliberately *because* the code does not have it

  ## Coverage

    * `:classes` — `[{class, reason}]`: a kind of code the spec doesn't describe, and why
    * `:rules` — `[%{class:, kinds:, name: regex | nil, parent_cited: boolean, parent: regex | nil}]`
      (`parent:` matches a member's parent module, never an item with no parent). The first
      matching rule excuses an uncited item into its class. Rules are by class, never by
      item, so a new helper falls into its class and a new entry point is a gap.
    * `:never_excused` — kinds that are the spec's subject matter. An uncited one is always
      a GAP, and a rule naming one is a configuration error.
  """

  @type rule :: %{
          class: String.t(),
          kinds: [atom],
          name: Regex.t() | nil,
          parent_cited: boolean,
          parent: Regex.t() | nil
        }
  @type subject :: %{file: String.t() | Regex.t(), heading: Regex.t(), items: [String.t()]}

  @type t :: %__MODULE__{
          sources: [String.t()],
          exclude: [String.t()],
          shape: Regex.t(),
          token: Regex.t(),
          known_shape: Regex.t() | nil,
          normalise: [{Regex.t(), String.t()}],
          subjects: [subject],
          table_columns: [String.t()],
          file_targets: [String.t() | :item_files],
          known_external: %{String.t() => String.t()},
          documented_absences: %{{String.t(), String.t()} => String.t()},
          classes: [{String.t(), String.t()}],
          rules: [rule],
          never_excused: [atom]
        }

  @enforce_keys [:sources, :shape]
  defstruct sources: [],
            exclude: [],
            shape: nil,
            token: nil,
            known_shape: nil,
            normalise: [],
            subjects: [],
            table_columns: [],
            file_targets: [],
            known_external: %{},
            documented_absences: %{},
            classes: [],
            rules: [],
            never_excused: []

  @keys [
    :sources,
    :exclude,
    :shape,
    :token,
    :known_shape,
    :normalise,
    :subjects,
    :table_columns,
    :file_targets,
    :known_external,
    :documented_absences,
    :classes,
    :rules,
    :never_excused
  ]

  @doc "The keys a profile takes: what shapes reading citations, and the class keys."
  @spec keys() :: [atom]
  def keys, do: @keys

  @doc "A validated profile from a keyword list or map. Raises `ArgumentError` naming the key."
  @spec new!(keyword | map) :: t
  def new!(fields) do
    fields = Map.new(fields)

    case Map.keys(fields) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown profile keys: #{inspect(Enum.sort(unknown))}"
    end

    for key <- [:sources, :shape], not Map.has_key?(fields, key) do
      raise ArgumentError, "profile key #{inspect(key)} is required"
    end

    fields =
      fields
      |> Map.put_new_lazy(:token, fn -> ~r/\b([A-Za-z_][A-Za-z0-9_]*)\b/ end)
      |> Map.update(:rules, [], &rules/1)

    profile = struct!(__MODULE__, fields)
    Enum.each(@keys, &check!(&1, Map.fetch!(profile, &1)))
    check_rules!(profile)
    profile
  end

  @doc """
  The coverage keys of a config (`classes:`, `rules:`, `never_excused:`), validated as
  `new!/1` validates them, for the relation log's classes (`Surfex.Scan.Classes`) without
  a whole profile. Rules get their defaults (`name: nil`, `parent_cited: false`,
  `parent: nil`).
  Raises `ArgumentError` naming what is wrong.
  """
  @spec coverage!(keyword | map) :: %{
          classes: [{String.t(), String.t()}],
          rules: [rule],
          never_excused: [atom]
        }
  def coverage!(config) do
    config = Map.new(config)

    coverage = %{
      classes: Map.get(config, :classes, []),
      rules: config |> Map.get(:rules, []) |> rules(),
      never_excused: Map.get(config, :never_excused, [])
    }

    Enum.each(coverage, fn {key, value} -> check!(key, value) end)
    check_rules!(coverage)
    coverage
  end

  defp rules(rules) when is_list(rules), do: Enum.map(rules, &rule/1)
  defp rules(other), do: other

  defp rule(%{class: _, kinds: _} = r),
    do: Map.merge(%{name: nil, parent_cited: false, parent: nil}, r)

  defp rule(other),
    do: raise(ArgumentError, "profile rule needs :class and :kinds, got #{inspect(other)}")

  defp check!(key, value) do
    if valid?(key, value),
      do: :ok,
      else: raise(ArgumentError, "profile key #{inspect(key)} is invalid: #{inspect(value)}")
  end

  defp valid?(:sources, v), do: strings?(v) and v != []
  defp valid?(:exclude, v), do: strings?(v)
  defp valid?(:table_columns, v), do: strings?(v)

  defp valid?(:file_targets, v),
    do: is_list(v) and Enum.all?(v, &(is_binary(&1) or &1 == :item_files))

  defp valid?(:shape, v), do: regex?(v)
  defp valid?(:token, v), do: regex?(v)
  defp valid?(:known_shape, v), do: is_nil(v) or regex?(v)
  defp valid?(:normalise, v), do: is_list(v) and Enum.all?(v, &rewrite?/1)
  defp valid?(:subjects, v), do: is_list(v) and Enum.all?(v, &subject?/1)
  defp valid?(:known_external, v), do: is_map(v)
  defp valid?(:documented_absences, v), do: is_map(v) and Enum.all?(Map.keys(v), &pair?/1)
  defp valid?(:classes, v), do: is_list(v) and Enum.all?(v, &pair?/1)
  defp valid?(:never_excused, v), do: is_list(v) and Enum.all?(v, &is_atom/1)
  defp valid?(:rules, v), do: is_list(v)

  defp strings?(v), do: is_list(v) and Enum.all?(v, &is_binary/1)
  defp regex?(v), do: is_struct(v, Regex)
  defp pair?({a, b}), do: is_binary(a) and is_binary(b)
  defp pair?(_), do: false
  defp rewrite?({re, rep}), do: regex?(re) and is_binary(rep)
  defp rewrite?(_), do: false

  defp subject?(%{file: file, heading: heading, items: items} = s) when map_size(s) == 3,
    do: (is_binary(file) or regex?(file)) and regex?(heading) and strings?(items) and items != []

  defp subject?(_), do: false

  defp check_rules!(%{classes: classes, rules: rules, never_excused: never}) do
    known = MapSet.new(classes, &elem(&1, 0))

    for %{class: class, kinds: kinds, name: name} = rule <- rules do
      cond do
        not MapSet.member?(known, class) ->
          raise ArgumentError, "profile rule names class #{inspect(class)}, which :classes lacks"

        not (is_list(kinds) and kinds != [] and Enum.all?(kinds, &is_atom/1)) ->
          raise ArgumentError, "profile rule #{inspect(rule)} needs a non-empty :kinds list"

        not (is_nil(name) or regex?(name)) ->
          raise ArgumentError, "profile rule #{inspect(rule)} has a non-regex :name"

        not (is_nil(rule.parent) or regex?(rule.parent)) ->
          raise ArgumentError, "profile rule #{inspect(rule)} has a non-regex :parent"

        (excused = Enum.filter(kinds, &(&1 in never))) != [] ->
          raise ArgumentError,
                "profile rule for #{inspect(class)} would excuse #{inspect(excused)}, " <>
                  "which :never_excused says can never be excused"

        true ->
          :ok
      end
    end

    :ok
  end
end
