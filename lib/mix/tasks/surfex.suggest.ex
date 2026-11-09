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

  **implements** also pairs each claim (a block, test hint, row, rule or contract) that
  nothing implements, itself or a unit it sits in, with the code its verifying tests call
  directly, most specific first: only the calls fewest other claims' tests make are
  listed, each with `also called by the tests of N other claims` when N > 0, and one line
  per claim counts the rest. A `reached` line says, per claim, which called item reaches
  more code and how much (spec §15.1). These are judgements: each is printed with the
  `mix surfex.relate` command that records it and the command that declines it, and
  `--accept` never records them (spec §15.5).

  Once the log is established (it holds a validated `implements`), a code span in prose
  proposes nothing outside a contract: subject headings, citing cells, contracts and a
  claim's tests still do. One line counts the prose citations not proposed, when there
  are any (spec §15.4).

  Pairs already related, in any state, are left out.

      mix surfex.suggest                         # list them; nothing is written
      mix surfex.suggest --accept                # record them
      mix surfex.suggest --accept --note "adopted the relation log"
      mix surfex.suggest --format json           # the same lists, for tools and agents

  `--accept` only creates relations that don't exist, and carries judgements across
  moves. It never confirms a dangling relation: that stays `mix surfex.confirm`, one named
  id at a time.

  An undeclared `verifies` resting on evidence, a review, a judgement or a baseline isn't
  retired, since a tag can go by mistake and a retired relation doesn't come back on its own:
  it is listed, and the status fails until the tag is restored. `--accept --retire-undeclared`
  retires those too, for tags removed on purpose.

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
        strict: [
          accept: :boolean,
          retire_undeclared: :boolean,
          note: :string,
          config: :string,
          merge: :keep,
          format: :string
        ]
      )

    if opts[:retire_undeclared] && !opts[:accept],
      do: Mix.raise("--retire-undeclared goes with --accept: read the list first")

    format = opts[:format] || "text"

    if format not in ["text", "json"],
      do: Mix.raise("--format must be text or json, got #{inspect(format)}")

    if format == "json" and opts[:accept],
      do: Mix.raise("--format json lists the suggestions; run --accept without it")

    root = File.cwd!()
    # Read first: a --merge file that isn't there fails whether or not there's work to do.
    evidence = R.evidence!(root, opts)
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    if Config.project_scanner?(config), do: Mix.Task.run("compile")

    items = Config.items(config, root)
    profile = Config.profile!(config, namespace, items)
    scans = Config.scans_of(items, config, root)
    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []

    suggestions = Suggest.all(profile, items, scans, entries, root)

    if format == "json",
      do: Mix.shell().info(Suggest.json(suggestions)),
      else: report(suggestions, {root, scans, entries}, opts, evidence)
  end

  defp report(suggestions, {root, scans, entries}, opts, evidence) do
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

    for u <- suggestions.undeclared do
      if u.validated do
        Mix.shell().info(
          "undeclared  verifies #{u.test} → #{u.spec} (validated, so not retired: restore the " <>
            "tag, or --accept --retire-undeclared)"
        )
      else
        Mix.shell().info("retire      verifies #{u.test} → #{u.spec} (no longer declared)")
      end
    end

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

    {claimed, cited} = Enum.split_with(suggestions.implements, &Suggest.claim_derived?/1)

    for c <- cited ++ claimed do
      Mix.shell().info("implements  #{c.spec.id} ↔ #{c.code.id}  (#{why(c)})")

      if Suggest.claim_derived?(c),
        do: Mix.shell().info("  relate:  " <> Suggest.relate_command(c.spec.id, c.code.id))

      Mix.shell().info(
        "  decline: " <> Suggest.decline_command(:implements, c.spec.id, c.code.id)
      )
    end

    for a <- suggestions.also_called,
        do:
          Mix.shell().info(
            "also called #{a.spec}: +#{a.count} #{plural(a.count, "call")} also made by " <>
              "the tests of other claims"
          )

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

    # A claim's tests' calls are judgements, reviewed one at a time (§15.5).
    if claimed != [],
      do:
        Mix.shell().info(
          "#{length(claimed)} claim-derived implements to review one at a time: " <>
            "not recorded by --accept"
        )

    count =
      suggestions
      |> Map.drop([:reached, :withheld, :also_called])
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
      |> Kernel.-(length(claimed))

    cond do
      count == 0 and claimed == [] ->
        Mix.shell().info("nothing to suggest: everything the spec implies is already related")

      count == 0 ->
        :ok

      opts[:accept] ->
        # The scans and log read above: reading them again cost the time of the whole run.
        meta = R.meta(root, Keyword.take(opts, [:note]))
        options = [evidence: evidence, retire_undeclared: opts[:retire_undeclared] == true]
        R.record(root, Suggest.accept_all(suggestions, scans, entries, meta, options))

      true ->
        Mix.shell().info("#{count} suggested; `mix surfex.suggest --accept` records them")
    end
  end

  defp why(%{cited_at: {file, line}}), do: "cited at #{file}:#{line}"

  defp why(%{tests: tests, shared: shared}), do: called(tests) <> also(shared)

  defp called([test]), do: "called by its test #{test}"
  defp called([test | more]), do: "called by its test #{test} and #{length(more)} more"

  defp also(0), do: ""
  defp also(n), do: "; also called by the tests of #{n} other #{plural(n, "claim")}"

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
