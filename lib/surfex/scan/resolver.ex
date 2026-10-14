defmodule Surfex.Scan.Resolver do
  @moduledoc """
  The spec units of a scan, indexed once by full id and by bare id, so that resolving a
  declaration (`Surfex.Scan.resolve/2`) is a lookup, not a scan of every record (§11).

  Build one with `Surfex.Scan.resolver/1` wherever many references resolve against the same
  scans (every test's declarations, in `Surfex.Status.derive/4`), and pass it to
  `Surfex.Scan.resolve/2` in place of the scans. It resolves exactly as the scans do.

  Built with a project's `unit_refs:` (`new/2`, §11.1), it also reads the project's own
  citation forms (`§03.4`, `spec/05 §4.3`), each a regex whose named captures say the file
  (`file`, or `chapter`: the file's leading number) and the `id` within it. They are tried
  before the exact and bare-id lookups.
  """

  alias Surfex.Scan

  @enforce_keys [:by_id, :by_bare]
  defstruct [:by_id, :by_bare, refs: [], by_chapter: %{}, by_file: %{}]

  @type t :: %__MODULE__{
          by_id: %{String.t() => [Scan.t()]},
          by_bare: %{String.t() => [Scan.t()]},
          refs: [Regex.t()],
          by_chapter: %{non_neg_integer => [String.t()]},
          by_file: %{String.t() => String.t()}
        }

  @doc """
  The spec records of `scans`, by full id, and by bare id for those a bare reference may
  name (an anchored section, a block, a hint or any other unit that isn't a section). With
  `unit_refs` (`unit_refs!/1`), the spec files too: by their leading number and by their
  path with and without `.md`.
  """
  @spec new([Scan.t()], [Regex.t()]) :: t
  def new(scans, unit_refs \\ []) do
    spec = for %Scan{kind: :spec} = s <- scans, do: s
    files = spec |> Enum.map(& &1.location.file) |> Enum.uniq()

    %__MODULE__{
      by_id: Enum.group_by(spec, & &1.id),
      by_bare:
        spec
        |> Enum.filter(&(&1.role != :section or anchored?(&1)))
        |> Enum.group_by(&bare(&1.id)),
      refs: unit_refs!(unit_refs),
      by_chapter:
        for(file <- files, n = chapter(file), n != nil, do: {n, file})
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      by_file: Map.new(files, &{&1, &1}) |> Map.merge(Map.new(files, &{Path.rootname(&1), &1}))
    }
  end

  @doc """
  A project's `unit_refs:`, validated: a list of regexes, each with a named capture `id`
  and one of `file` or `chapter`. Raises `ArgumentError` naming what is wrong.
  """
  @spec unit_refs!(term) :: [Regex.t()]
  def unit_refs!(refs) when is_list(refs) do
    for ref <- refs do
      names = if is_struct(ref, Regex), do: Regex.names(ref), else: []

      cond do
        not is_struct(ref, Regex) ->
          raise ArgumentError, "unit_refs: each must be a regex, got #{inspect(ref)}"

        "id" not in names or not Enum.any?(["file", "chapter"], &(&1 in names)) ->
          raise ArgumentError,
                "unit_refs: #{inspect(ref)} needs a named capture (?<id>…) and one of (?<file>…) or (?<chapter>…)"

        true ->
          ref
      end
    end
  end

  def unit_refs!(other),
    do: raise(ArgumentError, "unit_refs: must be a list of regexes, got #{inspect(other)}")

  @doc "The spec unit `ref` names, as `Surfex.Scan.resolve/2` gives it."
  @spec resolve(t, String.t()) ::
          {:ok, Scan.t()} | {:error, :unknown | {:ambiguous, [String.t()]}}
  def resolve(resolver, ref) do
    # A project's own form first; one that names nothing falls through to the ids.
    case form(resolver, ref) do
      {:ok, _} = found -> found
      {:error, {:ambiguous, _}} = ambiguous -> ambiguous
      _ -> by_id(resolver, ref)
    end
  end

  @doc """
  The spec unit a project citation form names (`unit_refs:`): `nil` when no pattern
  matches `ref`, else what the first matching pattern resolves to.
  """
  @spec form(t, String.t()) ::
          {:ok, Scan.t()} | {:error, :unknown | {:ambiguous, [String.t()]}} | nil
  def form(%__MODULE__{refs: refs} = resolver, ref) do
    Enum.find_value(refs, fn pattern ->
      case Regex.named_captures(pattern, ref) do
        nil -> nil
        captures -> in_files(resolver, files(resolver, captures), captures["id"])
      end
    end)
  end

  defp files(resolver, %{"chapter" => chapter}) when chapter != "" do
    case Integer.parse(chapter) do
      {n, ""} -> Map.get(resolver.by_chapter, n, [])
      _ -> []
    end
  end

  defp files(resolver, %{"file" => file}), do: List.wrap(Map.get(resolver.by_file, file))

  defp in_files(resolver, files, id) do
    case Enum.flat_map(files, &Map.get(resolver.by_id, "#{&1}##{id}", [])) do
      [one] -> {:ok, one}
      [] -> {:error, :unknown}
      many -> {:error, {:ambiguous, many |> Enum.map(& &1.id) |> Enum.sort()}}
    end
  end

  # A spec file's chapter: the number its name starts with (`spec/03-wire-format.md` is 3).
  defp chapter(file) do
    case Regex.run(~r/^(\d+)/, Path.basename(file), capture: :all_but_first) do
      [n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp by_id(resolver, "§" <> ref) do
    # A `§`-id is cited with its sign (`§Api.3.2`); the id is what follows it (§11).
    case exact(resolver, ref) do
      {:error, :unknown} -> exact(resolver, "§" <> ref)
      found -> found
    end
  end

  defp by_id(resolver, ref), do: exact(resolver, ref)

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
