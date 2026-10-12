defmodule Surfex.SourceScan.Calls do
  @moduledoc false
  # What source calls (§11, §5.2), read without compiling it: each function a body calls,
  # as `Module.fun/arity` with aliases resolved where they're declared, and each module it
  # names. A test's calls (`Surfex.Scan.ExUnit`) and a definition's (`Surfex.Scanner.Elixir`)
  # are read the same way; what a local call means is the caller's to say.

  # What defines a body: ExUnit's `test` and ExUnitProperties' `property`, and a function.
  @definers [:test, :property]

  @typedoc "Short alias name => full module name."
  @type aliases :: %{atom => String.t()}

  @doc """
  Every function and module `bodies` call or name, sorted. Each body is a node with the
  aliases in scope where it is defined; its own `alias`es apply from their line on. A
  local call (`fun/arity` with no module) is `local`'s to resolve: it returns the ids the
  call names, if any.
  """
  @spec of([{Macro.t(), aliases}], ({atom, non_neg_integer} -> [String.t()])) :: [String.t()]
  def of(bodies, local) do
    bodies =
      for {node, scope} <- bodies, body = body(node), do: {body, scope, local_aliases(body)}

    functions =
      Enum.flat_map(bodies, fn {body, scope, own} ->
        body
        |> calls()
        |> Enum.flat_map(fn
          {:remote, parts, fun, arity, line} ->
            [call(expand(parts, visible(scope, own, line)), fun, arity)]

          {:local, fun, arity} ->
            local.({fun, arity})
        end)
      end)

    # Every module a body names, as a call's target or as a value (a module handed to a
    # helper that calls it): naming a module is how code reaches it.
    modules =
      for {body, scope, own} <- bodies,
          {parts, line} <- aliases_in(body),
          do: expand(parts, visible(scope, own, line))

    (functions ++ modules) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  A module's aliases (short name => full name), the modules it imports, and the
  `{name, arity}` of every function and macro it defines, from its own expressions.
  `module`, when given, is what `__MODULE__` names.
  """
  @spec names([Macro.t()], String.t() | nil) :: %{
          aliases: aliases,
          imports: [String.t()],
          defined: [{atom, non_neg_integer}]
        }
  def names(exprs, module \\ nil) do
    aliases = aliases(exprs)
    aliases = if module, do: Map.put(aliases, :__MODULE__, module), else: aliases
    imports = for {:import, _, [{:__aliases__, _, parts} | _]} <- exprs, do: join(parts)

    defined =
      for {definer, _, [head | _]} <- exprs,
          definer in [:def, :defp, :defmacro, :defmacrop],
          {name, args} = signature(head),
          do: {name, length(args)}

    %{aliases: aliases, imports: imports, defined: defined}
  end

  @doc "The module-level aliases at one level of expressions."
  @spec aliases([Macro.t()]) :: aliases
  def aliases(exprs),
    do: for({:alias, _, args} <- exprs, pair <- alias_pairs(args), into: %{}, do: pair)

  @doc "A call's id: `Module.fun/arity`."
  @spec call(String.t(), atom, non_neg_integer) :: String.t()
  def call(module, fun, arity), do: "#{module}.#{fun}/#{arity}"

  @doc "An alias's parts, resolved through `aliases`: `Cart` is `MyApp.Cart` after `alias MyApp.Cart`."
  @spec expand(list, aliases) :: String.t()
  def expand([first | rest] = parts, aliases) when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join([full | Enum.map(rest, &Atom.to_string/1)], ".")
      :error -> join(parts)
    end
  end

  def expand(parts, _aliases), do: join(parts)

  # The aliases a body sees at `line`: its scope's, and its own declared on or before it.
  defp visible(scope, own, line) do
    for {short, full, at} <- own, at <= line, into: scope, do: {short, full}
  end

  # The aliases a body declares, with their lines, in order.
  defp local_aliases(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {:alias, meta, args} = node, acc when is_list(args) ->
          {node, acc ++ for({short, full} <- alias_pairs(args), do: {short, full, line(meta)})}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)

  defp aliases_in(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, parts} = node, acc when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [{parts, line(meta)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # What a test or a definition runs: its body, not the `test` or `defp` around it, nor a
  # definition's head, whose patterns call nothing.
  defp body({definer, _, args}) when definer in @definers and is_list(args), do: List.last(args)

  defp body({definer, _, [_head, body]}) when definer in [:def, :defp, :defmacro, :defmacrop],
    do: body

  defp body(other), do: other

  # Every call in `ast`: `{:remote, alias_parts, fun, arity, line}` or `{:local, fun, arity}`. A
  # piped call's arity counts the piped value, and a capture (`&Mod.fun/2`) is a call.
  # `__MODULE__.fun()` is a remote call to the module itself.
  defp calls({:|>, _, [lhs, rhs]}), do: calls(lhs) ++ piped(rhs)

  defp calls({:&, meta, [{:/, _, [{{:., _, [target, fun]}, _, []}, arity]}]})
       when is_atom(fun) and is_integer(arity) do
    case target(target) do
      nil -> []
      parts -> [{:remote, parts, fun, arity, line(meta)}]
    end
  end

  defp calls({{:., _, [target, fun]}, meta, args} = node) when is_atom(fun) and is_list(args) do
    case target(target) do
      nil -> calls_in(node)
      parts -> [{:remote, parts, fun, length(args), line(meta)} | calls(args)]
    end
  end

  defp calls({fun, _, args}) when is_atom(fun) and is_list(args) do
    n = length(args)

    if Macro.special_form?(fun, n) or Macro.operator?(fun, n),
      do: calls(args),
      else: [{:local, fun, n} | calls(args)]
  end

  defp calls({form, _, args}) when is_list(args), do: calls(form) ++ calls(args)
  defp calls({a, b}), do: calls(a) ++ calls(b)
  defp calls(list) when is_list(list), do: Enum.flat_map(list, &calls/1)
  defp calls(_leaf), do: []

  # A call through anything but an alias (a variable, an Erlang module): only its parts.
  defp calls_in({{:., _, [target, _fun]}, _, args}), do: calls(target) ++ calls(args)

  defp piped({{:., _, [target, fun]}, meta, args} = node) when is_atom(fun) and is_list(args) do
    case target(target) do
      nil -> calls(node)
      parts -> [{:remote, parts, fun, length(args) + 1, line(meta)} | calls(args)]
    end
  end

  defp piped({fun, _, args}) when is_atom(fun) and is_list(args),
    do: [{:local, fun, length(args) + 1} | calls(args)]

  defp piped(other), do: calls(other)

  defp target({:__aliases__, _, parts}), do: parts
  defp target({:__MODULE__, _, ctx}) when is_atom(ctx), do: [:__MODULE__]
  defp target(_other), do: nil

  defp alias_pairs([{:__aliases__, _, parts}]), do: [{List.last(parts), join(parts)}]

  defp alias_pairs([{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]),
    do: [{as, join(parts)}]

  defp alias_pairs([{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]) do
    for {:__aliases__, _, parts} <- members, do: {List.last(parts), join(base ++ parts)}
  end

  defp alias_pairs(_other), do: []

  defp join(parts), do: parts |> Enum.filter(&is_atom/1) |> Enum.map_join(".", &Atom.to_string/1)

  defp signature({:when, _, [call | _]}), do: signature(call)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp signature(_), do: {nil, []}
end
