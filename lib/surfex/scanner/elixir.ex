defmodule Surfex.Scanner.Elixir do
  @moduledoc """
  The built-in scanner: an Elixir project's public API, read from source without
  compiling it.

  | Item | Kind | Key | Aliases |
  |---|---|---|---|
  | a module | `:module` | `MyApp.Cart` | — |
  | a public function | `:function` | `MyApp.Cart.add/2` | `MyApp.Cart.add` |
  | a public macro or guard | `:macro` | `MyApp.Cart.is_cart/1` | `MyApp.Cart.is_cart` |
  | a public type (`@type`, `@opaque`) | `:type` | `t:MyApp.Cart.t/0` | `MyApp.Cart.t` |

  What counts as public is `Surfex.SourceScan.defs/1`'s rule: `def`, `defmacro`,
  `defdelegate` and `defguard`, minus `@doc false` and undocumented `@impl` callbacks. A
  module under `@moduledoc false` is skipped with its functions; a module nested in it is
  not, since Elixir documents it separately. A nested module is keyed by its full name,
  as Elixir names it.

  **`Mod.fun` without an arity cites every arity.** A spec that says "`MyApp.Cart.add`
  rejects a closed cart" is about the function, not one of its arities, so every arity
  shares the alias and a citation of it cites them all (`Surfex.Item` `:aliases`). A
  citation naming two unrelated items is still ambiguous; a family is not.

  ## Options

    * `:paths` — globs relative to the root. Default: `["lib/**/*.ex"]`, one project's
      own source. A poncho lists its members (`["*/lib/**/*.ex"]`). A glob that guessed
      would also find test fixtures and scratch trees that happen to have a `lib/`.
  """

  @behaviour Surfex.Scanner

  alias Surfex.{Item, SourceScan}

  @doc """
  Every module and public definition under `root`, sorted by key. See the moduledoc for
  what is public, and `Surfex.Scanner.c:items/2` for the contract.
  """
  @impl Surfex.Scanner
  def items(root, opts \\ []) do
    root = Path.expand(root)

    root
    |> files(Keyword.get(opts, :paths, ["lib/**/*.ex"]))
    |> Enum.flat_map(fn file ->
      rel = Path.relative_to(file, root)

      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file, token_metadata: true)
      |> modules([])
      |> items_in(rel)
    end)
    |> Enum.sort_by(&{Item.key(&1), &1.kind})
  end

  @doc """
  The `Surfex.Profile` keys that reading an Elixir project's citations starts from, for a
  project whose modules live under its roots (`"MyApp"`, or a list such as
  `["MyApp", "MyAppWeb"]`):

    * `:shape` — `MyApp`, `MyApp.Cart`, `MyApp.Cart.add`, `MyApp.Cart.add/2`: a span of
      this shape that names nothing is an unresolved citation
    * `:token` — the same names, found inside a longer span or a code block
    * `:normalise` — drops a call's arguments, so `MyApp.Cart.add(cart, item)` names
      `MyApp.Cart.add`
  """
  @spec profile_defaults(String.t() | [String.t()]) :: keyword
  def profile_defaults(roots) do
    # Longest first, so `MyAppWeb` is tried before `MyApp`.
    alternatives =
      roots
      |> List.wrap()
      |> Enum.uniq()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map_join("|", &Regex.escape/1)

    name = "(?:#{alternatives})(?:\\.[A-Z]\\w*)*(?:\\.[a-z_]\\w*[?!]?(?:/\\d+)?)?"

    [
      shape: Regex.compile!("^#{name}$"),
      # A name ends where a name ends: not glued to letters, a hyphen or a further segment.
      token: Regex.compile!("(?<![\\w.])(#{name})(?![\\w-]|\\.\\w)"),
      # ExDoc's `t:Mod.t/0` names the type `Mod.t()` does; a call's arguments drop.
      normalise: [{~r/^t:(.+)\/\d+$/s, "\\1"}, {~r/\(.*\)$/s, ""}]
    ]
  end

  defp files(root, globs),
    do: globs |> Enum.flat_map(&Path.wildcard(Path.join(root, &1))) |> Enum.uniq()

  # `{full name parts, node}` for every module, nested ones named as Elixir names them.
  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, prefix) do
    if Enum.all?(parts, &is_atom/1) do
      name = prefix ++ parts
      [{name, node} | modules(body, name)]
    else
      modules(body, prefix)
    end
  end

  defp modules({_form, _meta, args}, prefix) when is_list(args),
    do: Enum.flat_map(args, &modules(&1, prefix))

  defp modules(list, prefix) when is_list(list), do: Enum.flat_map(list, &modules(&1, prefix))
  defp modules({a, b}, prefix), do: modules(a, prefix) ++ modules(b, prefix)
  defp modules(_leaf, _prefix), do: []

  defp items_in(modules, file) do
    modules
    |> Enum.reject(fn {_name, node} -> SourceScan.hidden_module?(node) end)
    |> Enum.flat_map(fn {parts, node} ->
      module = Enum.map_join(parts, ".", &Atom.to_string/1)

      [
        %Item{
          kind: :module,
          name: module,
          file: file,
          hash: SourceScan.module_hash(node),
          lines: SourceScan.line_range(node)
        }
      ] ++
        for %{name: name, arity: arity, kind: kind, hash: hash, lines: lines} <-
              SourceScan.defs(node) do
          %Item{
            kind: kind,
            name: "#{name}/#{arity}",
            parent: module,
            file: file,
            hash: hash,
            aliases: ["#{module}.#{name}"],
            lines: lines
          }
        end ++
        for %{name: name, arity: arity, hash: hash, lines: lines} <- SourceScan.types(node) do
          # Keyed as ExDoc writes a type, so a function of the same name keeps its own key.
          %Item{
            kind: :type,
            name: "t:#{module}.#{name}/#{arity}",
            file: file,
            hash: hash,
            aliases: ["#{module}.#{name}"],
            lines: lines,
            shape: true
          }
        end
    end)
  end
end
