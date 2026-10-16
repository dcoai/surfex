defmodule Surfex.Status.SpecOnly do
  @moduledoc false
  # §13.16: the spec-only reading, `mix surfex.status --spec`, for a repository that holds
  # a spec another implements. Its status is derived over the spec's units alone
  # (`Surfex.Status.Config.read_spec/3`), so its lists are the full run's spec-side lists;
  # this says which of them fail with no code to vouch for anything.

  alias Surfex.Status
  alias Surfex.Status.SpecShape

  # With no code, the spec's own contracts are the only judge of a cited arity (§13.15).
  @fails [:contract_arity]

  @doc "What the text report opens with, and the JSON's `mode`."
  @spec header() :: String.t()
  def header, do: "spec only (--spec): code, relations, the log and evidence are not read"

  @doc """
  The spec-shape warnings that fail the reading: each of kind `contract_arity`, in file
  and line order. In a full run none fails.
  """
  @spec failures(Status.t()) :: [SpecShape.t()]
  def failures(status), do: status |> SpecShape.warnings() |> Enum.filter(&(&1.kind in @fails))

  @doc """
  Whether the reading fails: a cited arity no contract states, or a deferral citing a spec
  unit that went stale (§13.13). Nothing else is read, so nothing else fails.
  """
  @spec failing?(Status.t()) :: boolean
  def failing?(status), do: failures(status) != [] or status.stale_deferrals != []
end
