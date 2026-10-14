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

  The note speaks for what you read, so a review credits the code the test calls. Code the
  test reaches only through other code (§13.1), such as the function a public entry point
  hands the work to, is credited when you name it with `--code ID`, once per item, after
  reading it against the unit:

      mix surfex.validate "MyApp.CheckoutTest: totals" spec.md#totals \\
        --code MyApp.Pricing.total/1 --note "…"

  Naming code the test's green run didn't reach is an error, and a review with nothing to
  record but reached code says which to name. A batch (`--file`) takes no `--code`: name
  reached code in a single review. Evidence (`mix surfex.confirm --evidence`) credits
  reached code without naming, since a red-then-green run backs it.

  A function with default arguments is one definition under several arities (`put/3` and
  `put/4` from one `def put` with a default argument), so a review of either credits both,
  and its note is recorded on each. The task says so, naming them, so the note is written
  for the definition and not for the arity the test calls.

  Some tests exercise code by a path no call in the source shows: a route a router maps,
  a message to a process, a JavaScript hook, a capture handed to a helper. Relate the code
  to the claim it realises (`mix surfex.relate CODE CLAIM --type implements --note …`),
  then say how the test exercises it with `--through HOW`:

      mix surfex.validate "MyApp.FeedTest: refreshes" spec.md#feed-refresh \\
        --code MyApp.Feed.handle_info/2 --through "message {:feed, _} from the subscription" \\
        --note "…"

  It credits each named item the green run didn't reach, and the entry records `through`
  (`mix surfex.history` shows it; status counts these reviews). `--through` needs `--code`,
  and is refused when the run reached every named item: reached code needs no path named.
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, file: :string, merge: :keep, code: :keep, through: :string)
    {root, scans, entries, meta} = R.context(opts)

    meta =
      meta
      |> Keyword.put(:code, Keyword.get_values(opts, :code))
      |> then(&if(opts[:through], do: Keyword.put(&1, :through, opts[:through]), else: &1))

    evidence = R.evidence!(root, opts)

    case opts[:file] do
      nil ->
        {test, unit} = R.two!(ids)
        [test, unit] = R.units([test, unit], scans, opts)
        recorded(root, scans, Surfex.Record.validate(scans, entries, test, unit, evidence, meta))

      path ->
        if ids != [] or opts[:note] != nil or meta[:code] != [] or opts[:through] != nil,
          do:
            Mix.raise(
              "--file reads every relation and its note from the file: name none, no --note, and no --code or --through (name reached code in a single review)"
            )

        lines =
          for %{fields: [test, unit]} = l <- R.batch_lines!(path, 3),
              do: Map.merge(l, %{test: test, unit: hd(R.units([unit], scans, opts))})

        recorded(
          root,
          scans,
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

  # Records what the review returned, then names each definition it credited under several
  # arities: one note is on each, so it must speak for the definition (§18.4).
  defp recorded(root, scans, result) do
    R.record(root, result)
    {:ok, entries} = result

    for ids <- Surfex.Record.shared_definitions(scans, entries),
        do:
          Mix.shell().info(
            "one definition: #{Enum.join(ids, ", ")} share it (default arguments), so this " <>
              "review's note is recorded on each: write it for the definition, not one arity"
          )
  end
end
