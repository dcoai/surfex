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
      ordinary ExUnit, so `mix test --only verifies:cart-add` runs the tests tagged
      `"cart-add"`.
    * **unselectable** — the declared ids `mix test --only verifies:id` can't select the
      test by. ExUnit compares a list tag as one string, its ids run together, so a test
      tagged `["cart-add", "carts"]` is selected by neither, though it declares both.

  A `verifies` value that isn't a literal string or list of strings raises, naming the
  file and line: a declaration that can't be read must not be silently dropped.
  """

  alias Surfex.{Scan, SourceScan}
  alias Surfex.SourceScan.Calls

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
    names = %{Calls.names(flatten(exprs(body)), name) | aliases: aliases(exprs(body), name)}
    scopes = scopes(exprs(body), names.aliases)

    ctx = %{
      file: file,
      describe: nil,
      tags: nil,
      setups: [],
      wrappers: [],
      aliases: names.aliases
    }

    {found, _pending} = walk(exprs(body), ctx, nil)
    module = %{tags: module_tags(exprs(body), file), setups: setups(exprs(body))}

    for t <- found do
      nodes = t.wrappers ++ module.setups ++ t.setups ++ [t.node]
      # As ExUnit merges tags (#149): the most specific level that sets `verifies` wins,
      # the test's own over its describe's over its module's.
      tag = t.tags || module.tags || []
      declares = tag |> List.wrap() |> Enum.uniq()
      describe = if t.describe, do: "#{t.describe}: ", else: ""

      %Scan{
        kind: :test,
        id: "#{name}: #{describe}#{t.name}",
        hash: SourceScan.closure_hash(mod, nodes),
        location: %{file: file, lines: SourceScan.line_range(t.node)},
        declares: Enum.map(declares, &{:verifies, &1}),
        unselectable: unselectable(tag),
        calls: calls(mod, t, names, scopes)
      }
    end
  end

  defp module_tests(_mod, _file), do: []

  # ── What a test calls ───────────────────────────────────────────────────

  # What a test exercises, from its body and the private helpers it reaches
  # (`Surfex.SourceScan.Calls`). A local call that the module doesn't define may come from
  # an `import`: it is listed under each imported module, and whichever one the code
  # scanner knows is the one that counts. Setups are left out: they prepare a test, and
  # what a test tests is what it calls itself.
  defp calls(mod, test, names, scopes) do
    # Each body with the aliases in scope where it is defined.
    bodies =
      for node <- SourceScan.closure_nodes(mod, [test.node]),
          do:
            {node,
             if(node == test.node, do: test.aliases, else: Map.get(scopes, node, names.aliases))}

    Calls.of(bodies, fn {fun, arity} = local ->
      if local in names.defined,
        do: [],
        else: Enum.map(names.imports, &Calls.call(&1, fun, arity))
    end)
  end

  # The module's own aliases, and `__MODULE__` as the module.
  defp aliases(exprs, module), do: Map.put(Calls.aliases(exprs), :__MODULE__, module)

  # Each helper defined inside a describe, with the aliases in scope there: the module's
  # and the describe's own.
  defp scopes(exprs, module_aliases) do
    for {:describe, _, [_name, [do: block]]} <- exprs,
        inner = exprs(block),
        scope = Map.merge(module_aliases, Calls.aliases(inner)),
        {definer, _, _} = node <- inner,
        definer in [:def, :defp],
        into: %{},
        do: {node, scope}
  end

  # Tests in order, each with the tags and setups that apply from its describe, its own
  # `@tag`s, and the comprehension generators around it. `pending` is the `@tag`s waiting
  # for the next test.
  defp walk(exprs, ctx, pending) do
    Enum.reduce(exprs, {[], pending}, fn expr, {found, pending} ->
      case expr do
        {:@, _, [{:tag, _, [value]}]} ->
          # A later `@tag verifies:` replaces an earlier one; a tag without it leaves it.
          {found, verifies(value, expr, ctx.file) || pending}

        {:describe, _, [name, [do: block]]} ->
          inner = exprs(block)

          describe = %{
            ctx
            | describe: text(name),
              aliases: Map.merge(ctx.aliases, Calls.aliases(inner)),
              tags: describe_tags(inner, ctx.file),
              setups: ctx.setups ++ setups(inner)
          }

          {more, _} = walk(inner, describe, nil)
          {found ++ more, nil}

        {definer, _, [name | _]} = node when definer in @definers ->
          test = %{
            name: text(name),
            node: node,
            describe: ctx.describe,
            tags: pending || ctx.tags,
            setups: ctx.setups,
            wrappers: ctx.wrappers,
            aliases: ctx.aliases
          }

          {found ++ [test], nil}

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

  # A level's `verifies`: the last `@moduletag` or `@describetag` that sets it, or nil when
  # none does (the level then leaves it to the one above, as ExUnit does).
  defp module_tags(exprs, file), do: last_set(exprs, :moduletag, file)
  defp describe_tags(exprs, file), do: last_set(exprs, :describetag, file)

  defp last_set(exprs, attribute, file) do
    for {:@, _, [{^attribute, _, [v]}]} = e <- exprs,
        ids = verifies(v, e, file),
        ids != nil,
        reduce: nil do
      _earlier -> ids
    end
  end

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

  # A tag value's `verifies:` as written, a string or a list of strings, or nil when it
  # doesn't set it. Its form matters to `unselectable/1`.
  defp verifies(value, expr, file) do
    case value do
      list when is_list(list) ->
        if Keyword.keyword?(list) and Keyword.has_key?(list, :verifies),
          do: ids(list[:verifies], expr, file)

      {:%{}, _, pairs} ->
        if Keyword.has_key?(pairs, :verifies), do: ids(Keyword.get(pairs, :verifies), expr, file)

      _ ->
        nil
    end
  end

  defp ids(nil, _expr, _file), do: []
  defp ids(id, _expr, _file) when is_binary(id), do: id

  defp ids(list, expr, file) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: bad(expr, file)
  end

  defp ids(_other, expr, file), do: bad(expr, file)

  # The declared ids `mix test --only verifies:id` can't select the test by (#190). ExUnit
  # compares a list tag as one string, its ids run together, so a list is selectable only
  # by that: by its id when it has one, by none of several.
  defp unselectable(ids) when is_list(ids),
    do: ids |> Enum.uniq() |> Enum.reject(&(&1 == Enum.join(ids)))

  defp unselectable(_id), do: []

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
