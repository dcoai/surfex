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
  @type reading :: %{module: String.t(), targets: [String.t()], unscanned: [String.t()]}

  @doc """
  The reading of each dispatcher (`Module.fun/arity`) among `modules`, each
  `%{name, node}` as the Elixir scanner reads them. A literal entry without an arity names
  every arity of the function its module defines with `def` or `defdelegate`; one with an
  arity names that arity, if defined. A dispatcher the modules don't define raises.
  """
  @spec read([%{name: String.t(), node: Macro.t()}], [String.t()]) :: %{
          String.t() => reading
        }
  def read(_modules, []), do: %{}

  def read(modules, dispatchers) do
    by_name = Map.new(modules, &{&1.name, &1.node})
    defined = Map.new(by_name, fn {name, node} -> {name, defined(node)} end)

    Map.new(dispatchers, fn id ->
      module = Calls.module_of(id)
      [_, fun, arity] = Regex.run(~r/\.([^.\/]+)\/(\d+)$/, id)
      key = {String.to_atom(fun), String.to_integer(arity)}

      unless key in Map.get(defined, module, []),
        do:
          raise(
            ArgumentError,
            "dispatch: #{id} isn't a function the scanned source defines with def"
          )

      {found, missing} =
        by_name[module]
        |> entries(module)
        |> Enum.map(&resolve(&1, defined))
        |> Enum.split_with(&match?({:ok, _}, &1))

      targets = for {:ok, ids} <- found, id <- ids, do: id

      {id,
       %{
         module: module,
         targets: targets |> Enum.uniq() |> Enum.sort(),
         unscanned: missing |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
       }}
    end)
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
