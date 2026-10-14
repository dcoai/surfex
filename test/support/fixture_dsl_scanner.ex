defmodule Surfex.Test.FixtureDsl.Scanner do
  @moduledoc false
  # The fixture DSL's scanner (`Surfex.Test.FixtureDsl`): a plugin as a project, or a
  # small companion package, would write one for its DSL (spec §4.1). It reads source
  # with surfex's supported library API alone (`Surfex.SourceScan`, §23), never compiling
  # it, and gives one `Surfex.Item` per DSL block:
  #
  #   * `action :name do … end` — kind `:action`, keyed `Module.name`
  #   * `attribute :name, type` — kind `:attribute`, a shape: a declaration with no
  #     behaviour of its own
  #
  # It answers `calls/3` for the DSL's entry, so a call driving an action reaches it.
  #
  # Options: `:paths`, globs relative to the root (`["lib/**/*.ex"]` by default).
  @behaviour Surfex.Scanner

  alias Surfex.{Item, SourceScan}

  @dsl [:Surfex, :Test, :FixtureDsl]

  @impl Surfex.Scanner
  def items(root, opts) do
    root = Path.expand(root)

    for glob <- Keyword.get(opts, :paths, ["lib/**/*.ex"]),
        path <- root |> Path.join(glob) |> Path.wildcard() |> Enum.sort(),
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} <-
          path
          |> File.read!()
          |> Code.string_to_quoted!(file: path, token_metadata: true)
          |> SourceScan.defmodules(),
        exprs = exprs(body),
        Enum.any?(exprs, &match?({:use, _, [{:__aliases__, _, @dsl} | _]}, &1)),
        item <- blocks(exprs, Enum.map_join(parts, ".", &Atom.to_string/1), aliases(exprs)),
        do: %{item | file: Path.relative_to(path, root)}
  end

  # The DSL's entry names an action: `FixtureDsl.run(Shop.Order, :checkout, input)`, piped
  # or not, the entry and the resource read through the caller's aliases (spec §5.4).
  @impl Surfex.Scanner
  def calls(
        {{:., _, [{:__aliases__, _, entry}, :run]}, _, [{:__aliases__, _, resource}, action | _]},
        aliases,
        _opts
      )
      when is_atom(action) do
    if expand(entry, aliases) == Enum.map_join(@dsl, ".", &Atom.to_string/1),
      do: ["#{expand(resource, aliases)}.#{action}"],
      else: []
  end

  def calls(_call, _aliases, _opts), do: []

  defp blocks(exprs, module, aliases) do
    for expr <- exprs, item = block(expr, module, aliases), do: item
  end

  defp block({:action, _, [name, [do: body]]} = node, module, aliases) when is_atom(name),
    do: item(:action, node, module, name, calls(body, aliases), false)

  defp block({:attribute, _, [name, _type]} = node, module, _aliases) when is_atom(name),
    do: item(:attribute, node, module, name, [], true)

  defp block(_expr, _module, _aliases), do: nil

  # The block is the whole definition: its version covers it and nothing else, and it has
  # no hidden definitions of its own (§4.1).
  defp item(kind, node, module, name, calls, shape) do
    %Item{
      kind: kind,
      parent: module,
      name: Atom.to_string(name),
      file: nil,
      hash: SourceScan.definition_hash(node),
      lines: SourceScan.line_range(node),
      calls: calls,
      shape: shape
    }
  end

  # What a block references: each remote call and capture as `Module.fun/arity`, and each
  # module it names, aliases resolved. A call's own parts aren't walked again, so a
  # capture isn't also read as a call of arity 0; its arguments are.
  defp calls(body, aliases) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, arity]}]}, acc ->
          module = expand(parts, aliases)
          {nil, ["#{module}.#{fun}/#{arity}", module | acc]}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, acc when is_list(args) ->
          module = expand(parts, aliases)
          {args, ["#{module}.#{fun}/#{length(args)}", module | acc]}

        {:__aliases__, _, parts} = node, acc ->
          {node, [expand(parts, aliases) | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  defp aliases(exprs) do
    for {:alias, _, [{:__aliases__, _, parts}]} <- exprs,
        into: %{},
        do: {List.last(parts), Enum.map_join(parts, ".", &Atom.to_string/1)}
  end

  defp expand([first | rest] = parts, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join([full | Enum.map(rest, &Atom.to_string/1)], ".")
      :error -> Enum.map_join(parts, ".", &Atom.to_string/1)
    end
  end

  defp exprs({:__block__, _, list}), do: list
  defp exprs(one), do: [one]
end
