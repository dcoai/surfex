defmodule Surfex.Status.Callers do
  @moduledoc false
  # Which tests call or reach a piece of code, by definition (§13.1), and whether each verifies
  # a given unit's claims. `Surfex.Migrate` names them on a none (§14.2); what they reach is the
  # source's own fact (`Surfex.Scan.reach/1`), read once.

  alias Surfex.Scan

  @type t :: %{test: String.t(), how: :calls | :reaches, verifies_here: boolean}

  @spec index([Scan.t()]) :: %{term => [{String.t(), :calls | :reaches}]}
  def index(scans) do
    definition =
      for %Scan{kind: :code, id: id} = s <- scans, into: %{}, do: {id, Scan.definition(s)}

    reached = Scan.reach(scans)

    tests =
      for %Scan{kind: :test, id: test, calls: calls} <- scans,
          id <- Map.get(reached, test, []),
          d = definition[id],
          uniq: true do
        direct = Enum.any?(calls, &(definition[&1] == d))
        {d, {test, if(direct, do: :calls, else: :reaches)}}
      end

    Enum.group_by(tests, &elem(&1, 0), &elem(&1, 1))
  end

  @doc false
  @spec of(map, Scan.t(), MapSet.t()) :: [t]
  def of(index, %Scan{} = code, verifying) do
    index
    |> Map.get(Scan.definition(code), [])
    |> Enum.map(fn {test, how} ->
      %{test: test, how: how, verifies_here: MapSet.member?(verifying, test)}
    end)
    |> Enum.sort_by(&{&1.how != :calls, &1.test})
  end
end
