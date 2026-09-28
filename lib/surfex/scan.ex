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
    * `within` — what it sits in: the section or block of a block or hint, the parent of a
      code item (its module, for a function). `nil` when nothing encloses it. It is a
      fact about the source, not a relation.

  A test record (`Surfex.Scan.ExUnit`) can also **declare** what it relates to, in its
  own source: `declares` is a list of `{type, id}`, such as `{:verifies, "cart-add"}`
  from `@tag verifies: "cart-add"`. A declaration is a claim in the source, not a
  relation; `resolve/2` finds the spec unit it names. A test record also lists what it
  `calls`: the functions its source calls (`MyApp.Cart.add/3`), as facts to suggest
  `tests` relations from.

  `code/1` makes code records from any `Surfex.Scanner`'s items. `Surfex.Scan.Markdown`
  makes spec records and `Surfex.Scan.ExUnit` test records.
  """

  alias Surfex.Item

  @enforce_keys [:kind, :id, :hash, :location]
  defstruct [:kind, :id, :hash, :location, :role, :within, declares: [], calls: []]

  @type location :: %{file: String.t(), lines: {pos_integer, pos_integer} | nil}
  @type role :: atom | nil
  @type t :: %__MODULE__{
          kind: atom,
          id: String.t(),
          hash: String.t(),
          location: location,
          role: role,
          within: String.t() | nil,
          declares: [{atom, String.t()}],
          calls: [String.t()]
        }

  @doc """
  The spec unit a declaration names: a full id (`spec.md#Carts/Adding items`,
  `spec.md#cart-add`), or a bare anchor, block or hint id (`cart-add`) looked up across
  every spec file. `{:error, :unknown}` when nothing has it, `{:error, {:ambiguous, ids}}`
  when a bare id is in more than one file.
  """
  @spec resolve([t], String.t()) ::
          {:ok, t} | {:error, :unknown | {:ambiguous, [String.t()]}}
  def resolve(scans, ref) do
    spec = Enum.filter(scans, &(&1.kind == :spec))

    matches =
      if String.contains?(ref, "#"),
        do: Enum.filter(spec, &(&1.id == ref)),
        else:
          Enum.filter(spec, fn s -> (s.role != :section or anchored?(s)) and bare(s.id) == ref end)

    case matches do
      [one] -> {:ok, one}
      [] -> {:error, :unknown}
      many -> {:error, {:ambiguous, many |> Enum.map(& &1.id) |> Enum.sort()}}
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

  defp bare(id), do: id |> String.split("#", parts: 2) |> List.last()

  # A section's id is an anchor when it isn't a heading path: no `/`, and it has the
  # anchor form. A bare reference names anchors, blocks and hints, never a heading.
  defp anchored?(%__MODULE__{id: id}), do: Regex.match?(~r/#[a-z0-9][a-z0-9-]*$/, id)

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
        within: item.parent
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
