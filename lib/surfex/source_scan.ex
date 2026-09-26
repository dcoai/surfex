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
  The project root: ascend from the working directory to the first directory containing
  `marker`, falling back to the working directory when none is found.

  `marker` is explicit and has no default, deliberately. A poncho's root is the directory
  holding its aggregate build marker (`"scripts/poncho.exs"`); a single library's is the
  directory holding `"mix.exs"`. A default would be right for one shape and silently wrong
  for the other, and "silently wrong about which tree you are scanning" is the failure a
  drift gate is least able to notice.

      project_root("mix.exs")             # a library
      project_root("scripts/poncho.exs")  # a poncho
  """
  @spec project_root(String.t()) :: String.t()
  def project_root(marker) do
    Stream.iterate(File.cwd!(), &Path.dirname/1)
    |> Stream.take_while(&(&1 != "/"))
    |> Enum.find(File.cwd!(), &File.exists?(Path.join(&1, marker)))
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
          hash: String.t()
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
    {clauses, _} =
      Enum.flat_map_reduce(exprs(body), %{doc: nil, impl: false, seen: %{}}, &clause/2)

    clauses
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.flat_map(fn {{name, arity}, [first | _] = group} ->
      defaults = group |> Enum.map(& &1.defaults) |> Enum.max()
      hash = group |> Enum.map(& &1.node) |> definition_hash()

      if first.visible,
        do:
          for(
            a <- (arity - defaults)..arity//1,
            do: %{name: name, arity: a, kind: first.kind, hash: hash}
          ),
        else: []
    end)
    |> Enum.sort_by(&{&1.name, &1.arity})
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
      {name, args} when is_map_key(@public, definer) ->
        arity = length(args)
        key = {name, arity}
        visible = Map.get(st.seen, key, not hidden)

        clause = %{
          name: name,
          arity: arity,
          kind: Map.fetch!(@public, definer),
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
