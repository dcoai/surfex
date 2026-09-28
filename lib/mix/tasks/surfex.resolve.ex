defmodule Mix.Tasks.Surfex.Resolve do
  @shortdoc "Resolve a conflicted relation by picking one side"

  @moduledoc """
  A relation is conflicted when two entries were recorded without seeing each other,
  typically on two branches that were then merged. `mix surfex.status` lists the tips'
  ids; this records the picked one again with both as parents (`Surfex.Record.resolve/7`).

      mix surfex.resolve "spec.md#Carts/Adding items" MyApp.Cart.add/2 --type implements --pick 3f9c01

  `--pick` takes the start of a tip's id. If the code or spec has moved since, the
  relation is then dangling, and `mix surfex.confirm` is next.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    {from, to} = R.two!(ids)
    type = R.type!(opts)
    pick = opts[:pick] || Mix.raise("--pick is required: the start of the chosen tip's id")
    {root, scans, entries, meta} = R.context(opts)
    R.record(root, Surfex.Record.resolve(scans, entries, from, to, type, pick, meta))
  end
end
