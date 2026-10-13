defmodule Surfex.Item do
  @moduledoc """
  One item a scanner found in the code: the unit a spec citation resolves to, and the
  source of a code record (`Surfex.Scan.code/1`).

  `key/1` is the identity. It must stay stable across edits that rename nothing, or a
  golden reports a deletion and an addition where a reader should see one row whose
  version changed. That is why the version lives in `:hash` (a
  `Surfex.SourceScan.definition_hash/1`-style content hash) and never in the key.

  A scanner decides what the kinds are. Surfex never interprets `:kind` beyond grouping
  and the rules a project writes in its `Surfex.Profile`.
  """

  @enforce_keys [:kind, :name, :file, :hash]
  defstruct [
    :kind,
    :name,
    :file,
    :hash,
    :value,
    :parent,
    :type,
    :detail,
    :lines,
    aliases: [],
    shape: false,
    calls: [],
    hidden: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom,
          # Unique within its parent (or globally, for an item with no parent).
          name: String.t(),
          # Where it is declared, relative to the scanned root.
          file: String.t(),
          hash: String.t(),
          # The declared value where the item has one (a default, a constant's body).
          value: String.t() | nil,
          # The enclosing item's key, for a member (a struct field, a function in a module).
          parent: String.t() | nil,
          # The key of the item this one is an instance of, for a member whose type is itself
          # an item (a field holding a struct). A citation of `field.member` walks through it.
          type: String.t() | nil,
          # Scanner-specific extra a golden may render (a field's type).
          detail: String.t() | nil,
          # Other names that cite this item. Several items may share one: citing it cites
          # them all, as a family (`Mod.fun` cites every arity of `fun`). Unlike two items
          # sharing a *key*, which is ambiguous, a shared alias is declared on purpose.
          aliases: [String.t()],
          # First and last line in `file`, when the scanner knows them. Where the item is,
          # for people and tools; never part of its identity or its version.
          lines: {pos_integer, pos_integer} | nil,
          # A shape has no behaviour of its own (a type): no test run exercises it, so an
          # `implements` relation to it is validated by judgement (§18). The scanner says so.
          shape: boolean,
          # The keys of the code it calls, as far as its source says: a fact, never part of its
          # key or version. Empty when the scanner doesn't know (§4).
          calls: [String.t()],
          # Code the item covers that isn't an item of its own (a module's hidden
          # definitions), by the key a call names it with (`Mix.Tasks.Foo.run/1`), each with
          # its calls. Its version is in this item's; a call naming it reaches this item and
          # goes on through its calls (§4, §13.1). Empty for most items.
          hidden: %{String.t() => [String.t()]}
        }

  @doc """
  The citation key. A member is keyed through its parent (`parent.name`), so two structs'
  `offset` fields are two keys and a bare `offset` is never silently one of them.
  """
  @spec key(t) :: String.t()
  def key(%__MODULE__{parent: parent, name: name}) when is_binary(parent), do: "#{parent}.#{name}"
  def key(%__MODULE__{name: name}), do: name
end
