defmodule Surfex.Scanner.Elixir do
  @moduledoc """
  The built-in scanner: an Elixir project's public API, read from source without
  compiling it.

  | Item | Kind | Key | Aliases |
  |---|---|---|---|
  | a module | `:module` | `MyApp.Cart` | — |
  | a public function | `:function` | `MyApp.Cart.add/2` | `MyApp.Cart.add` |
  | a public macro or guard | `:macro` | `MyApp.Cart.is_cart/1` | `MyApp.Cart.is_cart` |
  | a public type (`@type`, `@opaque`) | `:type` | `t:MyApp.Cart.t/0` | `MyApp.Cart.t` |

  What counts as public is `Surfex.SourceScan.defs/1`'s rule: `def`, `defmacro`,
  `defdelegate` and `defguard`, minus `@doc false` and undocumented `@impl` callbacks. A
  module under `@moduledoc false` is skipped with its functions; a module nested in it is
  not, since Elixir documents it separately. A nested module is keyed by its full name,
  as Elixir names it.

  **Hidden definitions are covered, not listed** (spec §3.3). A `@doc false` definition
  or an undocumented `@impl` callback is no item, so its version goes into its module's,
  and into each public function's that runs it: one calling it locally, or one that
  dispatches through the module's own behaviour (`GenServer.call/3` from a module that
  `use`s `GenServer` runs its hidden callbacks). A call naming one reaches it through the
  module's `Surfex.Item` `:hidden`. `Surfex.SourceScan.module_hash/1` and `defs/1` stay the
  surface alone.

  **`Mod.fun` without an arity cites every arity.** A spec that says "`MyApp.Cart.add`
  rejects a closed cart" is about the function, not one of its arities, so every arity
  shares the alias and a citation of it cites them all (`Surfex.Item` `:aliases`). A
  citation naming two unrelated items is still ambiguous; a family is not.

  ## Options

    * `:paths` — globs relative to the root. Default: `["lib/**/*.ex"]`, one project's
      own source. A poncho lists its members (`["*/lib/**/*.ex"]`). A glob that guessed
      would also find test fixtures and scratch trees that happen to have a `lib/`.
  """

  @behaviour Surfex.Scanner

  alias Surfex.{Item, SourceScan}
  alias Surfex.SourceScan.Calls

  @doc """
  Every module and public definition under `root`, sorted by key. See the moduledoc for
  what is public, and `Surfex.Scanner.c:items/2` for the contract.
  """
  @impl Surfex.Scanner
  def items(root, opts \\ []) do
    root = Path.expand(root)

    root
    |> files(Keyword.get(opts, :paths, ["lib/**/*.ex"]))
    |> Enum.flat_map(fn file ->
      rel = Path.relative_to(file, root)

      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file, token_metadata: true)
      |> modules([])
      |> items_in(rel)
    end)
    |> Enum.sort_by(&{Item.key(&1), &1.kind})
  end

  @doc """
  The `Surfex.Profile` keys that reading an Elixir project's citations starts from, for a
  project whose modules live under its roots (`"MyApp"`, or a list such as
  `["MyApp", "MyAppWeb"]`):

    * `:shape` — `MyApp`, `MyApp.Cart`, `MyApp.Cart.add`, `MyApp.Cart.add/2`: a span of
      this shape that names nothing is an unresolved citation
    * `:token` — the same names, found inside a longer span or a code block
    * `:normalise` — drops a call's arguments, so `MyApp.Cart.add(cart, item)` names
      `MyApp.Cart.add`
  """
  @spec profile_defaults(String.t() | [String.t()]) :: keyword
  def profile_defaults(roots) do
    # Longest first, so `MyAppWeb` is tried before `MyApp`.
    alternatives =
      roots
      |> List.wrap()
      |> Enum.uniq()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map_join("|", &Regex.escape/1)

    name = "(?:#{alternatives})(?:\\.[A-Z]\\w*)*(?:\\.[a-z_]\\w*[?!]?(?:/\\d+)?)?"

    [
      shape: Regex.compile!("^#{name}$"),
      # A name ends where a name ends: not glued to letters, a hyphen or a further segment.
      token: Regex.compile!("(?<![\\w.])(#{name})(?![\\w-]|\\.\\w)"),
      # ExDoc's `t:Mod.t/0` names the type `Mod.t()` does; a call's arguments drop.
      normalise: [{~r/^t:(.+)\/\d+$/s, "\\1"}, {~r/\(.*\)$/s, ""}]
    ]
  end

  defp files(root, globs),
    do: globs |> Enum.flat_map(&Path.wildcard(Path.join(root, &1))) |> Enum.uniq()

  # `{full name parts, node}` for every module, nested ones named as Elixir names them.
  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, prefix) do
    if Enum.all?(parts, &is_atom/1) do
      name = prefix ++ parts
      [{name, node} | modules(body, name)]
    else
      modules(body, prefix)
    end
  end

  defp modules({_form, _meta, args}, prefix) when is_list(args),
    do: Enum.flat_map(args, &modules(&1, prefix))

  defp modules(list, prefix) when is_list(list), do: Enum.flat_map(list, &modules(&1, prefix))
  defp modules({a, b}, prefix), do: modules(a, prefix) ++ modules(b, prefix)
  defp modules(_leaf, _prefix), do: []

  defp items_in(modules, file) do
    modules
    |> Enum.reject(fn {_name, node} -> SourceScan.hidden_module?(node) end)
    |> Enum.flat_map(fn {parts, node} ->
      module = Enum.map_join(parts, ".", &Atom.to_string/1)
      hidden = SourceScan.hidden_definitions(node)
      calls = definition_calls(node, module, hidden)

      [
        %Item{
          kind: :module,
          name: module,
          file: file,
          hash: covering(node, SourceScan.module_hash(node), Map.keys(hidden), hidden),
          lines: SourceScan.line_range(node),
          hidden: Map.new(hidden, fn {key, _} -> {id(module, key), Map.fetch!(calls, key)} end)
        }
      ] ++
        for %{name: name, arity: arity, kind: kind, hash: hash, lines: lines} <-
              SourceScan.defs(node) do
          key = {name, arity}

          %Item{
            kind: kind,
            name: "#{name}/#{arity}",
            parent: module,
            file: file,
            hash: covering(node, hash, runs(key, calls, module, hidden), hidden),
            aliases: ["#{module}.#{name}"],
            lines: lines,
            calls: Map.fetch!(calls, key)
          }
        end ++
        for %{name: name, arity: arity, hash: hash, lines: lines} <- SourceScan.types(node) do
          # Keyed as ExDoc writes a type, so a function of the same name keeps its own key.
          %Item{
            kind: :type,
            name: "t:#{module}.#{name}/#{arity}",
            file: file,
            hash: hash,
            aliases: ["#{module}.#{name}"],
            lines: lines,
            shape: true
          }
        end
    end)
  end

  # What each public and hidden definition calls (§5.2), by `{name, arity}`: what its
  # clauses and the private helpers they reach call (`Surfex.SourceScan.Calls`). A local
  # call to one of the module's public or hidden definitions is a call to it; to anything
  # the module doesn't define, a call under each module whose import admits it (brace
  # imports and `only:`/`except:` read, `Calls.importing/2`). A `defdelegate` calls
  # its target. A definition that calls a function of a module this one `use`s or declares
  # as its `@behaviour` (`GenServer.call`, `:gen_statem.call`) dispatches through it, so it
  # calls the module's hidden callbacks too.
  defp definition_calls({:defmodule, _, [_aliases, [do: body]]} = node, module, hidden) do
    names = Calls.names(exprs(body), module)
    public = node |> SourceScan.defs() |> MapSet.new(&{&1.name, &1.arity})
    behaviours = behaviours(exprs(body), names.aliases)
    callbacks = for {key, %{impl: true}} <- hidden, do: id(module, key)

    local = fn {fun, arity} = call ->
      cond do
        MapSet.member?(public, call) or Map.has_key?(hidden, call) ->
          [Calls.call(module, fun, arity)]

        call in names.defined ->
          []

        true ->
          names.imports |> Calls.importing(call) |> Enum.map(&Calls.call(&1, fun, arity))
      end
    end

    node
    |> SourceScan.definition_nodes()
    |> Map.merge(Map.new(hidden, fn {key, %{nodes: nodes}} -> {key, nodes} end))
    |> Map.new(fn {key, nodes} ->
      {delegates, clauses} = Enum.split_with(nodes, &match?({:defdelegate, _, _}, &1))
      closure = SourceScan.closure_nodes(node, clauses)
      bodies = for n <- closure, do: {n, names.aliases}

      dispatched =
        if Enum.any?(closure, &dispatches?(&1, behaviours, names.aliases)),
          do: callbacks,
          else: []

      {key,
       Enum.sort(
         Enum.uniq(
           Calls.of(bodies, local) ++
             Enum.flat_map(delegates, &delegated(&1, names.aliases)) ++ dispatched
         )
       )}
    end)
  end

  # The modules whose behaviour this module implements, by name: each it `use`s or declares
  # as `@behaviour`, an Elixir alias or an Erlang module.
  defp behaviours(exprs, aliases) do
    for expr <- exprs, name <- behaviour(expr, aliases), into: MapSet.new(), do: name
  end

  defp behaviour({:use, _, [{:__aliases__, _, parts} | _]}, aliases),
    do: [Calls.expand(parts, aliases)]

  defp behaviour({:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]}, aliases),
    do: [Calls.expand(parts, aliases)]

  defp behaviour({:@, _, [{:behaviour, _, [module]}]}, _aliases) when is_atom(module),
    do: [Atom.to_string(module)]

  defp behaviour(_expr, _aliases), do: []

  # Whether `ast` calls a function of one of `behaviours`: the module dispatches through
  # its own behaviour (`GenServer.call(server, …)` runs the module's `handle_call/3`). Read
  # from source, so a call to another server through the same behaviour counts too; that
  # errs towards a version covering more, never less.
  defp dispatches?(ast, behaviours, aliases) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = n, found
        when is_atom(fun) and is_list(args) ->
          {n, found or MapSet.member?(behaviours, Calls.expand(parts, aliases))}

        {{:., _, [module, fun]}, _, args} = n, found
        when is_atom(module) and is_atom(fun) and is_list(args) ->
          {n, found or MapSet.member?(behaviours, Atom.to_string(module))}

        n, found ->
          {n, found}
      end)

    found
  end

  # The hidden definitions a definition runs, transitively: those its calls name, and those
  # theirs name in turn.
  defp runs(key, calls, module, hidden) do
    by_id = Map.new(hidden, fn {k, _} -> {id(module, k), k} end)
    follow(Map.fetch!(calls, key), calls, by_id, MapSet.new())
  end

  defp follow([], _calls, _by_id, found), do: Enum.sort(found)

  defp follow([call | rest], calls, by_id, found) do
    case Map.fetch(by_id, call) do
      {:ok, key} ->
        if MapSet.member?(found, key),
          do: follow(rest, calls, by_id, found),
          else: follow(Map.fetch!(calls, key) ++ rest, calls, by_id, MapSet.put(found, key))

      :error ->
        follow(rest, calls, by_id, found)
    end
  end

  # A version that also covers the hidden definitions `keys`, which have no item of their
  # own: unchanged when there are none.
  defp covering(_node, hash, [], _hidden), do: hash

  defp covering(node, hash, keys, hidden) do
    nodes = keys |> Enum.sort() |> Enum.flat_map(&hidden[&1].nodes) |> Enum.uniq()
    SourceScan.definition_hash([hash, SourceScan.closure_hash(node, nodes)])
  end

  defp id(module, {name, arity}), do: Calls.call(module, name, arity)

  # `defdelegate fun(args), to: Mod` (`as: :other`) calls `Mod.fun/arity` and names `Mod`.
  defp delegated({:defdelegate, _, [head, opts]}, aliases) when is_list(opts) do
    {name, args} =
      case head do
        {:when, _, [{name, _, args} | _]} -> {name, args}
        {name, _, args} -> {name, args}
      end

    case Keyword.get(opts, :to) do
      {:__aliases__, _, parts} ->
        target = Calls.expand(parts, aliases)
        [target, Calls.call(target, Keyword.get(opts, :as, name), length(List.wrap(args)))]

      _other ->
        []
    end
  end

  defp delegated(_node, _aliases), do: []

  defp exprs({:__block__, _, list}), do: list
  defp exprs(nil), do: []
  defp exprs(one), do: [one]
end
