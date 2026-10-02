defmodule Mix.Tasks.Surfex.Retire do
  @shortdoc "Record that two things no longer relate"

  @moduledoc """
  Retires a relation (`Surfex.Record.retire/6`): an entry saying it no longer applies. It
  is appended like any other, and the relation's history stays in the log.

      mix surfex.retire "spec.md#Carts/Discounts" MyApp.Cart.discount/2 --type implements --note "discounts dropped"

  An end need not still be scanned: retiring is how an orphaned relation is put to rest.

  Retiring a pair that was never related **declines** it: a suggestion turned down before
  anyone accepted it. `--note` is required then, saying why, and `mix surfex.suggest`
  doesn't propose the pair again.

      mix surfex.retire spec.md#limits Wren.max_len/0 --type implements --note "documented in §2"
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    {from, to} = R.two!(ids)
    type = R.type!(opts)
    {root, scans, entries, meta} = R.context(opts)
    R.record(root, Surfex.Record.retire(scans, entries, from, to, type, meta))
  end
end
