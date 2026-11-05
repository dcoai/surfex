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

  Naming a pair validates nothing (§18). An `implements` or `excuses` relation is recorded
  as proposed. A `verifies` relation is recorded on the test's failing run when the last
  `mix test` saw its current version fail, and as proposed otherwise.

  `--planned` relates a scanned id to one that doesn't exist yet (`Surfex.Record.plan/7`):
  the section is written and the code isn't, or the other way round.

      mix surfex.relate --planned "spec.md#Carts/Adding items" MyApp.Cart.add/2 --type implements

  The relation is planned until the id is scanned, then dangling until you confirm it. An
  id that couldn't be this project's (a spec file the scanner doesn't read, a code name
  outside the project's namespaces) is refused as a likely typo.

  Many relations cost one scan and one log load with `--file PATH`, one per line:

      mix surfex.relate --file relations.tsv
      mix surfex.relate --file planned.tsv --planned

  Each line is tab-separated `FROM`, `TO`, `TYPE` and an optional `NOTE`; blank lines and
  lines starting with `#` are skipped. Ids and types are written as above, and `--planned`
  plans every line. A line records what the single form records, so a file validates
  nothing either, and a claim-derived candidate is still reviewed pair by pair (§15.5).
  With `--file`, name no ids, no `--type` and no `--note`.

  Each line stands alone (`Surfex.Record.relate_batch/5`). One run names every line it
  refuses, records the others, and then fails, so a script notices. Correct the file and
  run it again: a line whose relation already stands at those versions is skipped and
  reported, so only what's new is recorded. That covers a relation with the same note, a
  line with no note, and a relation validated since, which a rerun never puts back to
  proposed (`mix surfex.annotate` gives one a new note).
  """

  use Mix.Task

  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, ids} = R.parse(args, file: :string, planned: :boolean, merge: :keep)

    case opts[:file] do
      nil -> one(opts, ids)
      path -> file(path, opts, ids)
    end
  end

  defp file(path, opts, ids) do
    if ids != [] or opts[:type] != nil or opts[:note] != nil,
      do:
        Mix.raise(
          "--file reads every relation and its note from the file: name none, and no --type or --note"
        )

    {root, scans, entries, meta} = R.context(opts)
    {lines, unread} = R.claim_lines!(path, scans, opts)

    batch_opts =
      if opts[:planned],
        do: [plausible: R.plausible(opts, scans)],
        else: [evidence: R.evidence!(root, opts)]

    {:ok, recorded, %{skipped: skipped, refused: refused}} =
      Surfex.Record.relate_batch(scans, entries, lines, meta, batch_opts)

    R.record(root, {:ok, recorded})
    Enum.each(skipped, &Mix.shell().info("skipped line #{&1.line}: #{&1.why}"))

    case Enum.sort_by(unread ++ refused, & &1.line) do
      [] ->
        :ok

      all ->
        total = length(lines) + length(unread)

        Mix.raise(
          "#{path}: #{length(all)} of #{total} lines refused; the others are in the log, " <>
            "so correct these and run the file again:\n" <>
            Enum.map_join(all, "\n", &"  line #{&1.line}: #{&1.why}")
        )
    end
  end

  defp one(opts, ids) do
    {from, to} = R.two!(ids)
    type = R.type!(opts)
    {root, scans, entries, meta} = R.context(opts)
    [from, to] = R.units([from, to], scans, opts)

    result =
      if opts[:planned],
        do: Surfex.Record.plan(scans, entries, from, to, type, R.plausible(opts, scans), meta),
        else:
          Surfex.Record.relate(scans, entries, from, to, type, meta,
            evidence: R.evidence!(root, opts)
          )

    R.record(root, result)
  end
end
