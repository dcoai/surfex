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

  @typedoc """
  An imported module and which of its functions the import brings in: all of them, only
  those listed (`only: [fun: arity]`), or all but those listed (`except:`). `only:
  :functions` (or `:macros`, `:sigils`) is read as all: telling a function from a macro
  takes the module's own source.
  """
  @type import :: {String.t(), :all | {:only | :except, [{atom, non_neg_integer}]}}

  @typedoc """
  What a remote call names beyond its function (`Surfex.Scanner.c:calls/3`): given the
  call's AST and the aliases in scope, the item keys.
  """
  @type remote :: (Macro.t(), aliases -> [String.t()])

  @doc """
  Every function and module `bodies` call or name, sorted. Each body is a node with the
  aliases in scope where it is defined; its own `alias`es apply from their line on. A
  local call (`fun/arity` with no module) is `local`'s to resolve: it returns the ids the
  call names, if any. A remote call names its function, and whatever `remote` answers for
  it (§5.4): a piped call is given with its piped value as its first argument. `driven`
  is asked about each whole body, with every alias it can see, for calls only the body as
  a whole states (a request to a route, then an event to the view it mounted, #206).
  """
  @spec of(
          [{Macro.t(), aliases}],
          ({atom, non_neg_integer} -> [String.t()]),
          remote,
          (Macro.t(), aliases -> [String.t()])
        ) :: [String.t()]
  def of(bodies, local, remote \\ none(), driven \\ fn _body, _aliases -> [] end) do
    bodies =
      for {node, scope} <- bodies, body = body(node), do: {body, scope, local_aliases(body)}

    functions =
      Enum.flat_map(bodies, fn {body, scope, own} ->
        body
        |> calls()
        |> Enum.flat_map(fn
          {:remote, parts, fun, arity, line, node} ->
            aliases = visible(scope, own, line)
            [call(expand(parts, aliases), fun, arity) | named(remote, node, aliases)]

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

    stated =
      for {body, scope, own} <- bodies,
          id <- driven.(body, visible(scope, own, :infinity)),
          do: id

    (functions ++ modules ++ stated) |> Enum.uniq() |> Enum.sort()
  end

  @doc "A `t:remote/0` that names nothing: the calls of a project with no scanner answering."
  @spec none() :: remote
  def none, do: fn _call, _aliases -> [] end

  @doc """
  The `t:remote/0` of `scanners` (`[{module, opts}]`, `Surfex.Status.Config.scanners!/1`):
  each that implements `Surfex.Scanner.c:calls/3` is asked, and the keys they answer are
  joined. A scanner answering anything but a list of strings raises, naming it.
  """
  @spec remote([{module, keyword}]) :: remote
  def remote(scanners) do
    case for {m, opts} <- scanners,
             Code.ensure_loaded?(m),
             function_exported?(m, :calls, 3),
             do: {m, opts} do
      [] ->
        none()

      asked ->
        fn call, aliases ->
          Enum.flat_map(asked, fn {m, opts} ->
            case m.calls(call, aliases, opts) do
              keys when is_list(keys) ->
                if Enum.all?(keys, &is_binary/1), do: keys, else: bad_answer(m, keys)

              other ->
                bad_answer(m, other)
            end
          end)
        end
    end
  end

  defp bad_answer(scanner, answer),
    do:
      raise(
        ArgumentError,
        "#{inspect(scanner)}.calls/3 must answer a list of item keys, got #{inspect(answer)}"
      )

  # A capture names a function without calling it: there is no call to ask about.
  defp named(_remote, nil, _aliases), do: []
  defp named(remote, node, aliases), do: remote.(node, aliases)

  @doc """
  A module's aliases (short name => full name), its imports (`t:import/0`), and the
  `{name, arity}` of every function and macro it defines, from its own expressions.
  `module`, when given, is what `__MODULE__` names. An import names its module as an alias
  does (resolved through the module's aliases), and `import Base.{A, B}` imports each of
  `Base.A` and `Base.B`, with the same `only:`/`except:` (#194).
  """
  @spec names([Macro.t()], String.t() | nil) :: %{
          aliases: aliases,
          imports: [import],
          defined: [{atom, non_neg_integer}]
        }
  def names(exprs, module \\ nil) do
    aliases = aliases(exprs)
    aliases = if module, do: Map.put(aliases, :__MODULE__, module), else: aliases
    imports = for {:import, _, args} <- exprs, import <- imports(args, aliases), do: import

    defined =
      for {definer, _, [head | _]} <- exprs,
          definer in [:def, :defp, :defmacro, :defmacrop],
          {name, args} = signature(head),
          do: {name, length(args)}

    %{aliases: aliases, imports: imports, defined: defined}
  end

  @doc """
  The modules among `imports` (`names/2`) that a local call of `fun/arity` may come from:
  each whose `only:` lists it, or whose `except:` doesn't. Which of them defines it is for
  the caller to say, if it knows the module's code.
  """
  @spec importing([import], {atom, non_neg_integer}) :: [String.t()]
  def importing(imports, call) do
    for {module, filter} <- imports, admits?(filter, call), do: module
  end

  defp admits?(:all, _call), do: true
  defp admits?({:only, listed}, call), do: call in listed
  defp admits?({:except, listed}, call), do: call not in listed

  @doc "The module-level aliases at one level of expressions."
  @spec aliases([Macro.t()]) :: aliases
  def aliases(exprs),
    do: for({:alias, _, args} <- exprs, pair <- alias_pairs(args), into: %{}, do: pair)

  @doc "A call's id: `Module.fun/arity`."
  @spec call(String.t(), atom, non_neg_integer) :: String.t()
  def call(module, fun, arity), do: "#{module}.#{fun}/#{arity}"

  @doc "The module of a call's id: `MyApp.Cart` for `MyApp.Cart.add/2`."
  @spec module_of(String.t()) :: String.t()
  def module_of(id) do
    [_, module] = Regex.run(~r/^((?:[A-Z]\w*\.)*[A-Z]\w*)\./, id)
    module
  end

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
  defp calls({:|>, _, [lhs, rhs]}), do: calls(lhs) ++ piped(lhs, rhs)

  defp calls({:&, meta, [{:/, _, [{{:., _, [target, fun]}, _, []}, arity]}]})
       when is_atom(fun) and is_integer(arity) do
    case target(target) do
      nil -> []
      parts -> [{:remote, parts, fun, arity, line(meta), nil}]
    end
  end

  defp calls({{:., _, [target, fun]}, meta, args} = node) when is_atom(fun) and is_list(args) do
    case target(target) do
      nil -> calls_in(node)
      parts -> [{:remote, parts, fun, length(args), line(meta), node} | calls(args)]
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

  # A piped call is asked about with its piped value as its first argument, as it runs.
  defp piped(lhs, {{:., _, [target, fun]} = dot, meta, args} = node)
       when is_atom(fun) and is_list(args) do
    case target(target) do
      nil ->
        calls(node)

      parts ->
        [
          {:remote, parts, fun, length(args) + 1, line(meta), {dot, meta, [lhs | args]}}
          | calls(args)
        ]
    end
  end

  defp piped(_lhs, {fun, _, args}) when is_atom(fun) and is_list(args),
    do: [{:local, fun, length(args) + 1} | calls(args)]

  defp piped(_lhs, other), do: calls(other)

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

  # An `import`'s modules, each with its filter: one for `import A`, one per member for
  # `import Base.{A, B}`, every one with the options given.
  defp imports([target | opts], aliases) do
    filter = opts |> List.first([]) |> import_filter()

    for parts <- import_targets(target), do: {expand(parts, aliases), filter}
  end

  defp import_targets({:__aliases__, _, parts}), do: [parts]

  defp import_targets({{:., _, [{:__aliases__, _, base}, :{}]}, _, members}),
    do: for({:__aliases__, _, parts} <- members, do: base ++ parts)

  # An Erlang module (`import :lists`) or anything computed: no module surfex can name.
  defp import_targets(_other), do: []

  # `only:` or `except:` with a literal list of `fun: arity`; anything else imports all.
  defp import_filter(opts) when is_list(opts) do
    case {Keyword.get(opts, :only), Keyword.get(opts, :except)} do
      {only, _} when is_list(only) -> {:only, pairs(only)}
      {_, except} when is_list(except) -> {:except, pairs(except)}
      _all -> :all
    end
  end

  defp import_filter(_opts), do: :all

  defp pairs(list),
    do: for({fun, arity} <- list, is_atom(fun) and is_integer(arity), do: {fun, arity})

  defp join(parts), do: parts |> Enum.filter(&is_atom/1) |> Enum.map_join(".", &Atom.to_string/1)

  defp signature({:when, _, [call | _]}), do: signature(call)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp signature(_), do: {nil, []}
end
