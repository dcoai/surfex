defmodule Mix.Tasks.Surfex.Annotate do
  @shortdoc "Give a current relation a new note"
  @moduledoc """
  Gives a current relation a new note (`Surfex.Record.annotate/6`, §14): a re-review that
  found nothing to change still belongs in the log, not a commit message.

      mix surfex.annotate FROM TO --type TYPE --note "what the re-review found"

  It re-records the relation as it stands (its versions and basis), with the note. A
  dangling or proposed relation is refused: `mix surfex.confirm` settles those.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    {from, to} = R.two!(ids)
    type = R.type!(opts)
    {root, scans, entries, meta} = R.context(opts)
    R.record(root, Surfex.Record.annotate(scans, entries, from, to, type, meta))
  end
end
