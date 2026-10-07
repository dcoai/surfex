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
  it refuses. One test and one unit per run.

  Code usually implements a section while its tests verify the hints inside it. Review
  the test against its hint first, then against the section, judging that it validates
  the section's claims for the code it exercises:

      mix surfex.validate "MyApp.CartTest: rejects a closed cart" spec.md#closed-test --note …
      mix surfex.validate "MyApp.CartTest: rejects a closed cart" spec.md#carts --note …

  The second records the section's `implements` relations alone.
  """

  use Mix.Task

  alias Surfex.Evidence
  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args)
    {test, unit} = R.two!(ids)
    {root, scans, entries, meta} = R.context(opts)
    evidence = Evidence.load(Evidence.path(root))
    R.record(root, Surfex.Record.validate(scans, entries, test, unit, evidence, meta))
  end
end
