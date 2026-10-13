defmodule Surfex.Scan.Resolver do
  @moduledoc """
  The spec units of a scan, indexed once by full id and by bare id, so that resolving a
  declaration (`Surfex.Scan.resolve/2`) is a lookup, not a scan of every record (§11).

  Build one with `Surfex.Scan.resolver/1` wherever many references resolve against the same
  scans (every test's declarations, in `Surfex.Status.derive/4`), and pass it to
  `Surfex.Scan.resolve/2` in place of the scans. It resolves exactly as the scans do.
  """

  alias Surfex.Scan

  @enforce_keys [:by_id, :by_bare]
  defstruct [:by_id, :by_bare]

  @type t :: %__MODULE__{
          by_id: %{String.t() => [Scan.t()]},
          by_bare: %{String.t() => [Scan.t()]}
        }

  @doc """
  The spec records of `scans`, by full id, and by bare id for those a bare reference may
  name (an anchored section, a block, a hint or any other unit that isn't a section).
  """
  @spec new([Scan.t()]) :: t
  def new(scans) do
    spec = for %Scan{kind: :spec} = s <- scans, do: s

    %__MODULE__{
      by_id: Enum.group_by(spec, & &1.id),
      by_bare:
        spec
        |> Enum.filter(&(&1.role != :section or anchored?(&1)))
        |> Enum.group_by(&bare(&1.id))
    }
  end

  @doc "The spec unit `ref` names, as `Surfex.Scan.resolve/2` gives it."
  @spec resolve(t, String.t()) ::
          {:ok, Scan.t()} | {:error, :unknown | {:ambiguous, [String.t()]}}
  def resolve(resolver, "§" <> ref) do
    # A `§`-id is cited with its sign (`§Api.3.2`); the id is what follows it (§11).
    case resolve(resolver, ref) do
      {:error, :unknown} -> exact(resolver, "§" <> ref)
      found -> found
    end
  end

  def resolve(resolver, ref), do: exact(resolver, ref)

  defp exact(%__MODULE__{by_id: by_id, by_bare: by_bare}, ref) do
    matches =
      if String.contains?(ref, "#"),
        do: Map.get(by_id, ref, []),
        else: Map.get(by_bare, ref, [])

    case matches do
      [one] -> {:ok, one}
      [] -> {:error, :unknown}
      many -> {:error, {:ambiguous, many |> Enum.map(& &1.id) |> Enum.sort()}}
    end
  end

  defp bare(id), do: id |> String.split("#", parts: 2) |> List.last()

  # A section's id is an anchor when the author wrote it (`named`), or, for a record built
  # by hand, when it has the lowercase anchor form. A bare reference names anchors, blocks
  # and hints, never a heading path.
  defp anchored?(%Scan{named: true}), do: true
  defp anchored?(%Scan{id: id}), do: Regex.match?(~r/#[a-z0-9][a-z0-9-]*$/, id)
end
