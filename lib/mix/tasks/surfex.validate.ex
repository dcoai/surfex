defmodule Mix.Tasks.Surfex.Validate do
  @shortdoc "Record a review: a test judged to validate a spec unit, and green against the code"

  @moduledoc """
  Records a **review** (`Surfex.Record.validate/6`, §18): the test was examined against the
  spec unit, judged to validate it, and passes against the code.

      mix test
      mix surfex.validate "MyApp.CartTest: rejects a closed cart" spec.md#closed \\
        --note "asserts {:error, :closed} and that the cart is unchanged: both claims of the unit"

  Before running it, do the work: read the unit's claims and the test, and judge whether
  the test accurately validates that component of the spec: its cases, its boundaries,
  what must stay unchanged. Fix or extend the test where it falls short. The note says
  which claim each assertion checks.

  It needs a `verifies` relation from the test to the unit, and the last `mix test` to have
  passed the test's current version. It validates that relation and each `implements`
  relation of the unit whose code the test exercised, each only if it isn't validated
  already (a `verifies` on its failing run keeps that basis); with nothing left to record
  it refuses. One test and one unit per run, or, with `--file PATH`, many: one per line,
  tab-separated `TEST`, `UNIT`, `NOTE`, each reviewed as the single form reviews it, with
  distinct notes (`Surfex.Record.batch/3`).

  `--merge PATH` (once per file) also reads other runs' evidence, such as CI artifacts,
  with the local run as one history (`Surfex.Evidence.combined/1`), so a test excluded
  locally counts from the run that had its environment. A missing file fails.

  Code usually implements a section while its tests verify the hints inside it. Review
  the test against its hint first, then against the section, judging that it validates
  the section's claims for the code it exercises:

      mix surfex.validate "MyApp.CartTest: rejects a closed cart" spec.md#closed-test --note …
      mix surfex.validate "MyApp.CartTest: rejects a closed cart" spec.md#carts --note …

  The second records the section's `implements` relations alone.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, file: :string, merge: :keep)
    {root, scans, entries, meta} = R.context(opts)
    evidence = R.evidence!(root, opts)

    case opts[:file] do
      nil ->
        {test, unit} = R.two!(ids)
        R.record(root, Surfex.Record.validate(scans, entries, test, unit, evidence, meta))

      path ->
        if ids != [] or opts[:note] != nil,
          do:
            Mix.raise(
              "--file reads every relation and its note from the file: name none, and no --note"
            )

        lines =
          for %{fields: [test, unit]} = l <- R.batch_lines!(path, 3),
              do: Map.merge(l, %{test: test, unit: unit})

        R.record(
          root,
          Surfex.Record.batch(entries, lines, fn so_far, l ->
            Surfex.Record.validate(
              scans,
              so_far,
              l.test,
              l.unit,
              evidence,
              Keyword.put(meta, :note, l.note)
            )
          end)
        )
    end
  end
end
