defmodule Surfex.SourceScan.Closure do
  @moduledoc false
  # A function's content hash over what it actually depends on, read from source (#20):
  #
  #   * its own clauses, with variables renamed by order of first appearance, so renaming a
  #     variable is not a change;
  #   * transitively, every private definition it calls, so a change made through a helper
  #     is a change to the function;
  #   * the values assigned to every module attribute it (or a callee) reads.
  #
  # Calls to other modules, and to the module's own public functions, are not followed:
  # those have their own rows and their own hashes.

  # `groups` maps `{name, arity}` to `%{nodes: [clause], defaults: n, private: boolean}` for
  # every definition in the module; `attributes` maps an attribute name to the values it is
  # assigned, in source order.
  def hash(key, groups, attributes) do
    locals0 = for {{name, 0}, _} <- groups, into: MapSet.new(), do: name
    privates = private_index(groups)

    {callees, read} = closure([key], MapSet.new(), MapSet.new(), groups, privates)

    [
      normalise_all(groups[key].nodes, locals0),
      for(
        {name, arity} = k <- Enum.sort(callees),
        do: [Atom.to_string(name), arity, normalise_all(groups[k].nodes, locals0)]
      ),
      for(attr <- Enum.sort(read), do: [Atom.to_string(attr), Map.get(attributes, attr, [])])
    ]
    |> Surfex.SourceScan.definition_hash()
  end

  # Private definitions reachable from `frontier`, and the attributes read on the way.
  defp closure([], callees, read, _groups, _privates), do: {callees, read}

  defp closure([key | rest], callees, read, groups, privates) do
    nodes = groups[key].nodes
    read = Enum.reduce(nodes, read, &MapSet.union(&2, reads(&1)))

    found =
      nodes
      |> Enum.flat_map(&calls/1)
      |> Enum.flat_map(&resolve(&1, privates))
      |> Enum.reject(&(MapSet.member?(callees, &1) or &1 == key))
      |> Enum.uniq()

    closure(rest ++ found, MapSet.union(callees, MapSet.new(found)), read, groups, privates)
  end

  # name => [{arity, defaults, key}] for private definitions: a call of arity n reaches a
  # definition of arity a when its defaults cover the difference.
  defp private_index(groups) do
    for {{name, arity} = key, %{private: true, defaults: defaults}} <- groups, reduce: %{} do
      acc -> Map.update(acc, name, [{arity, defaults, key}], &[{arity, defaults, key} | &1])
    end
  end

  defp resolve({name, n}, privates) do
    for {arity, defaults, key} <- Map.get(privates, name, []),
        n <= arity and n >= arity - defaults,
        do: key
  end

  # ── What a clause calls and reads ─────────────────────────────────────

  # Local calls as {name, arity}. A piped call's arity counts the piped value; a capture
  # (`&fee/1`) is a reference. Anything that is not a local call (a remote call, a special
  # form) resolves to nothing, because no private definition has its name and arity.
  defp calls({:|>, _, [lhs, {name, _, args}]}) when is_atom(name) and is_list(args),
    do: [{name, length(args) + 1} | calls(lhs) ++ calls(args)]

  defp calls({:&, _, [{:/, _, [{name, _, ctx}, arity]}]})
       when is_atom(name) and is_atom(ctx) and is_integer(arity),
       do: [{name, arity}]

  defp calls({name, _, args}) when is_atom(name) and is_list(args),
    do: [{name, length(args)} | calls(args)]

  defp calls({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [{name, 0}]
  defp calls({form, _, args}) when is_list(args), do: calls(form) ++ calls(args)
  defp calls({a, b}), do: calls(a) ++ calls(b)
  defp calls(list) when is_list(list), do: Enum.flat_map(list, &calls/1)
  defp calls(_leaf), do: []

  defp reads(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{name, _, ctx}]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # ── Variable normalisation ────────────────────────────────────────────

  defp normalise_all(nodes, locals0), do: Enum.map(nodes, &normalise(&1, locals0))

  # Each variable becomes `v0`, `v1`, … by first appearance in the clause. Left alone: an
  # attribute read (`@rate` is not a variable), a zero-arity local function called without
  # parentheses, `_`, and special forms such as `__MODULE__`.
  defp normalise(clause, locals0) do
    {ast, _} = rename(clause, %{}, locals0)
    ast
  end

  defp rename({:@, _, [{name, _, ctx}]} = node, seen, _locals0)
       when is_atom(name) and is_atom(ctx),
       do: {node, seen}

  defp rename({name, meta, ctx} = node, seen, locals0) when is_atom(name) and is_atom(ctx) do
    if variable?(name, locals0) do
      case Map.fetch(seen, name) do
        {:ok, new} ->
          {{new, meta, nil}, seen}

        :error ->
          new = :"v#{map_size(seen)}"
          {{new, meta, nil}, Map.put(seen, name, new)}
      end
    else
      {node, seen}
    end
  end

  defp rename({form, meta, args}, seen, locals0) when is_list(args) do
    {form, seen} = rename(form, seen, locals0)
    {args, seen} = rename(args, seen, locals0)
    {{form, meta, args}, seen}
  end

  defp rename({a, b}, seen, locals0) do
    {a, seen} = rename(a, seen, locals0)
    {b, seen} = rename(b, seen, locals0)
    {{a, b}, seen}
  end

  defp rename(list, seen, locals0) when is_list(list),
    do: Enum.map_reduce(list, seen, &rename(&1, &2, locals0))

  defp rename(leaf, seen, _locals0), do: {leaf, seen}

  defp variable?(name, locals0) do
    text = Atom.to_string(name)
    name != :_ and not String.starts_with?(text, "__") and not MapSet.member?(locals0, name)
  end
end
