defmodule Mix.Tasks.Surfex.Confirm do
  @shortdoc "Confirm one relation by judgement, or every relation the test evidence validates"

  @moduledoc """
  Confirms **one** relation, named by its ends and type, with a note saying what was
  judged (`Surfex.Record.confirm/7`):

      mix surfex.confirm "test:MyApp.CartTest: rejects a closed cart" spec.md#closed \\
        --type verifies --note "spec reworded; the test still checks a closed cart is refused"

  It is the judgement path (§18): a `verifies` relation after a spec rewording that
  changes no behaviour, an `excuses` relation, a structural relation after a change, and
  an `implements` relation to a shape (a type, which no run exercises). It never confirms
  any other `implements` relation: code is validated by evidence or a review, never
  asserted. There is no form that confirms every relation touching an id.

  With `--file PATH` it confirms many in one run (`Surfex.Record.batch/3`): one relation
  per line, tab-separated `FROM`, `TO`, `TYPE`, `NOTE`, each judged as the single form
  judges it. The notes must be distinct, and a refused line fails the whole batch.

  `--merge PATH` (once per file) also reads other runs' evidence, such as CI artifacts,
  with the local run as one history (`Surfex.Evidence.combined/1`), so a test excluded
  locally counts from the run that had its environment. A missing file fails.

  With `--evidence` it confirms instead what the test evidence justifies
  (`Surfex.Record.confirm_by_evidence/4`): each test relation on its test's failing run,
  each `tests` and `implements` relation on a red run and then a green one:

      mix test && mix surfex.confirm --evidence

  With `require_red: true` in `.surfex.exs`, a `tests` relation isn't confirmed by hand
  until its test's current version has failed first.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, evidence: :boolean, file: :string, merge: :keep)
    {root, scans, entries, meta} = R.context(opts)
    evidence = R.evidence!(root, opts)

    cond do
      opts[:file] != nil and (ids != [] or opts[:evidence] == true or opts[:note] != nil) ->
        Mix.raise(
          "--file reads every relation and its note from the file: name none, and no --note or --evidence"
        )

      opts[:file] != nil ->
        config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
        policy = [require_red: Config.require_red!(config), evidence: evidence]

        lines =
          for %{fields: [from, to, type]} = line <- R.batch_lines!(opts[:file], 4),
              do: Map.merge(line, %{from: from, to: to, type: R.type_named!(type)})

        R.record(
          root,
          Surfex.Record.batch(entries, lines, fn so_far, l ->
            Surfex.Record.confirm(
              scans,
              so_far,
              l.from,
              l.to,
              l.type,
              Keyword.put(meta, :note, l.note),
              policy
            )
          end)
        )

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
