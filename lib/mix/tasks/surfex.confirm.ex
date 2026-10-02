defmodule Mix.Tasks.Surfex.Confirm do
  @shortdoc "Confirm one relation by judgement, or every relation the test evidence validates"

  @moduledoc """
  Confirms **one** relation, named by its ends and type, with a note saying what was
  judged (`Surfex.Record.confirm/7`):

      mix surfex.confirm "test:MyApp.CartTest: rejects a closed cart" spec.md#closed \\
        --type verifies --note "spec reworded; the test still checks a closed cart is refused"

  It is the judgement path (§18): a `verifies` relation after a spec rewording that
  changes no behaviour, an `excuses` relation, a structural relation after a change. It
  never confirms an `implements` relation: code is validated by evidence or a review,
  never asserted. There is no form that confirms more than one relation.

  With `--evidence` it confirms instead what the test evidence justifies
  (`Surfex.Record.confirm_by_evidence/4`): each test relation on its test's failing run,
  each `tests` and `implements` relation on a red run and then a green one:

      mix test && mix surfex.confirm --evidence

  With `require_red: true` in `.surfex.exs`, a `tests` relation isn't confirmed by hand
  until its test's current version has failed first.
  """

  use Mix.Task

  alias Surfex.Evidence
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, evidence: :boolean)
    {root, scans, entries, meta} = R.context(opts)
    evidence = Evidence.load(Evidence.path(root))

    cond do
      opts[:evidence] == true and ids != [] ->
        Mix.raise("--evidence confirms what the evidence justifies: name no relation with it")

      opts[:evidence] == true ->
        # A baselined test counts as discriminated under the project's adoption: (§18.1).
        config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
        meta = Keyword.put(meta, :adoption, Config.adoption!(config, root))

        case Surfex.Record.confirm_by_evidence(scans, entries, evidence, meta) do
          {:ok, []} -> Mix.shell().info("nothing to confirm by evidence")
          result -> R.record(root, result)
        end

      true ->
        {from, to} = R.two!(ids)
        type = R.type!(opts)
        config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
        policy = [require_red: Config.require_red!(config), evidence: evidence]
        R.record(root, Surfex.Record.confirm(scans, entries, from, to, type, meta, policy))
    end
  end
end
