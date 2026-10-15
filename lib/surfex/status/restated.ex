defmodule Surfex.Status.Restated do
  @moduledoc false
  # §13.10: a contract stated in several spec files whose statements differ is listed,
  # never failing. A contract unit's id after its file (`Module.name/arity`, a callback
  # `Module.callback:name/arity`, §11.9) names the same function in every file, so a spec
  # and a callback of one name never pair; its version is its signatures' text with
  # whitespace collapsed, so statements differ exactly when the versions do.

  alias Surfex.Scan

  @type t :: %{contract: String.t(), units: [String.t()]}

  @doc "The contracts stated in several files with several versions, sorted, units sorted."
  @spec of([Scan.t()]) :: [t]
  def of(scans) do
    for %Scan{kind: :spec, role: :contract} = scan <- scans do
      [file, key] = String.split(scan.id, "#", parts: 2)
      {key, file, scan}
    end
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    |> Enum.filter(fn {_key, stated} ->
      several?(stated, fn {file, _} -> file end) and
        several?(stated, fn {_, scan} -> scan.hash end)
    end)
    |> Enum.map(fn {key, stated} ->
      %{contract: key, units: stated |> Enum.map(fn {_, scan} -> scan.id end) |> Enum.sort()}
    end)
    |> Enum.sort_by(& &1.contract)
  end

  defp several?(stated, by), do: stated |> Enum.uniq_by(by) |> length() > 1
end
