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

    * `role` — `:section` (a heading and its body), `:block` (a marked requirement inside
      a section) or `:test_hint` (a fenced `test` block saying how to test something);
      `nil` for records that aren't spec
    * `within` — the id of the section or block it sits in, `nil` for a section. It is a
      fact about the text, not a relation.

  `code/1` makes code records from any `Surfex.Scanner`'s items. `Surfex.Scan.Markdown`
  makes spec records.
  """

  alias Surfex.Item

  @enforce_keys [:kind, :id, :hash, :location]
  defstruct [:kind, :id, :hash, :location, :role, :within]

  @type location :: %{file: String.t(), lines: {pos_integer, pos_integer} | nil}
  @type role :: :section | :block | :test_hint | nil
  @type t :: %__MODULE__{
          kind: atom,
          id: String.t(),
          hash: String.t(),
          location: location,
          role: role,
          within: String.t() | nil
        }

  @doc "Code records from a scanner's items: the item's key, version and place."
  @spec code([Item.t()]) :: [t]
  def code(items) do
    items
    |> Enum.map(fn item ->
      %__MODULE__{
        kind: :code,
        id: Item.key(item),
        hash: item.hash,
        location: %{file: item.file, lines: item.lines}
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
