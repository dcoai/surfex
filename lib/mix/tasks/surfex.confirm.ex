defmodule Mix.Tasks.Surfex.Confirm do
  @shortdoc "Re-confirm the dangling relations of the named ids at their current versions"

  @moduledoc """
  For every **dangling** relation touching one of the named ids, records it again at the
  current hashes (`Surfex.Record.confirm/4`): the deliberate "I have checked this" that
  moves a relation back to current.

      mix surfex.confirm MyApp.Cart.add/2
      mix surfex.confirm "spec.md#Carts/Adding items" MyApp.Cart.total/1 --note "reworded"

  Only named ids: there is no way to confirm everything at once. An id with nothing
  dangling is an error, not a silent no-op. Orphaned and conflicted relations are not
  confirmed here: re-point one with `relate` and `retire`, and resolve the other with
  `mix surfex.resolve`.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    if ids == [], do: Mix.raise("name the ids to confirm")
    {root, scans, entries, meta} = R.context(opts)
    R.record(root, Surfex.Record.confirm(scans, entries, ids, meta))
  end
end
