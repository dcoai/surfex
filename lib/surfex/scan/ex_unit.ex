defmodule Surfex.Scan.ExUnit do
  @moduledoc """
  The test scanner for ExUnit: one `Surfex.Scan` record of kind `:test` per `test`, and per
  ExUnitProperties `property`, read from source without compiling it. A property is a test
  in every way below; its `check all` generators are part of its body, so weakening one
  changes its version.

    * **id** — the module, the `describe` if any, and the test's name:
      `MyApp.CartTest: adding: rejects a closed cart`. A test defined in a comprehension
      has its name as written (`inside: \#{name}`), since the names it generates are only
      known at compile time. Two tests with one id are told apart as `~2`, `~3`.
    * **hash** — the test's version, as a function's is versioned (`Surfex.SourceScan`):
      over its body, the private helpers it calls (transitively), and the module
      attributes they read, with variables normalised. Also over every `setup` that
      applies to it (the module's and its `describe`'s, including named callbacks), and
      over the generators of a comprehension that defines it. Weakening a test through a
      helper, a setup or a table of cases changes its version; renaming a variable doesn't.
    * **location** — the file and the test's lines.
    * **declares** — what the test says it verifies, from ExUnit tags:
      `@tag verifies: "cart-add"` (or a list) before the test, `@describetag` in its
      `describe`, and `@moduletag` in its module. Each gives `{:verifies, id}`. A tag is
      ordinary ExUnit, so `mix test --only verifies:cart-add` runs exactly those tests.

  A `verifies` value that isn't a literal string or list of strings raises, naming the
  file and line: a declaration that can't be read must not be silently dropped.
  """

  alias Surfex.{Scan, SourceScan}

  # What defines a test: ExUnit's `test`, and ExUnitProperties' `property`, which ExUnit runs
  # as a test named "property …" (#141).
  @definers [:test, :property]

  @doc "Every test in every file matching `globs` under `root`, in file then source order."
  @spec records(String.t(), [String.t()]) :: [Scan.t()]
  def records(root, globs) do
    root = Path.expand(root)

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path -> path |> File.read!() |> tests(Path.relative_to(path, root)) end)
  end

  @doc "The tests in one source text, as records located in `file`."
  @spec tests(String.t(), String.t()) :: [Scan.t()]
  def tests(text, file) do
    text
    |> Code.string_to_quoted!(file: file, token_metadata: true)
    |> SourceScan.defmodules()
    |> Enum.flat_map(&module_tests(&1, file))
    |> number_duplicates()
  end

  # ── One module ──────────────────────────────────────────────────────────

  defp module_tests({:defmodule, meta, [{:__aliases__, _, parts} = aliases, [do: body]]}, file) do
    # A `describe` block's helpers are the module's functions too: ExUnit compiles them at
    # the module's top level. Flattened, a test's version and calls follow them.
    mod = {:defmodule, meta, [aliases, [do: {:__block__, [], flatten(exprs(body))}]]}
    name = parts |> Enum.filter(&is_atom/1) |> Enum.map_join(".", &Atom.to_string/1)
    # Aliases are lexical (§11): the module's own apply throughout; a describe's, to what
    # is inside it (`scopes`, for the helpers defined there); a body's, to that body.
    names = %{names(flatten(exprs(body))) | aliases: aliases(exprs(body))}
    scopes = scopes(exprs(body), names.aliases)
    ctx = %{file: file, describe: nil, tags: [], setups: [], wrappers: [], aliases: names.aliases}
    {found, _pending} = walk(exprs(body), ctx, [])
    module = %{tags: module_tags(exprs(body), file), setups: setups(exprs(body))}

    for t <- found do
      nodes = t.wrappers ++ module.setups ++ t.setups ++ [t.node]
      declares = Enum.uniq(module.tags ++ t.tags)
      describe = if t.describe, do: "#{t.describe}: ", else: ""

      %Scan{
        kind: :test,
        id: "#{name}: #{describe}#{t.name}",
        hash: SourceScan.closure_hash(mod, nodes),
        location: %{file: file, lines: SourceScan.line_range(t.node)},
        declares: Enum.map(declares, &{:verifies, &1}),
        calls: calls(mod, t, names, scopes)
      }
    end
  end

  defp module_tests(_mod, _file), do: []

  # ── What a test calls ───────────────────────────────────────────────────

  # What a test exercises, from its body and the private helpers it reaches: each function
  # it calls, as `Module.fun/arity` with the module's aliases resolved, and each module it
  # names. A local call that the module doesn't define may come from an `import`: it is
  # listed under each imported module, and whichever one the code scanner knows is the one
  # that counts. Setups are left out: they prepare a test, and what a test tests is what it
  # calls itself.
  defp calls(mod, test, names, scopes) do
    # Each body with the aliases in scope where it is defined.
    bodies =
      for node <- SourceScan.closure_nodes(mod, [test.node]) do
        scope = if node == test.node, do: test.aliases, else: Map.get(scopes, node, names.aliases)
        body = body(node)
        {body, scope, local_aliases(body)}
      end

    functions =
      Enum.flat_map(bodies, fn {body, scope, local} ->
        body
        |> remote_calls()
        |> Enum.flat_map(fn
          {:remote, parts, fun, arity, line} ->
            [call(expand(parts, visible(scope, local, line)), fun, arity)]

          {:local, fun, arity} ->
            if {fun, arity} in names.defined,
              do: [],
              else: Enum.map(names.imports, &call(&1, fun, arity))
        end)
      end)

    # Every module the test names, as a call's target or as a value (a module handed to a
    # helper that calls it): naming a module is how a test reaches it.
    modules =
      for {body, scope, local} <- bodies,
          {parts, line} <- aliases_in(body),
          do: expand(parts, visible(scope, local, line))

    (functions ++ modules) |> Enum.uniq() |> Enum.sort()
  end

  # The aliases a body sees at `line`: its scope's, and its own declared on or before it.
  defp visible(scope, local, line) do
    for {short, full, at} <- local, at <= line, into: scope, do: {short, full}
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

  # The module-level aliases at one level of expressions.
  defp aliases(exprs),
    do: for({:alias, _, args} <- exprs, pair <- alias_pairs(args), into: %{}, do: pair)

  # Each helper defined inside a describe, with the aliases in scope there: the module's
  # and the describe's own.
  defp scopes(exprs, module_aliases) do
    for {:describe, _, [_name, [do: block]]} <- exprs,
        inner = exprs(block),
        scope = Map.merge(module_aliases, aliases(inner)),
        {definer, _, _} = node <- inner,
        definer in [:def, :defp],
        into: %{},
        do: {node, scope}
  end

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

  defp call(module, fun, arity), do: "#{module}.#{fun}/#{arity}"

  # What a test or a definition runs: its body, not the `test` or `defp` around it, nor a
  # definition's head, whose patterns call nothing.
  defp body({definer, _, args}) when definer in @definers and is_list(args), do: List.last(args)
  defp body({definer, _, [_head, body]}) when definer in [:def, :defp], do: body
  defp body(other), do: other

  # Every call in `ast`: `{:remote, alias_parts, fun, arity, line}` or `{:local, fun, arity}`. A
  # piped call's arity counts the piped value, and a capture (`&Mod.fun/2`) is a call.
  defp remote_calls({:|>, _, [lhs, rhs]}), do: remote_calls(lhs) ++ piped(rhs)

  defp remote_calls(
         {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, arity]}]}
       )
       when is_atom(fun) and is_integer(arity),
       do: [{:remote, parts, fun, arity, line(meta)}]

  defp remote_calls({{:., _, [{:__aliases__, _, parts}, fun]}, meta, args})
       when is_atom(fun) and is_list(args),
       do: [{:remote, parts, fun, length(args), line(meta)} | remote_calls(args)]

  defp remote_calls({fun, _, args}) when is_atom(fun) and is_list(args) do
    n = length(args)

    if Macro.special_form?(fun, n) or Macro.operator?(fun, n),
      do: remote_calls(args),
      else: [{:local, fun, n} | remote_calls(args)]
  end

  defp remote_calls({form, _, args}) when is_list(args),
    do: remote_calls(form) ++ remote_calls(args)

  defp remote_calls({a, b}), do: remote_calls(a) ++ remote_calls(b)
  defp remote_calls(list) when is_list(list), do: Enum.flat_map(list, &remote_calls/1)
  defp remote_calls(_leaf), do: []

  defp piped({{:., _, [{:__aliases__, _, parts}, fun]}, meta, args})
       when is_atom(fun) and is_list(args),
       do: [{:remote, parts, fun, length(args) + 1, line(meta)} | remote_calls(args)]

  defp piped({fun, _, args}) when is_atom(fun) and is_list(args),
    do: [{:local, fun, length(args) + 1} | remote_calls(args)]

  defp piped(other), do: remote_calls(other)

  # The module's aliases (short name → full name), its imports, and the functions it
  # defines itself.
  defp names(exprs) do
    aliases = aliases(exprs)
    imports = for {:import, _, [{:__aliases__, _, parts} | _]} <- exprs, do: join(parts)

    defined =
      for {definer, _, [head | _]} <- exprs,
          definer in [:def, :defp, :defmacro, :defmacrop],
          {name, args} = signature(head),
          do: {name, length(args)}

    %{aliases: aliases, imports: imports, defined: defined}
  end

  defp alias_pairs([{:__aliases__, _, parts}]), do: [{List.last(parts), join(parts)}]

  defp alias_pairs([{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]),
    do: [{as, join(parts)}]

  defp alias_pairs([{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]) do
    for {:__aliases__, _, parts} <- members, do: {List.last(parts), join(base ++ parts)}
  end

  defp alias_pairs(_other), do: []

  defp expand([first | rest] = parts, aliases) when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join([full | Enum.map(rest, &Atom.to_string/1)], ".")
      :error -> join(parts)
    end
  end

  defp expand(parts, _aliases), do: join(parts)

  defp join(parts), do: parts |> Enum.filter(&is_atom/1) |> Enum.map_join(".", &Atom.to_string/1)

  defp signature({:when, _, [call | _]}), do: signature(call)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp signature(_), do: {nil, []}

  # Tests in order, each with the tags and setups that apply from its describe, its own
  # `@tag`s, and the comprehension generators around it. `pending` is the `@tag`s waiting
  # for the next test.
  defp walk(exprs, ctx, pending) do
    Enum.reduce(exprs, {[], pending}, fn expr, {found, pending} ->
      case expr do
        {:@, _, [{:tag, _, [value]}]} ->
          {found, pending ++ verifies(value, expr, ctx.file)}

        {:describe, _, [name, [do: block]]} ->
          inner = exprs(block)

          describe = %{
            ctx
            | describe: text(name),
              aliases: Map.merge(ctx.aliases, aliases(inner)),
              tags: ctx.tags ++ describe_tags(inner, ctx.file),
              setups: ctx.setups ++ setups(inner)
          }

          {more, _} = walk(inner, describe, [])
          {found ++ more, []}

        {definer, _, [name | _]} = node when definer in @definers ->
          test = %{
            name: text(name),
            node: node,
            describe: ctx.describe,
            tags: ctx.tags ++ pending,
            setups: ctx.setups,
            wrappers: ctx.wrappers,
            aliases: ctx.aliases
          }

          {found ++ [test], []}

        {:for, _, args} when is_list(args) ->
          {generators, [[do: block]]} = Enum.split(args, -1)

          {more, pending} =
            walk(exprs(block), %{ctx | wrappers: ctx.wrappers ++ generators}, pending)

          {found ++ more, pending}

        _ ->
          {found, pending}
      end
    end)
  end

  defp module_tags(exprs, file),
    do: for({:@, _, [{:moduletag, _, [v]}]} = e <- exprs, id <- verifies(v, e, file), do: id)

  defp describe_tags(exprs, file),
    do: for({:@, _, [{:describetag, _, [v]}]} = e <- exprs, id <- verifies(v, e, file), do: id)

  # The setups at one level: a block is itself; a named callback (`setup :name`, or a list
  # of names) is a call, so its private definition is followed into.
  defp setups(exprs) do
    for {form, _, args} = node <- exprs, form in [:setup, :setup_all], is_list(args) do
      case args do
        [name] when is_atom(name) ->
          [{name, [], [nil]}]

        [names] when is_list(names) and names != [] and is_atom(hd(names)) ->
          for n <- names, is_atom(n), do: {n, [], [nil]}

        _ ->
          [node]
      end
    end
    |> List.flatten()
  end

  # The ids a tag value declares: its `verifies:` key, a string or a list of strings.
  defp verifies(value, expr, file) do
    case value do
      list when is_list(list) ->
        if Keyword.keyword?(list), do: ids(list[:verifies], expr, file), else: []

      {:%{}, _, pairs} ->
        ids(Keyword.get(pairs, :verifies), expr, file)

      _ ->
        []
    end
  end

  defp ids(nil, _expr, _file), do: []
  defp ids(id, _expr, _file) when is_binary(id), do: [id]

  defp ids(list, expr, file) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: bad(expr, file)
  end

  defp ids(_other, expr, file), do: bad(expr, file)

  defp bad(expr, file) do
    {line, _} = SourceScan.line_range(expr) || {0, 0}
    raise ArgumentError, "#{file}:#{line}: verifies: must be a string or a list of strings"
  end

  # A test's or describe's name as written: a literal, or an interpolation shown as source.
  defp text(name) when is_binary(name), do: name

  defp text(name) do
    source = Macro.to_string(name)
    if String.starts_with?(source, "\""), do: String.slice(source, 1..-2//1), else: source
  end

  # The module's own expressions with every `describe` block's inlined, recursively.
  defp flatten(exprs) do
    Enum.flat_map(exprs, fn
      {:describe, _, [_name, [do: block]]} -> flatten(exprs(block))
      expr -> [expr]
    end)
  end

  defp exprs({:__block__, _, list}), do: list
  defp exprs(nil), do: []
  defp exprs(one), do: [one]

  defp number_duplicates(records) do
    {numbered, _} =
      Enum.map_reduce(records, %{}, fn r, seen ->
        n = Map.get(seen, r.id, 0) + 1
        id = if n == 1, do: r.id, else: "#{r.id}~#{n}"
        {%{r | id: id}, Map.put(seen, r.id, n)}
      end)

    numbered
  end
end
