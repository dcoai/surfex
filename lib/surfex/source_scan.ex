defmodule Surfex.SourceScan do
  @moduledoc """
  Generic, dependency-free primitives for reading Elixir source **without compiling it**:
  find a project root, enumerate `lib` sources, extract `defmodule` nodes, and version a
  definition by its content.

  Not compiling is the point. A gate built on these runs before, and independently of, the
  code it inspects — so it can be a build gate rather than a test, and it cannot be fooled
  by a module that failed to load.

  Stdlib only, and `deps: []` by policy: anything that depends on this should not inherit a
  kernel along with it.

  It knows nothing about *what* is being catalogued. Finding a `use Authz.Api` opener, a
  `TLA.Spec` action, or a terminal escape sequence is the scanner's job, and a scanner
  belongs to the project whose vocabulary it reads. This is what every scanner shares.

  > Extracted from `agentronic`'s `Maatronic.SourceScan`, where ten surface goldens have
  > used it in production. The algorithms below are unchanged; only the prose and the
  > project-root marker were generalised.
  """

  @doc """
  The project root: ascend from `start` (the working directory by default) to the first
  directory containing `marker`, falling back to `start` when none is found.

  `start` exists so that nothing has to change the working directory to ask. The working
  directory belongs to the whole VM: changing it for one caller changes it for every
  process running alongside.

  `marker` is explicit and has no default, deliberately. A poncho's root is the directory
  holding its aggregate build marker (`"scripts/poncho.exs"`); a single library's is the
  directory holding `"mix.exs"`. A default would be right for one shape and silently wrong
  for the other, and "silently wrong about which tree you are scanning" is the failure a
  drift gate is least able to notice.

      project_root("mix.exs")             # a library
      project_root("scripts/poncho.exs")  # a poncho
      project_root("mix.exs", "lib/my_app/deep")
  """
  @spec project_root(String.t(), String.t()) :: String.t()
  def project_root(marker, start \\ File.cwd!()) do
    start = Path.expand(start)

    Stream.iterate(start, &Path.dirname/1)
    |> Stream.take_while(&(&1 != "/"))
    |> Enum.find(start, &File.exists?(Path.join(&1, marker)))
  end

  @doc """
  Every `.ex` source in a first-party `lib/` under `root`, sorted: the sources a scanner
  walks. It works for a single library (`lib/`) and a multi-member tree (`app/lib/`)
  alike, with nothing to configure.

  A `lib/` directory is first-party when both hold:

    * **its parent has a `mix.exs`.** It is a Mix project's own source. A `lib/` that a
      test fixture or a scratch tree happens to contain is not.
    * **no directory between `root` and it is `deps`, `_build`, `test`, `tmp`, or hidden
      (a dot-directory).** The first rule alone is not enough: dependencies are Mix
      projects, and some test fixtures are complete ones, `mix.exs` and all.

  Before this rule, anything matching `**/lib/**` counted. That included the `tmp/` trees
  ExUnit's `@tag :tmp_dir` leaves behind, so a golden could drift on the machine that had
  just run the tests and never in CI, whose checkout is clean (#9).
  """
  @spec lib_sources(String.t()) :: [String.t()]
  def lib_sources(root) do
    root
    |> Path.join("**/lib")
    |> Path.wildcard()
    |> Enum.filter(&first_party_lib?(&1, root))
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @foreign ~w(deps _build test tmp)

  defp first_party_lib?(lib, root) do
    between =
      lib
      |> Path.expand()
      |> Path.relative_to(Path.expand(root))
      |> Path.split()
      |> Enum.drop(-1)

    File.dir?(lib) and File.regular?(Path.join(Path.dirname(lib), "mix.exs")) and
      not Enum.any?(between, &(&1 in @foreign or String.starts_with?(&1, ".")))
  end

  @public %{def: :function, defdelegate: :function, defmacro: :macro, defguard: :macro}
  @definers [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp]

  @typedoc "One public definition of a module: a name at one arity, hashed over all its clauses."
  @type definition :: %{
          name: atom,
          arity: non_neg_integer,
          kind: :function | :macro,
          hash: String.t(),
          # First and last line of all its clauses (see line_range/1), or nil.
          lines: {pos_integer, pos_integer} | nil
        }

  @doc """
  The public definitions in a `defmodule` node's own body, sorted by name and arity. A
  nested module's definitions are that module's, not this one's.

  Clauses are grouped by `{name, arity}` and hashed together with `definition_hash/1`, so
  editing any clause changes the function's hash and moving it does not. A default
  argument (`\\\\`) declares every arity it generates, each with the function's one hash.

  Public means `def`, `defmacro`, `defdelegate` and `defguard`, minus what the module
  hides from its docs: `@doc false`, and an `@impl` callback without an explicit `@doc`
  (Elixir hides those by default, as the behaviour's surface rather than the module's).
  A definition whose name is computed (`def unquote(name)(…)`) is not knowable without
  compiling and is skipped.
  """
  @spec defs(Macro.t()) :: [definition]
  def defs({:defmodule, _, [_aliases, [do: body]]}) do
    {grouped, groups, attributes} = definitions(body)

    grouped
    |> Enum.flat_map(fn {{name, arity} = key, [first | _]} ->
      if first.kind != :private and first.visible do
        hash = Surfex.SourceScan.Closure.hash(key, groups, attributes)
        defaults = groups[key].defaults
        lines = line_range(groups[key].nodes)

        for a <- (arity - defaults)..arity//1,
            do: %{name: name, arity: a, kind: first.kind, hash: hash, lines: lines}
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  @doc """
  The module's public types: each `@type` and `@opaque`, minus one under `@typedoc false`,
  as Elixir's docs leave it out. A `@typep` is private. Each has its name, arity, version
  (the hash of its declaration, so it changes with the type alone) and lines.
  """
  @spec types(Macro.t()) :: [
          %{
            name: atom,
            arity: non_neg_integer,
            hash: String.t(),
            lines: {pos_integer, pos_integer} | nil
          }
        ]
  def types({:defmodule, _, [_aliases, [do: body]]}) do
    {types, _hidden} =
      Enum.reduce(exprs(body), {[], false}, fn
        {:@, _, [{:typedoc, _, [false]}]}, {acc, _hidden} ->
          {acc, true}

        {:@, _, [{kind, _, [{:"::", _, [head, _body]}]}]} = node, {acc, hidden}
        when kind in [:type, :opaque] ->
          {if(hidden, do: acc, else: [type(head, node) | acc]), false}

        _other, state ->
          state
      end)

    Enum.sort_by(types, &{&1.name, &1.arity})
  end

  defp type({name, _meta, args}, node),
    do: %{
      name: name,
      arity: if(is_list(args), do: length(args), else: 0),
      hash: definition_hash(node),
      lines: line_range(node)
    }

  @doc false
  # The content version of arbitrary `nodes` in a module, hashed as `defs/1` hashes a
  # function: over the nodes, the private definitions they reach, and the attributes read
  # on the way. `Surfex.Scan.ExUnit` versions a test (its body and its `setup`s) this way.
  @spec closure_hash(Macro.t(), [Macro.t()]) :: String.t()
  def closure_hash({:defmodule, _, [_aliases, [do: body]]}, nodes) do
    {_grouped, groups, attributes} = definitions(body)
    Surfex.SourceScan.Closure.hash_nodes(nodes, groups, attributes)
  end

  @doc false
  # `nodes` and the clauses of the private definitions they reach in the module.
  @spec closure_nodes(Macro.t(), [Macro.t()]) :: [Macro.t()]
  def closure_nodes({:defmodule, _, [_aliases, [do: body]]}, nodes) do
    {_grouped, groups, _attributes} = definitions(body)
    Surfex.SourceScan.Closure.reach(nodes, groups)
  end

  # The module's definitions grouped by name and arity (each clause kept), the same as
  # hashing needs them (%{nodes, defaults, private}), and its attributes' values.
  defp definitions(body) do
    {clauses, _} =
      Enum.flat_map_reduce(exprs(body), %{doc: nil, impl: false, seen: %{}}, &clause/2)

    grouped = Enum.group_by(clauses, &{&1.name, &1.arity})

    groups =
      Map.new(grouped, fn {key, [first | _] = group} ->
        {key,
         %{
           nodes: Enum.map(group, & &1.node),
           defaults: group |> Enum.map(& &1.defaults) |> Enum.max(),
           private: first.kind == :private
         }}
      end)

    {grouped, groups, attributes(body)}
  end

  # Every value assigned to each module attribute in the module's own body, in order.
  # Attributes Elixir itself reads (docs, specs, callbacks) are never read by a clause as
  # `@name`, so collecting them all does no harm.
  defp attributes(body) do
    for {:@, _, [{name, _, [value]}]} <- exprs(body), is_atom(name), reduce: %{} do
      acc -> Map.update(acc, name, [value], &(&1 ++ [value]))
    end
  end

  @doc """
  The first and last source lines a quoted node spans, from its metadata, or `nil` when it
  carries none. Parse with `token_metadata: true` so a `do … end` block's closing line is
  known. Metadata never reaches a hash, so parsing this way changes no version.
  """
  @spec line_range(Macro.t()) :: {pos_integer, pos_integer} | nil
  def line_range(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {_, meta, _} = node, acc when is_list(meta) -> {node, meta_lines(meta) ++ acc}
        node, acc -> {node, acc}
      end)

    case lines do
      [] -> nil
      lines -> {Enum.min(lines), Enum.max(lines)}
    end
  end

  defp meta_lines(meta) do
    Enum.flat_map(meta, fn
      {:line, line} when is_integer(line) ->
        [line]

      {_key, nested} when is_list(nested) ->
        if Keyword.keyword?(nested), do: meta_lines(nested), else: []

      _ ->
        []
    end)
  end

  @doc """
  A module's version: a `definition_hash/1` over its **public surface**, not its whole
  body. That covers:

    * its `@moduledoc`
    * its public definitions, as name, arity and kind (`defs/1`)
    * its `@behaviour`s and `use`s
    * its `defstruct` or `defexception` fields
    * its `@type`, `@opaque`, `@callback` and `@macrocallback` declarations

  Each list is sorted, so reordering is not a change. Function bodies are left out: each
  public function has its own item and version, so a body edit changes that function's
  version and not its module's. Private definitions and nested modules are left out too.
  """
  @spec module_hash(Macro.t()) :: String.t()
  def module_hash({:defmodule, _, [_aliases, [do: body]]} = node) do
    top = exprs(body)

    pick = fn match -> top |> Enum.flat_map(match) |> Enum.map(&strip_meta/1) |> Enum.sort() end

    [
      pick.(fn
        {:@, _, [{:moduledoc, _, [doc]}]} -> [doc]
        _ -> []
      end),
      node
      |> defs()
      |> Enum.map(&[Atom.to_string(&1.name), &1.arity, Atom.to_string(&1.kind)])
      |> Enum.sort(),
      pick.(fn
        {:@, _, [{:behaviour, _, [mod]}]} -> [[:behaviour, mod]]
        {:use, _, args} -> [[:use, args]]
        _ -> []
      end),
      pick.(fn
        {definer, _, args} when definer in [:defstruct, :defexception] -> [[definer, args]]
        _ -> []
      end),
      pick.(fn
        {:@, _, [{kind, _, [spec]}]} when kind in [:type, :opaque, :callback, :macrocallback] ->
          [[kind, spec]]

        _ ->
          []
      end)
    ]
    |> definition_hash()
  end

  @doc "Whether a `defmodule` node declares `@moduledoc false` in its own body."
  @spec hidden_module?(Macro.t()) :: boolean
  def hidden_module?({:defmodule, _, [_aliases, [do: body]]}),
    do: Enum.any?(exprs(body), &match?({:@, _, [{:moduledoc, _, [false]}]}, &1))

  defp exprs({:__block__, _, exprs}), do: exprs
  defp exprs(nil), do: []
  defp exprs(expr), do: [expr]

  # `@doc` and `@impl` apply to the next definition; the first clause of a function decides
  # its visibility for every later clause, which carry no attributes of their own.
  defp clause({:@, _, [{:doc, _, [false]}]}, st), do: {[], %{st | doc: :hidden}}
  defp clause({:@, _, [{:doc, _, [_]}]}, st), do: {[], %{st | doc: :shown}}
  defp clause({:@, _, [{:impl, _, [false]}]}, st), do: {[], st}
  defp clause({:@, _, [{:impl, _, [_]}]}, st), do: {[], %{st | impl: true}}

  defp clause({definer, _, [head | _]} = node, st) when definer in @definers do
    hidden = st.doc == :hidden or (st.doc == nil and st.impl)
    st = %{st | doc: nil, impl: false}

    case signature(head) do
      {name, args} ->
        arity = length(args)
        key = {name, arity}
        visible = Map.get(st.seen, key, not hidden)

        # Private definitions are kept too: a public function's hash follows its calls
        # into them (Surfex.SourceScan.Closure).
        clause = %{
          name: name,
          arity: arity,
          kind: Map.get(@public, definer, :private),
          defaults: Enum.count(args, &match?({:\\, _, _}, &1)),
          visible: visible,
          node: node
        }

        {[clause], %{st | seen: Map.put_new(st.seen, key, visible)}}

      _ ->
        {[], st}
    end
  end

  defp clause(_expr, st), do: {[], st}

  defp signature({:when, _, [call | _]}), do: signature(call)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp signature(_), do: nil

  @doc """
  Every `{:defmodule, meta, [aliases, [do: body]]}` node in a quoted `ast`, in source
  order — the enumeration a scanner walks to find declaring modules. Nested `defmodule`s
  are included, in the order they appear.
  """
  @spec defmodules(Macro.t()) :: [Macro.t()]
  def defmodules(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, _}, _]} = node, acc -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  @doc """
  A definition's **content version**: a short `sha256` (8 lowercase hex chars) over the item's AST
  with ALL positional and formatting metadata stripped, so the hash is a stable function of the
  definition's STRUCTURE — not of its position in the file or its layout. Inserting a blank line or
  a comment above the definition, or reindenting it, leaves the hash unchanged; changing the
  definition's body changes it.

  This is what lets a golden's `Locus` be a stable path plus a version, rather than a
  `path.ex:line` that drifts whenever anything above the item moves. **A line number
  reports movement; this hash reports change.** It is also what makes a golden auto-merge
  across branches: two people editing different items touch different rows.

  Accepts a quoted AST node, or a binary source snippet parsed with `Code.string_to_quoted!/1`.
  """
  @spec definition_hash(Macro.t() | String.t()) :: String.t()
  def definition_hash(source) when is_binary(source),
    do: source |> Code.string_to_quoted!() |> definition_hash()

  def definition_hash(ast) do
    ast
    |> strip_meta()
    |> Macro.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  # Drop ALL AST metadata (line, column, delimiter/closing, end_of_expression, …) so the hash is a
  # function of structure alone. A positional or cosmetic shift must not restamp the version, or the
  # drift-on-movement problem comes back hidden behind a checksum — which is worse than having it in
  # the open, because a checksum looks authoritative. A quoted call node is `{form, meta, args}`; a
  # 2-tuple is an AST literal pair; a list is an argument list; anything else is a leaf literal
  # (atom/number/binary) carrying no metadata.
  defp strip_meta({form, _meta, args}), do: {strip_meta(form), [], strip_meta(args)}
  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta({a, b}), do: {strip_meta(a), strip_meta(b)}
  defp strip_meta(leaf), do: leaf
end
