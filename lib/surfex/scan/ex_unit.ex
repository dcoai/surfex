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
    * **deviation** — the reference a test gives with `@tag deviation: "#119"` (or at its
      `describe`'s or module's level, merged as `verifies` is): the code is known to
      deviate from what the test verifies, and the reference names what will fix it. Free
      text, `nil` when the test doesn't declare one.
    * **skip** — ExUnit's `skip:` tag as `mix test --include skip:VALUE` matches it: its
      literal reason, `"true"` for `@tag :skip`, `nil` when not skipped, `:unreadable` when
      it isn't a literal. What `mix surfex.test --deviations` includes a skipped
      deviation test by.

  A `verifies` value that isn't a literal string or list of strings, or a `deviation`
  that isn't a literal string, raises, naming the file and line: a declaration that can't
  be read must not be silently dropped.
  """

  alias Surfex.{Scan, SourceScan}
  alias Surfex.SourceScan.Calls

  # What defines a test: ExUnit's `test`, and ExUnitProperties' `property`, which ExUnit runs
  # as a test named "property …" (#141).
  @definers [:test, :property]

  @doc """
  Every test in every file matching `globs` under `root`, in file then source order.
  `code` is the project's code records (`Surfex.Scan.code/1`), which say what an imported
  module defines (`tests/3`).
  """
  @spec records(String.t(), [String.t()], [Scan.t()]) :: [Scan.t()]
  def records(root, globs, code \\ []) do
    root = Path.expand(root)
    known = known(code)

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> scan_text(Path.relative_to(path, root), known)
    end)
  end

  @doc """
  The tests in one source text, as records located in `file`. A local call the test
  module doesn't define comes from one of its imports (§11): given the project's `code`
  records, a call through an import of a scanned module is a call to the function that
  module defines, and names the module too, as a qualified call does; a call to a function
  it doesn't define (ExUnit's `assert` beside `import MyApp.Fixtures`) comes from
  elsewhere, and isn't listed under it. A module that isn't scanned has its candidate
  listed, `Module.fun/arity`, which reaches nothing.
  """
  @spec tests(String.t(), String.t(), [Scan.t()]) :: [Scan.t()]
  def tests(text, file, code \\ []), do: scan_text(text, file, known(code))

  defp scan_text(text, file, known) do
    text
    |> Code.string_to_quoted!(file: file, token_metadata: true)
    |> SourceScan.defmodules()
    |> Enum.flat_map(&module_tests(&1, file, known))
    |> number_duplicates()
  end

  # What the code records say an import can resolve to, indexed once: the scanned
  # modules, hidden ones included, and every id a call can name, an item's, a module's
  # hidden definition's or a hidden module's.
  defp known(code) do
    ran = for %Scan{kind: :code, runs: runs} <- code, key <- Map.keys(runs), uniq: true, do: key

    %{
      modules:
        MapSet.new(
          for(%Scan{kind: :code, role: :module, id: id} <- code, do: id) ++
            Enum.map(ran, &Calls.module_of/1)
        ),
      ids:
        MapSet.new(
          for(
            %Scan{kind: :code, id: id, hidden: hidden} <- code,
            key <- [id | Map.keys(hidden)],
            do: key
          ) ++ ran
        )
    }
  end

  # ── One module ──────────────────────────────────────────────────────────

  defp module_tests(
         {:defmodule, meta, [{:__aliases__, _, parts} = aliases, [do: body]]},
         file,
         known
       ) do
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
      tags: %{},
      setups: [],
      wrappers: [],
      aliases: names.aliases
    }

    {found, _pending} = walk(exprs(body), ctx, %{})
    module = %{tags: module_tags(exprs(body), file), setups: setups(exprs(body))}

    for t <- found do
      nodes = t.wrappers ++ module.setups ++ t.setups ++ [t.node]
      # As ExUnit merges tags (#149): the most specific level that sets a key wins, the
      # test's own over its describe's over its module's, `verifies` and `deviation` alike.
      tags = Map.merge(module.tags, t.tags)
      tag = Map.get(tags, :verifies, [])
      declares = tag |> List.wrap() |> Enum.uniq()
      describe = if t.describe, do: "#{t.describe}: ", else: ""

      %Scan{
        kind: :test,
        id: "#{name}: #{describe}#{t.name}",
        hash: SourceScan.closure_hash(mod, nodes),
        location: %{file: file, lines: SourceScan.line_range(t.node)},
        declares: Enum.map(declares, &{:verifies, &1}),
        unselectable: unselectable(tag),
        deviation: Map.get(tags, :deviation),
        skip: Map.get(tags, :skip),
        calls: calls(mod, t, names, scopes, known)
      }
    end
  end

  defp module_tests(_mod, _file, _known), do: []

  # ── What a test calls ───────────────────────────────────────────────────

  # What a test exercises, from its body and the private helpers it reaches
  # (`Surfex.SourceScan.Calls`). A local call that the module doesn't define may come from
  # an `import` whose `only:`/`except:` admits it (`imported/4`). Setups are left out: they
  # prepare a test, and what a test tests is what it calls itself.
  defp calls(mod, test, names, scopes, known) do
    # Each body with the aliases in scope where it is defined.
    bodies =
      for node <- SourceScan.closure_nodes(mod, [test.node]),
          do:
            {node,
             if(node == test.node, do: test.aliases, else: Map.get(scopes, node, names.aliases))}

    Calls.of(bodies, fn {fun, arity} = local ->
      if local in names.defined,
        do: [],
        else:
          names.imports
          |> Calls.importing(local)
          |> Enum.flat_map(&imported(&1, fun, arity, known))
    end)
  end

  # A local call through an import of `module` (#194). A scanned module's code says whether
  # it defines the function: a call to it names the module too, as `Module.fun()` would;
  # one it doesn't define comes from another import (ExUnit's `assert`), so nothing. An
  # unscanned module's code is unknown: the call is listed under it and reaches nothing.
  defp imported(module, fun, arity, known) do
    id = Calls.call(module, fun, arity)

    cond do
      not MapSet.member?(known.modules, module) -> [id]
      MapSet.member?(known.ids, id) -> [id, module]
      true -> []
    end
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
  # for the next test, as a map of the keys surfex reads.
  defp walk(exprs, ctx, pending) do
    Enum.reduce(exprs, {[], pending}, fn expr, {found, pending} ->
      case expr do
        {:@, _, [{:tag, _, [value]}]} ->
          # A later `@tag` replaces what an earlier one set; a key it doesn't set is left.
          {found, Map.merge(pending, read_tags(value, expr, ctx.file))}

        {:describe, _, [name, [do: block]]} ->
          inner = exprs(block)

          describe = %{
            ctx
            | describe: text(name),
              aliases: Map.merge(ctx.aliases, Calls.aliases(inner)),
              tags: describe_tags(inner, ctx.file),
              setups: ctx.setups ++ setups(inner)
          }

          {more, _} = walk(inner, describe, %{})
          {found ++ more, %{}}

        {definer, _, [name | _]} = node when definer in @definers ->
          test = %{
            name: text(name),
            node: node,
            describe: ctx.describe,
            tags: Map.merge(ctx.tags, pending),
            setups: ctx.setups,
            wrappers: ctx.wrappers,
            aliases: ctx.aliases
          }

          {found ++ [test], %{}}

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

  # A level's tags: for each key, the last `@moduletag` or `@describetag` that sets it. A
  # key no tag sets is absent, so the level leaves it to the one above, as ExUnit does.
  defp module_tags(exprs, file), do: last_set(exprs, :moduletag, file)
  defp describe_tags(exprs, file), do: last_set(exprs, :describetag, file)

  defp last_set(exprs, attribute, file) do
    for {:@, _, [{^attribute, _, [v]}]} = e <- exprs, reduce: %{} do
      earlier -> Map.merge(earlier, read_tags(v, e, file))
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

  # The keys surfex reads from a tag value, as written: `verifies:` a string or a list of
  # strings (its form matters to `unselectable/1`), `deviation:` a string or nil, and
  # ExUnit's own `skip:` (`skip/1`). A key the tag doesn't set is absent. A bare atom
  # (`@tag :skip`) sets that key to true, as ExUnit reads it.
  @read [:verifies, :deviation, :skip]

  defp read_tags(value, expr, file) do
    pairs =
      case value do
        list when is_list(list) -> if Keyword.keyword?(list), do: list, else: []
        {:%{}, _, pairs} -> pairs
        atom when is_atom(atom) -> [{atom, true}]
        _ -> []
      end

    for key <- @read, Keyword.has_key?(pairs, key), into: %{} do
      {key, read(key, Keyword.get(pairs, key), expr, file)}
    end
  end

  defp read(:verifies, value, expr, file), do: ids(value, expr, file)
  defp read(:deviation, ref, _expr, _file) when is_binary(ref) or is_nil(ref), do: ref

  defp read(:skip, value, _expr, _file), do: skip(value)

  defp read(:deviation, _other, expr, file) do
    {line, _} = SourceScan.line_range(expr) || {0, 0}
    raise ArgumentError, "#{file}:#{line}: deviation: must be a string"
  end

  defp ids(nil, _expr, _file), do: []
  defp ids(id, _expr, _file) when is_binary(id), do: id

  defp ids(list, expr, file) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: bad(expr, file)
  end

  defp ids(_other, expr, file), do: bad(expr, file)

  # ExUnit's skip tag as `mix test --include skip:VALUE` matches it: a literal string or
  # `true` by its text, `false` or nil as not skipped, anything else (computed when the
  # module compiles) as unreadable.
  defp skip(reason) when is_binary(reason), do: reason
  defp skip(true), do: "true"
  defp skip(none) when none in [false, nil], do: nil
  defp skip(_computed), do: :unreadable

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
