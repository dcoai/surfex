defmodule Mix.Tasks.Surfex.Confirm do
  @shortdoc "Confirm dangling relations: named ones by judgement, or all that evidence justifies"

  @moduledoc """
  For every **dangling** relation touching one of the named ids, records it again at the
  current hashes (`Surfex.Record.confirm/5`): the deliberate "I have checked this" that
  moves a relation back to current.

      mix surfex.confirm MyApp.Cart.add/2
      mix surfex.confirm "spec.md#Carts/Adding items" MyApp.Cart.total/1 --note "reworded"

  Only named ids: there is no way to confirm everything at once by hand. An id with
  nothing dangling is an error, not a silent no-op. Orphaned and conflicted relations are
  not confirmed here: re-point one with `relate` and `retire`, and resolve the other with
  `mix surfex.resolve`.

  `--evidence`, with no ids, confirms instead what the test evidence justifies
  (`Surfex.Record.confirm_by_evidence/4`, evidence from `Surfex.ExUnitFormatter`):

      mix test && mix surfex.confirm --evidence

  A dangling `tests` relation is confirmed when its test's current version has failed
  once and passes now against the code's current version. A dangling `implements`
  relation follows when a test verifying that spec unit exercises the code with such
  evidence. `verifies` relations are never confirmed by evidence: whether a test still
  expresses its requirement is a judgement, confirmed by name. Nothing justified is not an
  error.

  With `require_red: true` in `.surfex.exs`, a `tests` relation isn't confirmed by hand
  either until its test's current version has failed first.
  """

  use Mix.Task

  alias Surfex.Evidence
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, evidence: :boolean)
    by_evidence? = opts[:evidence] == true
    {root, scans, entries, meta} = R.context(opts)
    evidence = Evidence.load(Evidence.path(root))

    cond do
      by_evidence? and ids != [] ->
        Mix.raise("--evidence confirms what the evidence justifies: name no ids with it")

      by_evidence? ->
        case Surfex.Record.confirm_by_evidence(scans, entries, evidence, meta) do
          {:ok, []} -> Mix.shell().info("nothing to confirm by evidence")
          result -> R.record(root, result)
        end

      ids == [] ->
        Mix.raise("name the ids to confirm, or pass --evidence")

      true ->
        config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
        policy = [require_red: Config.require_red!(config), evidence: evidence]
        R.record(root, Surfex.Record.confirm(scans, entries, ids, meta, policy))
    end
  end
end
