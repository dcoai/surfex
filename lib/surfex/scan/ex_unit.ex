defmodule Surfex.Scan.ExUnit do
  @moduledoc """
  The test scanner for ExUnit: one `Surfex.Scan` record of kind `:test` per `test`, read
  from source without compiling it.

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

  defp module_tests({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = mod, file) do
    name = parts |> Enum.filter(&is_atom/1) |> Enum.map_join(".", &Atom.to_string/1)
    ctx = %{file: file, describe: nil, tags: [], setups: [], wrappers: []}
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
        declares: Enum.map(declares, &{:verifies, &1})
      }
    end
  end

  defp module_tests(_mod, _file), do: []

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
              tags: ctx.tags ++ describe_tags(inner, ctx.file),
              setups: ctx.setups ++ setups(inner)
          }

          {more, _} = walk(inner, describe, [])
          {found ++ more, []}

        {:test, _, [name | _]} = node ->
          test = %{
            name: text(name),
            node: node,
            describe: ctx.describe,
            tags: ctx.tags ++ pending,
            setups: ctx.setups,
            wrappers: ctx.wrappers
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
