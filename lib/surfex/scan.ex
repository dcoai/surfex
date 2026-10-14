defmodule Surfex.Scan do
  @moduledoc """
  A scan record: one fact about the source as it is now, `{kind, id, hash, location}`.

  Scanners produce these and nothing else. They never read or write relations, which are
  judgements kept in the relation log. A record is a pure function of the source.

    * `kind` — `:spec` or `:code` (more kinds, such as tests or configuration, can come)
    * `id` — the identity: a function's key (`MyApp.Cart.add/2`), or a spec section's
      file and heading path (`spec.md#Carts/Adding items`)
    * `hash` — the content version: 8 hex characters that change when the content does
      and not when it moves
    * `location` — where it is (`file`, first and last `lines`), for people and tools.
      **Never part of a relation:** moving code, or adding text above a section, changes
      its location and nothing else.

  A spec record also says what part of the spec it is:

    * `role` — what part of the source a record is. For spec, `:section` (a heading and
      its body), `:block` (a marked requirement inside a section) or `:test_hint` (a
      fenced `test` block saying how to test something). For code, the item's kind
      (`:module`, `:function`, …). `nil` for tests and classes.
    * `contract` — for a contract unit (role `:contract`, a signature in a contract
      fence), the function it is the contract of, `MyApp.Cart.add/2`; `nil` otherwise.
    * `within` — what it sits in: the section or block of a block or hint, the parent of a
      code item (its module, for a function). `nil` when nothing encloses it. It is a
      fact about the source, not a relation.
    * `under` — for a section, the section whose heading it sits under: the nearest
      heading above it at a higher level (§13.4). `nil` for a top-level section and for
      every other record.
    * `class` — for a section its spec class gives (§11.7), `%{name, reason, note, by}`:
      the class's name and reason, the marker's own reason (`note`, or `nil`), and `by`
      `:marker`, `:pattern` or `:alias`. `nil` for an unclassed unit.
    * `deferred` — for a section or block a deferral marker defers (§11.7),
      `%{ref, reason}`: the issue reference and the marker's reason, or `nil`.

  A test record (`Surfex.Scan.ExUnit`) can also **declare** what it relates to, in its
  own source: `declares` is a list of `{type, id}`, such as `{:verifies, "cart-add"}`
  from `@tag verifies: "cart-add"`. A declaration is a claim in the source, not a
  relation; `resolve/2` finds the spec unit it names. `unselectable` lists the declared
  ids the test's runner can't select it by (a list tag, to `mix test --only`). `deviation`
  is the reference a test gives with `@tag deviation: "#119"`: the code is known to deviate
  from what the test verifies (§13.1); `nil` when it gives none. `skip` is ExUnit's skip
  tag as a filter matches it (`"true"` for `@tag :skip`, `:unreadable` when not a literal),
  by which a skipped deviation test is included in a run. A test record also lists
  what it
  `calls`: the functions its source calls (`MyApp.Cart.add/3`), as facts to suggest
  `tests` relations from. A code record lists what its item calls (`Surfex.Item`), so
  `reach/1` can follow a test through the code it calls.

  A check record (`Surfex.Scan.Checks`, kind `:check`) is a declared gate: its `declares`
  are what it verifies, and `check` holds its command, its declaration's version and its
  inputs' versions, from which its own version is made (§11.4). `nil` for every other
  record.

  `code/1` makes code records from any `Surfex.Scanner`'s items. `Surfex.Scan.Markdown`
  makes spec records and `Surfex.Scan.ExUnit` test records.
  """

  alias Surfex.Item
  alias Surfex.Scan.Resolver

  @enforce_keys [:kind, :id, :hash, :location]
  defstruct [
    :kind,
    :id,
    :hash,
    :location,
    :role,
    :within,
    :under,
    declares: [],
    unselectable: [],
    deviation: nil,
    skip: nil,
    calls: [],
    hidden: %{},
    runs: %{},
    shape: false,
    named: false,
    contract: nil,
    check: nil,
    class: nil,
    deferred: nil
  ]

  @type location :: %{file: String.t(), lines: {pos_integer, pos_integer} | nil}
  @type role :: atom | nil
  @type t :: %__MODULE__{
          kind: atom,
          id: String.t(),
          hash: String.t(),
          location: location,
          role: role,
          within: String.t() | nil,
          # A section's enclosing section, by heading level (§13.4).
          under: String.t() | nil,
          declares: [{atom, String.t()}],
          # Declared ids the test's runner can't select it by (§11).
          unselectable: [String.t()],
          # A test's declared deviation: the reference to what fixes it (§13.1).
          deviation: String.t() | nil,
          # ExUnit's skip tag, as `--include skip:VALUE` matches it (§11).
          skip: String.t() | :unreadable | nil,
          calls: [String.t()],
          # A code record's hidden code, by the key a call names it with (`Surfex.Item`).
          hidden: %{String.t() => [String.t()]},
          # The hidden modules' code a code record runs, by key, with its calls (`Surfex.Item`).
          runs: %{String.t() => [String.t()]},
          # A code record of a shape (`Surfex.Item` `:shape`): judged, never exercised.
          shape: boolean,
          # A spec section whose id the author wrote (an anchor, a heading comment or the
          # project's heading grammar), not its heading path (§11).
          named: boolean,
          # A contract unit's function, `Module.name/arity` (§11.1).
          contract: String.t() | nil,
          # A check's command, its declaration's version and its inputs' versions (§11.4).
          check:
            %{run: String.t(), declaration: String.t(), inputs: %{String.t() => String.t()}}
            | nil,
          # A spec unit's class and a unit's deferral (§11.7).
          class:
            %{
              name: String.t(),
              reason: String.t(),
              note: String.t() | nil,
              by: :marker | :pattern | :alias
            }
            | nil,
          deferred: %{ref: String.t(), reason: String.t() | nil} | nil
        }

  @doc """
  The spec unit a declaration names: a full id (`spec.md#Carts/Adding items`,
  `spec.md#cart-add`), or a bare anchor, block or hint id (`cart-add`) looked up across
  every spec file. A `§`-id may carry its sign (`§Api.3.2`). `{:error, :unknown}` when
  nothing has it, `{:error, {:ambiguous, ids}}` when a bare id is in more than one file.

  It takes the scans, or a resolver built from them once (`resolver/1`), which resolves
  the same way by lookup: what to pass when many references resolve against one scan.
  """
  @spec resolve([t] | Resolver.t(), String.t()) ::
          {:ok, t} | {:error, :unknown | {:ambiguous, [String.t()]}}
  def resolve(%Resolver{} = resolver, ref), do: Resolver.resolve(resolver, ref)
  def resolve(scans, ref) when is_list(scans), do: scans |> resolver() |> resolve(ref)

  @doc """
  The spec units of `scans`, indexed once by full id and by bare id (`Surfex.Scan.Resolver`),
  for `resolve/2` to look references up in. Given a project's `unit_refs:`, it reads the
  project's own citation forms too (§11.1).
  """
  @spec resolver([t], [Regex.t()]) :: Resolver.t()
  def resolver(scans, unit_refs \\ []), do: Resolver.new(scans, unit_refs)

  @doc """
  What a code record is a version of: its file, lines and version. A function with
  default arguments is one definition the scanner reports as several items (`f/1`, `f/2`),
  and they share this key, so code compared by it is one code however many arities it has.
  Any other record is its own definition.
  """
  @spec definition(t) :: term
  def definition(%__MODULE__{kind: :code, location: %{file: f, lines: l}, hash: h}) when l != nil,
    do: {:code, f, l, h}

  def definition(%__MODULE__{kind: kind, id: id}), do: {kind, id}

  @doc """
  What each test reaches (§13.1): the scanned code its `calls` name and, transitively, the
  scanned code that code calls, sorted by id. A call naming code a record covers without
  it being a record (a module's hidden definition, `Surfex.Item` `:hidden`) reaches that
  record and goes on through the hidden code's calls. A call naming a hidden module's code
  (`Surfex.Item` `:runs`) reaches no record and goes on through its calls. A call to code
  that isn't scanned (a dependency, or code not written yet) reaches nothing. Pure: a
  function of the scans.
  """
  @spec reach([t]) :: %{String.t() => [String.t()]}
  def reach(scans) do
    from = reacher(scans)
    for %__MODULE__{kind: :test, id: id, calls: calls} <- scans, into: %{}, do: {id, from.(calls)}
  end

  @doc """
  What any calls reach, as `reach/1` follows a test's: a function from a list of call ids
  to the code records they reach, sorted. The index is built once, so asking it about many
  starting points (each code item a claim's tests call, §15.1) costs one closure each.
  """
  @spec reacher([t]) :: ([String.t()] -> [String.t()])
  def reacher(scans) do
    code = for %__MODULE__{kind: :code, id: id, calls: calls} <- scans, into: %{}, do: {id, calls}

    # A hidden module's code is on every record running it, each time the same, and is
    # owned by none of them.
    ran =
      for %__MODULE__{kind: :code, runs: runs} <- scans,
          {key, calls} <- runs,
          into: %{},
          do: {key, {nil, calls}}

    hidden =
      for %__MODULE__{kind: :code, id: id, hidden: hidden} <- scans,
          {key, calls} <- hidden,
          into: ran,
          do: {key, {id, calls}}

    fn calls -> calls |> closure({code, hidden}, {MapSet.new(), MapSet.new()}) |> Enum.sort() end
  end

  # The records reached from `frontier`. Hidden code is passed through, never reached:
  # `via` holds the hidden keys already followed, so a cycle through them ends.
  defp closure([], _index, {seen, _via}), do: seen

  defp closure([id | rest], {code, hidden} = index, {seen, via}) do
    case {Map.fetch(code, id), Map.fetch(hidden, id)} do
      {{:ok, calls}, _} ->
        if id in seen,
          do: closure(rest, index, {seen, via}),
          else: closure(calls ++ rest, index, {MapSet.put(seen, id), via})

      {:error, {:ok, {owner, calls}}} ->
        if id in via,
          do: closure(rest, index, {seen, via}),
          else: closure(List.wrap(owner) ++ calls ++ rest, index, {seen, MapSet.put(via, id)})

      {:error, :error} ->
        closure(rest, index, {seen, via})
    end
  end

  defp code_id(item, shared) do
    key = Item.key(item)
    if Map.has_key?(shared, key), do: "#{key} (#{item.kind})", else: key
  end

  @doc """
  The code record in `scans` for `item`, whatever its id: the bare key, or the key with
  its kind when the key is shared (`code/1`).
  """
  @spec for_item([t], Item.t()) :: t | nil
  def for_item(scans, %Item{kind: kind} = item) do
    key = Item.key(item)

    Enum.find(scans, fn s ->
      s.kind == :code and s.role == kind and (s.id == key or s.id == "#{key} (#{kind})")
    end)
  end

  @doc """
  Code records from a scanner's items: the item's key, version and place, with its kind as
  `role` (`:function`, `:module`, …) and its parent as `within`, as a spec record has them.

  The id is the item's key. When two items share a key (a C function and a constant both
  called `twin`), each id carries its kind, `twin (function)` and `twin (const)`, so each
  can be related on its own. A key no other item has keeps its bare id.
  """
  @spec code([Item.t()]) :: [t]
  def code(items) do
    shared = items |> Enum.frequencies_by(&Item.key/1) |> Map.filter(fn {_, n} -> n > 1 end)

    items
    |> Enum.map(fn item ->
      %__MODULE__{
        kind: :code,
        id: code_id(item, shared),
        hash: item.hash,
        location: %{file: item.file, lines: item.lines},
        role: item.kind,
        within: item.parent,
        shape: item.shape,
        calls: item.calls,
        hidden: item.hidden,
        runs: item.runs
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
