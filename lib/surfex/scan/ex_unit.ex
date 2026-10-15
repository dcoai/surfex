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
      `"cart-add"`. A project that already records what its tests verify in a form of
      its own declares the form (`declares:`, §11.6, `forms` here): an ExUnit tag key,
      read at the same levels and merged as `verifies` is, or a module attribute before a
      test, which applies to the next test as a `@tag` does. Each id, with the form's
      `strip:` pattern removed, is a `{:verifies, id}` too.
    * **unselectable** — the declared ids `mix test --only verifies:id` can't select the
      test by. ExUnit compares a list tag as one string, its ids run together, so a test
      tagged `["cart-add", "carts"]` is selected by neither, though it declares both. An
      id declared in a project's own form is never selectable by it either.
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
  module defines (`tests/4`). `scanners` are the project's code scanners
  (`Surfex.Status.Config.scanners!/1`): each implementing `Surfex.Scanner.c:calls/3` is
  asked what a test's remote calls name (§5.4). `routes` are the project's router's
  (`Surfex.Status.Config.routes/2`): a request a test makes to one of them is a call to
  what it runs (§11). `forms` are the project's own declaration forms
  (`Surfex.Status.Config.declares!/1`, §11.6).
  """
  @spec records(
          String.t(),
          [String.t()],
          [Scan.t()],
          [{atom, keyword}],
          [
            Surfex.SourceScan.Routes.route()
          ],
          [map]
        ) :: [Scan.t()]
  def records(root, globs, code \\ [], scanners \\ [], routes \\ [], forms \\ []) do
    root = Path.expand(root)
    known = known(code, scanners, routes, forms)

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
  listed, `Module.fun/arity`, which reaches nothing. A remote call also names the item
  keys a scanner's `Surfex.Scanner.c:calls/3` answers for it (§5.4). The test's requests,
  events and messages are calls too (§11): a request to one of `routes` calls what the
  route runs, an event to a view a request mounted calls its `handle_event/3`, and a
  `GenServer.call/cast` to a module calls its `handle_call/3` or `handle_cast/2`.
  """
  @spec tests(
          String.t(),
          String.t(),
          [Scan.t()],
          [{atom, keyword}],
          [
            Surfex.SourceScan.Routes.route()
          ],
          [map]
        ) :: [Scan.t()]
  def tests(text, file, code \\ [], scanners \\ [], routes \\ [], forms \\ []),
    do: scan_text(text, file, known(code, scanners, routes, forms))

  defp scan_text(text, file, known) do
    text
    |> Code.string_to_quoted!(file: file, token_metadata: true)
    |> SourceScan.defmodules()
    |> Enum.flat_map(&module_tests(&1, file, known))
    |> number_duplicates()
  end

  # Where support code lives: compiled for the tests, never run as one (§11.5).
  @support ["test/support/**/*.ex", "test/support/**/*.exs"]

  @typedoc "A `verifies` tag that verifies nothing, and why (§11.5)."
  @type inert :: %{
          file: String.t(),
          line: non_neg_integer,
          ids: [String.t()],
          reason: :no_test | :support
        }

  @doc """
  The `verifies` tags that verify nothing (§11.5): a declaration counts only from a test or
  property block it applies to. In the files `globs` match under `root`, that is a `@tag`
  no test follows in its block, and a `@describetag` or `@moduletag` over a describe or
  module with no test (`:no_test`). Every `verifies` tag in a file under `test/support`,
  which is compiled as support code and never run as a test, is one too (`:support`),
  unless `globs` scan that file as tests. A tag or attribute in one of the project's
  declared `forms` (§11.6) counts as a `verifies` tag does. In file and line order.
  """
  @spec inert(String.t(), [String.t()], [map]) :: [inert]
  def inert(root, globs, forms \\ []) do
    root = Path.expand(root)
    tests = files(root, globs)

    found =
      Enum.flat_map(tests, fn path ->
        src = %{file: Path.relative_to(path, root), forms: forms}

        path
        |> quoted(src.file)
        |> SourceScan.defmodules()
        |> Enum.flat_map(&module_inert(&1, src))
      end) ++
        Enum.flat_map(files(root, @support) -- tests, fn path ->
          src = %{file: Path.relative_to(path, root), forms: forms}
          support_inert(quoted(path, src.file), src)
        end)

    Enum.sort_by(found, &{&1.file, &1.line})
  end

  defp files(root, globs),
    do:
      globs
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
      |> Enum.uniq()
      |> Enum.sort()

  defp quoted(path, file),
    do: path |> File.read!() |> Code.string_to_quoted!(file: file, token_metadata: true)

  # A module's inert tags: its own tags over no test, and those in its blocks.
  defp module_inert({:defmodule, _, [_aliases, [do: body]]}, src) do
    {inert, pending, tested?} = block_inert(exprs(body), src, [])
    module = if tested?, do: [], else: level_tags(exprs(body), :moduletag, src)
    module ++ inert ++ pending
  end

  defp module_inert(_mod, _src), do: []

  # A block's inert tags, the `@tag`s still waiting for a test at its end, and whether it
  # defines any test. As `walk/3` reads them: a `@tag` applies to the next test, a
  # comprehension's tests take the tags before it, and a describe starts afresh.
  defp block_inert(exprs, src, pending) do
    Enum.reduce(exprs, {[], pending, false}, fn expr, {inert, pending, tested?} ->
      case expr do
        {:@, _, [{:tag, _, [value]}]} ->
          {inert, pending ++ verifies_tag(value, expr, src, :no_test), tested?}

        {:@, _, [{name, _, [value]}]} when is_atom(name) ->
          {inert, pending ++ form_attribute(name, value, expr, src, :no_test), tested?}

        {:describe, _, [_name, [do: block]]} ->
          inner = exprs(block)
          {more, left, inner_tested?} = block_inert(inner, src, [])
          own = if inner_tested?, do: [], else: level_tags(inner, :describetag, src)
          {inert ++ pending ++ own ++ more ++ left, [], tested? or inner_tested?}

        {definer, _, [_name | _]} when definer in @definers ->
          {inert, [], true}

        {:for, _, args} when is_list(args) ->
          {_generators, [[do: block]]} = Enum.split(args, -1)
          {more, left, inner_tested?} = block_inert(exprs(block), src, pending)
          {inert ++ more, left, tested? or inner_tested?}

        _ ->
          {inert, pending, tested?}
      end
    end)
  end

  defp level_tags(exprs, attribute, src) do
    for {:@, _, [{^attribute, _, [value]}]} = expr <- exprs,
        tag <- verifies_tag(value, expr, src, :no_test),
        do: tag
  end

  # Every verifies tag in support code, at any level, and every declared attribute form.
  defp support_inert(ast, src) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attribute, _, [value]}]} = expr, acc
        when attribute in [:tag, :describetag, :moduletag] ->
          {expr, acc ++ verifies_tag(value, expr, src, :support)}

        {:@, _, [{name, _, [value]}]} = expr, acc when is_atom(name) ->
          {expr, acc ++ form_attribute(name, value, expr, src, :support)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # A tag declaring some id, `verifies` or a declared form's (§11.6), as one inert entry;
  # none otherwise.
  defp verifies_tag(value, expr, src, reason),
    do: inert_entry(declared_ids(read_tags(value, expr, src), src.forms), expr, src, reason)

  # A declared attribute form (§11.6) naming some id, as one inert entry; none otherwise.
  defp form_attribute(name, value, expr, src, reason),
    do:
      inert_entry(
        declared_ids(read_attribute(name, value, expr, src), src.forms),
        expr,
        src,
        reason
      )

  defp inert_entry([], _expr, _src, _reason), do: []

  defp inert_entry(ids, expr, src, reason) do
    {line, _} = SourceScan.line_range(expr) || {0, 0}
    [%{file: src.file, line: line, ids: Enum.uniq(ids), reason: reason}]
  end

  # What the code records say an import can resolve to, indexed once: the scanned
  # modules, hidden ones included, and every id a call can name, an item's, a module's
  # hidden definition's or a hidden module's. And what the scanners say a remote call names.
  defp known(code, scanners, routes, forms) do
    ran = for %Scan{kind: :code, runs: runs} <- code, key <- Map.keys(runs), uniq: true, do: key

    %{
      forms: forms,
      remote: Calls.remote(scanners),
      routes: routes,
      # The declared dispatch functions' targets (§11.10), as the module records hold them.
      dispatch:
        for(
          %Scan{kind: :code, dispatch: dispatch} <- code,
          {id, %{targets: targets}} <- dispatch,
          into: %{},
          do: {id, targets}
        ),
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
      forms: known.forms,
      describe: nil,
      tags: %{},
      setups: [],
      wrappers: [],
      aliases: names.aliases
    }

    {found, _pending} = walk(exprs(body), ctx, %{})
    module = %{tags: module_tags(exprs(body), ctx), setups: setups(exprs(body))}

    for t <- found do
      nodes = t.wrappers ++ module.setups ++ t.setups ++ [t.node]
      # As ExUnit merges tags (#149): the most specific level that sets a key wins, the
      # test's own over its describe's over its module's, `verifies` and `deviation` alike.
      tags = Map.merge(module.tags, t.tags)
      tag = Map.get(tags, :verifies, [])
      # A declared form's ids (§11.6) are declarations too, which `--only verifies:id`
      # never selects: it reads the `verifies` tag alone.
      formed = declared_ids(Map.delete(tags, :verifies), known.forms)
      declares = (List.wrap(tag) ++ formed) |> Enum.uniq()
      selectable = List.wrap(tag) -- unselectable(tag)
      describe = if t.describe, do: "#{t.describe}: ", else: ""

      %Scan{
        kind: :test,
        id: "#{name}: #{describe}#{t.name}",
        hash: SourceScan.closure_hash(mod, nodes),
        location: %{file: file, lines: SourceScan.line_range(t.node)},
        declares: Enum.map(declares, &{:verifies, &1}),
        unselectable: Enum.uniq(unselectable(tag) ++ Enum.reject(formed, &(&1 in selectable))),
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

    Calls.of(
      bodies,
      fn {fun, arity} = local ->
        if local in names.defined,
          do: [],
          else:
            names.imports
            |> Calls.importing(local)
            |> Enum.flat_map(&imported(&1, fun, arity, known))
      end,
      known.remote,
      &Surfex.SourceScan.Routes.calls(&1, &2, known.routes),
      known.dispatch
    )
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
          {found, Map.merge(pending, read_tags(value, expr, ctx))}

        # A declared attribute form (§11.6) applies to the next test, as a `@tag` does.
        {:@, _, [{name, _, [value]}]} when is_atom(name) ->
          {found, Map.merge(pending, read_attribute(name, value, expr, ctx))}

        {:describe, _, [name, [do: block]]} ->
          inner = exprs(block)

          describe = %{
            ctx
            | describe: text(name),
              aliases: Map.merge(ctx.aliases, Calls.aliases(inner)),
              tags: describe_tags(inner, ctx),
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
  defp module_tags(exprs, src), do: last_set(exprs, :moduletag, src)
  defp describe_tags(exprs, src), do: last_set(exprs, :describetag, src)

  defp last_set(exprs, attribute, src) do
    for {:@, _, [{^attribute, _, [v]}]} = e <- exprs, reduce: %{} do
      earlier -> Map.merge(earlier, read_tags(v, e, src))
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
  # (`@tag :skip`) sets that key to true, as ExUnit reads it. Each tag form the project
  # declares (§11.6) is read as `verifies` is, under the key `{:form, :tag, name}`.
  @read [:verifies, :deviation, :skip]

  defp read_tags(value, expr, src) do
    pairs =
      case value do
        list when is_list(list) -> if Keyword.keyword?(list), do: list, else: []
        {:%{}, _, pairs} -> pairs
        atom when is_atom(atom) -> [{atom, true}]
        _ -> []
      end

    own =
      for key <- @read, Keyword.has_key?(pairs, key), into: %{} do
        {key, read(key, Keyword.get(pairs, key), expr, src.file)}
      end

    for %{kind: :tag, name: name} <- src.forms,
        Keyword.has_key?(pairs, name),
        into: own,
        do: {{:form, :tag, name}, ids(Keyword.get(pairs, name), expr, src.file, name)}
  end

  # A module attribute the project declares as a form (§11.6), read as a `verifies` tag
  # value; any other attribute is no declaration.
  defp read_attribute(name, value, expr, src) do
    if Enum.any?(src.forms, &match?(%{kind: :attribute, name: ^name}, &1)),
      do: %{{:form, :attribute, name} => ids(value, expr, src.file, name)},
      else: %{}
  end

  # The ids a level's tags declare in the project's forms (§11.6), each with its form's
  # `strip:` pattern removed: `Engine.15.2@abc123` read as `Engine.15.2`.
  defp declared_ids(tags, forms) do
    verifies = tags |> Map.get(:verifies, []) |> List.wrap()

    formed =
      for %{kind: kind, name: name, strip: strip} <- forms,
          id <- tags |> Map.get({:form, kind, name}, []) |> List.wrap(),
          do: if(strip, do: Regex.replace(strip, id, ""), else: id)

    verifies ++ formed
  end

  defp read(:verifies, value, expr, file), do: ids(value, expr, file, :verifies)
  defp read(:deviation, ref, _expr, _file) when is_binary(ref) or is_nil(ref), do: ref

  defp read(:skip, value, _expr, _file), do: skip(value)

  defp read(:deviation, _other, expr, file) do
    {line, _} = SourceScan.line_range(expr) || {0, 0}
    raise ArgumentError, "#{file}:#{line}: deviation: must be a string"
  end

  defp ids(nil, _expr, _file, _key), do: []
  defp ids(id, _expr, _file, _key) when is_binary(id), do: id

  defp ids(list, expr, file, key) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: bad(expr, file, key)
  end

  defp ids(_other, expr, file, key), do: bad(expr, file, key)

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

  defp bad(expr, file, key) do
    {line, _} = SourceScan.line_range(expr) || {0, 0}
    raise ArgumentError, "#{file}:#{line}: #{key}: must be a string or a list of strings"
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
