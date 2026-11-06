defmodule Surfex.SourceScan.Dispatch do
  @moduledoc false
  # Calls through a declared dispatch function (§11.10, #272): a function that runs a
  # handler it looks up in a table (`apply(module, fun, args)` from a map of operations)
  # reaches every handler the table lists. The project declares the dispatcher
  # (`dispatch:` in `.surfex.exs`); the targets are read from its module's source, never
  # compiled: the literal `{Module, :fun}` and `{Module, :fun, arity}` tuples and
  # `&Module.fun/arity` captures written inside its module attributes, map literals and
  # keyword literals.

  alias Surfex.SourceScan.Calls

  @not_tables [
    :spec,
    :type,
    :typep,
    :opaque,
    :callback,
    :macrocallback,
    :doc,
    :moduledoc,
    :typedoc,
    :impl
  ]
  @blocks [:do, :else, :after, :rescue, :catch]

  @typedoc """
  What one dispatcher's module lists: the scanned functions it reaches (`targets`, call
  ids), the literal entries naming no function the scanned source defines (`unscanned`,
  `Module.fun` or `Module.fun/arity`), and the module the dispatcher is in.
  """
  @type reading :: %{
          required(:module) => String.t(),
          required(:targets) => [String.t()],
          required(:unscanned) => [String.t()],
          optional(:module_arg) => pos_integer,
          optional(:by_module) => %{String.t() => [String.t()]}
        }

  @typedoc "A dispatcher as declared: its id alone for a table, or with its form (§11.10)."
  @type declared ::
          String.t()
          | %{
              required(:id) => String.t(),
              optional(:registry) => String.t(),
              optional(:module_arg) => pos_integer,
              optional(:callback) => atom
            }

  @doc """
  The reading of each dispatcher (`Module.fun/arity`) among `modules`, each
  `%{name, node}` as the Elixir scanner reads them. A literal entry without an arity names
  every arity of the function its module defines with `def` or `defdelegate`; one with an
  arity names that arity, if defined. A dispatcher the modules don't define raises.
  """
  @spec read([%{name: String.t(), node: Macro.t()}], [declared]) :: %{
          String.t() => reading
        }
  def read(_modules, []), do: %{}

  def read(modules, dispatchers) do
    by_name = Map.new(modules, &{&1.name, &1.node})
    defined = Map.new(by_name, fn {name, node} -> {name, defined(node)} end)

    Map.new(dispatchers, fn declared ->
      id = id(declared)
      module = Calls.module_of(id)
      defined!(id, defined)

      case declared do
        %{registry: _} -> {id, registry(declared, module, by_name, defined)}
        %{module_arg: _} -> {id, module_arg(declared, module, by_name, defined)}
        _ -> {id, table(module, by_name, defined)}
      end
    end)
  end

  @doc "What a call to the dispatcher reaches, as `Surfex.SourceScan.Calls.of/5` takes it."
  @spec callee(map) :: [String.t()] | %{module_arg: pos_integer, by_module: map}
  def callee(%{module_arg: n, by_module: by_module}), do: %{module_arg: n, by_module: by_module}
  def callee(%{targets: targets}), do: targets

  defp id(%{id: id}), do: id
  defp id(id), do: id

  defp key(id) do
    [_, fun, arity] = Regex.run(~r/\.([^.\/]+)\/(\d+)$/, id)
    {String.to_atom(fun), String.to_integer(arity)}
  end

  defp defined!(id, defined) do
    unless key(id) in Map.get(defined, Calls.module_of(id), []),
      do:
        raise(
          ArgumentError,
          "dispatch: #{id} isn't a function the scanned source defines with def"
        )
  end

  # A registry (§11.10): each module the catalogue's literal list holds, by its callbacks.
  defp registry(declared, module, by_name, defined) do
    defined!(declared.registry, defined)
    listed = catalogue(declared.registry, by_name)

    found =
      for name <- listed || [], do: {name, implementing(name, declared, by_name, defined)}

    %{
      module: module,
      targets: found |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      unscanned: for({name, []} <- found, uniq: true, do: name) |> Enum.sort()
    }
  end

  # A module passed as a value (§11.10): what each scanned module would answer, kept for the
  # call sites to read by the alias each one passes.
  defp module_arg(declared, module, by_name, defined) do
    by_module =
      for name <- Map.keys(by_name),
          ids = implementing(name, declared, by_name, defined),
          ids != [],
          into: %{},
          do: {name, ids}

    %{
      module: module,
      targets: [],
      unscanned: [],
      module_arg: declared.module_arg,
      by_module: by_module
    }
  end

  # The functions of `name` that implement a callback of a behaviour it declares with
  # `@behaviour`, or are named `callback:`, whatever the behaviour.
  defp implementing(name, declared, by_name, defined) do
    own = Map.get(defined, name, [])

    wanted =
      case declared do
        %{callback: callback} when callback != nil ->
          for {^callback, arity} <- own, do: {callback, arity}

        _ ->
          for behaviour <- behaviours(by_name[name], name),
              node = by_name[behaviour],
              node != nil,
              c <- Surfex.SourceScan.callbacks(node),
              {c.name, c.arity} in own,
              do: {c.name, c.arity}
      end

    wanted
    |> Enum.uniq()
    |> Enum.map(fn {fun, arity} -> Calls.call(name, fun, arity) end)
    |> Enum.sort()
  end

  defp behaviours(nil, _name), do: []

  defp behaviours({:defmodule, _, [_aliases, [do: body]]}, name) do
    aliases = Map.put(Calls.aliases(exprs(body)), :__MODULE__, name)

    for {:@, _, [{:behaviour, _, [value]}]} <- exprs(body),
        found = module(value, aliases),
        do: found
  end

  # The modules a catalogue function returns, when its body, or a module attribute it
  # returns, is a literal list of aliases; nil otherwise.
  defp catalogue(id, by_name) do
    module = Calls.module_of(id)
    {:defmodule, _, [_aliases, [do: body]]} = by_name[module]
    aliases = Map.put(Calls.aliases(exprs(body)), :__MODULE__, module)

    exprs(body)
    |> Enum.find_value(fn
      {:def, _, [head, [do: value]]} ->
        {name, arity, _} = signature(head)
        if {name, arity} == key(id), do: {:found, value}

      _ ->
        nil
    end)
    |> case do
      {:found, value} -> literal_modules(resolve_attribute(value, body), aliases)
      nil -> nil
    end
  end

  defp resolve_attribute({:@, _, [{attribute, _, ctx}]}, body) when is_atom(ctx) do
    Enum.find_value(exprs(body), fn
      {:@, _, [{^attribute, _, [value]}]} -> value
      _ -> nil
    end)
  end

  defp resolve_attribute(value, _body), do: value

  defp literal_modules(list, aliases) when is_list(list) do
    names = Enum.map(list, &module(&1, aliases))
    if list != [] and Enum.all?(names, &is_binary/1), do: names
  end

  defp literal_modules(_other, _aliases), do: nil

  # A table (§11.10): the literal entries its module writes.
  defp table(module, by_name, defined) do
    {found, missing} =
      by_name[module]
      |> entries(module)
      |> Enum.map(&resolve(&1, defined))
      |> Enum.split_with(&match?({:ok, _}, &1))

    targets = for {:ok, ids} <- found, id <- ids, do: id

    %{
      module: module,
      targets: targets |> Enum.uniq() |> Enum.sort(),
      unscanned: missing |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    }
  end

  # The functions a module can be applied to: its `def`s and `defdelegate`s, at each arity
  # their default arguments give.
  defp defined({:defmodule, _, [_aliases, [do: body]]}) do
    for {definer, _, [head | _]} <- exprs(body),
        definer in [:def, :defdelegate],
        {name, arity, defaults} = signature(head),
        name != nil,
        a <- (arity - defaults)..arity//1,
        uniq: true,
        do: {name, a}
  end

  defp resolve({module, fun, nil}, defined) do
    case for({^fun, a} <- Map.get(defined, module, []), do: Calls.call(module, fun, a)) do
      [] -> {:missing, "#{module}.#{fun}"}
      ids -> {:ok, Enum.sort(ids)}
    end
  end

  defp resolve({module, fun, arity}, defined) do
    if {fun, arity} in Map.get(defined, module, []),
      do: {:ok, [Calls.call(module, fun, arity)]},
      else: {:missing, Calls.call(module, fun, arity)}
  end

  # The literal entries `{module, fun, arity | nil}` inside the module's own attributes,
  # map literals and keyword literals, with aliases resolved as the module declares them.
  # A module nested in it is its own.
  defp entries({:defmodule, _, [_aliases, [do: body]]}, module) do
    aliases = Map.put(Calls.aliases(exprs(body)), :__MODULE__, module)

    {_, found} =
      Macro.prewalk(body, [], fn
        {:defmodule, _, _}, acc -> {:skip, acc}
        node, acc -> {node, if(table?(node), do: targets(node, aliases) ++ acc, else: acc)}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  # Where a table is written: a module attribute's value (not a typespec's or the docs'),
  # a map literal, a keyword literal. A `do:` block's keywords are code, not a table.
  defp table?({:@, _, [{name, _, [_value]}]}) when is_atom(name), do: name not in @not_tables
  defp table?({:%{}, _, pairs}) when is_list(pairs), do: true

  defp table?([_ | _] = list),
    do:
      Enum.all?(list, &match?({key, _} when is_atom(key), &1)) and
        not Enum.any?(list, fn {key, _} -> key in @blocks end)

  defp table?(_node), do: false

  # Every literal target in a table, however deep.
  defp targets(table, aliases) do
    {_, found} =
      Macro.prewalk(table, [], fn node, acc ->
        case target(node, aliases) do
          nil -> {node, acc}
          entry -> {node, [entry | acc]}
        end
      end)

    found
  end

  defp target({module, fun}, aliases) when is_atom(fun) and fun not in [nil, true, false] do
    with name when is_binary(name) <- module(module, aliases), do: {name, fun, nil}
  end

  defp target({:{}, _, [module, fun, arity]}, aliases)
       when is_atom(fun) and fun not in [nil, true, false] and is_integer(arity) do
    with name when is_binary(name) <- module(module, aliases), do: {name, fun, arity}
  end

  defp target({:&, _, [{:/, _, [{{:., _, [module, fun]}, _, []}, arity]}]}, aliases)
       when is_atom(fun) and is_integer(arity) do
    with name when is_binary(name) <- module(module, aliases), do: {name, fun, arity}
  end

  defp target(_node, _aliases), do: nil

  defp module({:__aliases__, _, parts}, aliases) do
    if Enum.all?(parts, &is_atom/1), do: Calls.expand(parts, aliases)
  end

  defp module({:__MODULE__, _, ctx}, aliases) when is_atom(ctx), do: aliases[:__MODULE__]
  defp module(_other, _aliases), do: nil

  # A head's name, arity and how many of its arguments have defaults.
  defp signature({:when, _, [call | _]}), do: signature(call)

  defp signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), Enum.count(args, &match?({:\\, _, _}, &1))}

  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0, 0}
  defp signature(_), do: {nil, 0, 0}

  defp exprs({:__block__, _, list}), do: list
  defp exprs(nil), do: []
  defp exprs(one), do: [one]
end
