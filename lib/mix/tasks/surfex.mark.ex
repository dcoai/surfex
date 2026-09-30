defmodule Mix.Tasks.Surfex.Mark do
  @shortdoc "Mark a spec unit as needing an update, or withdraw its mark"

  @moduledoc """
  Records that a spec unit itself needs to change (`Surfex.Record.mark/5`, §12.1): the
  tests reflect it and the code passes them, but the result is wrong or clearly
  sub-optimal. The mark is recorded at the unit's current version, and the note says what
  is wrong:

      mix surfex.mark spec.md#totals --needs-update \\
        --note "totals ignore discounts: a customer sees the undiscounted price"

  The mark stays open while the unit is at that version, and is resolved when the spec
  changes, which starts the process over from the spec (§18). `mix surfex.status` reports
  open marks; `--no-marks` fails on them. The new mark is printed as a change draft (§19),
  for the project's change process: `mix surfex.draft --file` hands it off.

  With `--withdraw` it withdraws the unit's open mark instead
  (`Surfex.Record.withdraw/5`), with a note saying why it proved unfounded, and `--pick
  ID_PREFIX` when the unit has several:

      mix surfex.mark spec.md#totals --withdraw --note "the customer's cart had no discount"
  """

  use Mix.Task

  alias Surfex.Change
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, needs_update: :boolean, withdraw: :boolean)

    unit =
      case ids do
        [unit] -> unit
        _ -> Mix.raise("give one spec unit: mix surfex.mark SPEC_UNIT --needs-update --note N")
      end

    {root, scans, entries, meta} = R.context(opts)
    meta = if opts[:pick], do: [pick: opts[:pick]] ++ meta, else: meta

    case {opts[:needs_update], opts[:withdraw]} do
      {true, nil} ->
        R.record(root, Surfex.Record.mark(scans, entries, unit, :needs_update, meta))
        print_draft(root, opts, unit)

      {nil, true} ->
        R.record(root, Surfex.Record.withdraw(scans, entries, unit, :needs_update, meta))

      _ ->
        Mix.raise("give exactly one of --needs-update or --withdraw")
    end
  end

  # The mark as a change draft (§19), to carry into the project's change process.
  defp print_draft(root, opts, unit) do
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    status = Config.status(config, root, namespace, [])

    for draft <- Change.drafts(status, root, [unit]),
        do: Mix.shell().info("\n" <> Change.markdown(draft))
  end
end
