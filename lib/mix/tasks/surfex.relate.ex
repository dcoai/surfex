defmodule Mix.Tasks.Surfex.Relate do
  @shortdoc "Record that two scanned things relate, at their current versions"

  @moduledoc """
  Records a relation between two scanned ids, at their current hashes
  (`Surfex.Record.relate/6`).

      mix surfex.relate "spec.md#Carts/Adding items" MyApp.Cart.add/2 --type implements
      mix surfex.relate MyApp.Cart.add/2 MyApp.Cart.Line.new/1 --type depends_on --note "builds a line"

  For a directed type (`depends_on`, `refines`, `tests`) the order is from → to. Prefix
  an id with `spec:` or `code:` when it is scanned as both. The entry supersedes the
  relation's current judgement, if it has one.

  `--planned` relates a scanned id to one that doesn't exist yet (`Surfex.Record.plan/7`):
  the section is written and the code isn't, or the other way round.

      mix surfex.relate --planned "spec.md#Carts/Adding items" MyApp.Cart.add/2 --type implements

  The relation is planned until the id is scanned, then dangling until you confirm it. An
  id that couldn't be this project's (a spec file the scanner doesn't read, a code name
  outside the project's namespaces) is refused as a likely typo.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, planned: :boolean)
    {from, to} = R.two!(ids)
    type = R.type!(opts)
    {root, scans, entries, meta} = R.context(opts)

    result =
      if opts[:planned],
        do: Surfex.Record.plan(scans, entries, from, to, type, R.plausible(opts, scans), meta),
        else: Surfex.Record.relate(scans, entries, from, to, type, meta)

    R.record(root, result)
  end
end
