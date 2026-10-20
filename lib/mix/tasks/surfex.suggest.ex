defmodule Mix.Tasks.Surfex.Suggest do
  @shortdoc "Suggest relations from what the spec already says (--accept to record them)"

  @moduledoc """
  Lists what the spec already implies (`Surfex.Suggest.all/5`):

    * **moves** — a spec or test id the log knows that is gone, and a new id at the same
      version: a renamed heading or an added anchor; a test whose module, `describe` or
      file was renamed, as when a test file is split. Accepting moves each relation, and a
      test's red→green and baseline records, onto the new id (`mix surfex.move`). A
      version found under several ids is listed as ambiguous and never moved.
    * **refines** — each marked block and test hint refines the section or block it sits
      in. A `refines` relation whose unit no longer sits there (moved to another section)
      is listed as a retire; accepting retires it beside the new one.
    * **implements** — each spec unit paired with each code item it names.
    * **verifies** — each test paired with the spec unit its `@tag verifies:` names.
    * **tests** — each test paired with each code item it calls.
    * **excuses** — each code item nothing implements, paired with the class of the first
      rule in `.surfex.exs` it matches.
    * **migrated** — a section's `implements` that `mix surfex.migrate` moved to claims
      whose relations are all validated now: accepting retires the section's.

  **implements** also pairs each claim (a block, test hint, row, rule or contract) with the
  code its verifying tests call directly, and a `reached` line says, per claim, which
  called item reaches more code and how much: name the ones that realise the claim with
  `mix surfex.relate` (spec §15.1).

  Once the log is established (it holds a validated `implements`), a code span in prose
  proposes nothing outside a contract: subject headings, citing cells, contracts and a
  claim's tests still do. One line counts the prose citations not proposed, when there
  are any (spec §15.4).

  Pairs already related, in any state, are left out.

      mix surfex.suggest                         # list them; nothing is written
      mix surfex.suggest --accept                # record them
      mix surfex.suggest --accept --note "adopted the relation log"

  `--accept` only creates relations that don't exist, and carries judgements across
  moves. It never confirms a dangling relation: that stays `mix surfex.confirm`, one named
  id at a time.

  Adopting the relation log is `mix surfex.log --init`, then this with `--accept`.
  """

  use Mix.Task

  alias Surfex.{Log, Suggest}
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [accept: :boolean, note: :string, config: :string, merge: :keep]
      )

    root = File.cwd!()
    # Read first: a --merge file that isn't there fails whether or not there's work to do.
    evidence = R.evidence!(root, opts)
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    items = Config.items(config, root)
    profile = Config.profile!(config, namespace, items)
    scans = Config.scans(config, root)
    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []

    suggestions = Suggest.all(profile, items, scans, entries, root)

    for m <- suggestions.moves, do: Mix.shell().info("move        #{m.from} → #{m.to.id}")

    for a <- suggestions.ambiguous,
        do:
          Mix.shell().info(
            "ambiguous   #{Enum.join(a.from, ", ")} → #{Enum.join(a.to, ", ")}: one version, " <>
              "several ids; move by hand (mix surfex.move)"
          )

    for r <- suggestions.refines, do: Mix.shell().info("refines     #{r.from.id} → #{r.to.id}")

    for v <- suggestions.verifies, do: Mix.shell().info("verifies    #{v.from.id} → #{v.to.id}")
    for t <- suggestions.tests, do: Mix.shell().info("tests       #{t.from.id} → #{t.to.id}")

    for f <- suggestions.refresh,
        do:
          Mix.shell().info(
            "refresh     #{f.type} #{f.from.id} → #{f.to.id} (the source still states it)"
          )

    for u <- suggestions.undeclared,
        do: Mix.shell().info("retire      verifies #{u.test} → #{u.spec} (no longer declared)")

    for m <- suggestions.moved,
        do: Mix.shell().info("retire      refines #{m.from} → #{m.to} (now in #{m.now})")

    for m <- suggestions.migrated,
        do:
          Mix.shell().info(
            "retire      implements #{m.code} ↔ #{m.section} (moved to #{Enum.join(m.claims, ", ")}, " <>
              "which #{if match?([_], m.claims), do: "holds", else: "hold"} it now)"
          )

    for x <- suggestions.excuses do
      Mix.shell().info("excuses     #{x.from.id} ↔ #{x.to.id}")
      Mix.shell().info("  decline: " <> Suggest.decline_command(:excuses, x.from.id, x.to.id))
    end

    for c <- suggestions.implements do
      Mix.shell().info("implements  #{c.spec.id} ↔ #{c.code.id}  (#{why(c)})")

      Mix.shell().info(
        "  decline: " <> Suggest.decline_command(:implements, c.spec.id, c.code.id)
      )
    end

    if suggestions.implements != [] or suggestions.excuses != [],
      do:
        Mix.shell().info(
          "a decline is recorded and permanent: the pair is never suggested again " <>
            "(a later relate revives it)"
        )

    # What a claim's tests reach only through other code is a pointer, not a suggestion.
    for r <- suggestions.reached,
        do:
          Mix.shell().info(
            "reached     #{r.spec} through #{r.through}: #{r.count} more items; " <>
              "name the ones that realise this claim with mix surfex.relate"
          )

    # The bootstrap's end, made visible rather than silent (§15.4).
    case suggestions.withheld do
      [] ->
        :ok

      [_] ->
        Mix.shell().info(
          "1 prose citation not proposed (log established: relate the claim, not the sentence)"
        )

      withheld ->
        Mix.shell().info(
          "#{length(withheld)} prose citations not proposed " <>
            "(log established: relate the claim, not the sentence)"
        )
    end

    count =
      suggestions
      |> Map.drop([:reached, :withheld])
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    cond do
      count == 0 ->
        Mix.shell().info("nothing to suggest: everything the spec implies is already related")

      opts[:accept] ->
        {^root, scans, entries, meta} = R.context(Keyword.take(opts, [:note, :config]))
        R.record(root, Suggest.accept_all(suggestions, scans, entries, meta, evidence: evidence))

      true ->
        Mix.shell().info("#{count} suggested; `mix surfex.suggest --accept` records them")
    end
  end

  defp why(%{cited_at: {file, line}}), do: "cited at #{file}:#{line}"

  defp why(%{tests: [test]}), do: "called by its test #{test}"
  defp why(%{tests: [test | more]}), do: "called by its test #{test} and #{length(more)} more"
end
