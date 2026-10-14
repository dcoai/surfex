defmodule Mix.Tasks.Surfex.Migrate do
  @shortdoc "Move a section's implements to the claims inside it (--report: what it buys)"

  @moduledoc """
  The migration aid (`Surfex.Migrate`, spec §14.1): moving a section's `implements`
  relations to the claims inside it, one section at a time, as work touches it.

      mix surfex.migrate spec.md#carts                  # the proposals for one section
      mix surfex.migrate spec/08-reclamation.md --within  # every section under a prefix
      mix surfex.migrate spec.md#carts --accept          # record the single ones
      mix surfex.migrate spec.md#carts --code MyApp.Cart.add/2 --to spec.md#adding
      mix surfex.migrate --report                        # every section, worst first
      mix surfex.migrate --report spec.md#carts          # what migrating it buys

  For each live `implements` between code and the section (or a table in it), it lists
  the claims inside the section that could own the code: a row whose key names it (an
  arity-less key `Mod.fun` names every arity), a contract unit for it, a claim whose
  verifying test calls it, or, failing those, one whose test reaches it, through what.
  Arities of one definition (default arguments) are one proposal. **None** comes first:
  code no claim owns is the spec work the migration surfaces, a claim not written yet or
  code that doesn't belong to the section. **Several** are listed and never decided:
  which claim code realises is a judgement. Listing writes nothing.

  `--accept [--note N]` records each single proposal (`Surfex.Migrate.accept/4`): the code
  related to its claim, **proposed**, with `migrates` naming the section. Such a relation
  **migrates**: it doesn't fail the status while the section still holds its relation, so
  a section can be migrated across several commits. Validate it as any `implements`, by
  evidence or a review (`mix surfex.validate TEST CLAIM`). Once every claim relation of a
  code item is validated the pair is **settled**, and the section's relation is retired,
  noting the claims it moved to: by the next `--accept`, or by `mix surfex.suggest
  --accept`. A section never loses a relation before its claim holds one. `--code ID --to
  CLAIM` (`--to` once per claim) records your choice for a proposal with several
  candidates, or one with none once its claim is written (`Surfex.Migrate.choose/6`).

  `--report` is read-only too. Per section: the relations an edit of its text dangles now
  and after migration, its section-grain `implements` by outcome, the marking a prose
  section needs first (the relations one marker line dangles, paid once), and each code
  item's dangle width now and after, widest after first. With no section, every section
  holding section-grain `implements`, worst first, after the population: the sections whose
  claims are already units (they migrate today) and the prose ones (they need claim forms,
  spec §11.1).
  """

  use Mix.Task

  alias Surfex.Migrate
  alias Surfex.Record.Mix, as: R

  @impl Mix.Task
  def run(args) do
    {opts, refs} =
      R.parse(args,
        within: :boolean,
        report: :boolean,
        accept: :boolean,
        code: :string,
        to: :keep
      )

    {root, scans, entries, meta} = R.context(opts)
    refs = for ref <- R.units(refs, scans, opts), do: String.replace_prefix(ref, "spec:", "")

    sections =
      for ref <- refs, reduce: [] do
        acc ->
          case Migrate.sections(scans, ref, within: opts[:within] == true) do
            {:ok, ids} -> acc ++ ids
            {:error, why} -> Mix.raise(why)
          end
      end
      |> Enum.uniq()

    cond do
      opts[:report] ->
        report(Migrate.report(scans, entries, if(refs == [], do: :all, else: sections)), refs)

      sections == [] ->
        Mix.raise("name a section: mix surfex.migrate SECTION [--within], or --report")

      opts[:code] != nil ->
        claims =
          for c <- R.units(Keyword.get_values(opts, :to), scans, opts),
              do: String.replace_prefix(c, "spec:", "")

        case {sections, claims} do
          {[section], [_ | _]} ->
            R.record(root, Migrate.choose(scans, entries, section, opts[:code], claims, meta))

          {[_], []} ->
            Mix.raise("--code needs the claim it moves to: --to CLAIM (once per claim)")

          _ ->
            Mix.raise("--code moves code from one section: name one, without --within")
        end

      opts[:accept] ->
        R.record(root, Migrate.accept(scans, entries, sections, meta))

      true ->
        list(scans, entries, sections)
    end
  end

  defp list(scans, entries, sections) do
    proposals = Migrate.proposals(scans, entries, sections)

    if proposals == [],
      do:
        Mix.shell().info(
          "no section-grain implements in #{Enum.join(sections, ", ")}: nothing to migrate"
        )

    for p <- proposals, do: Mix.shell().info(line(p))

    counts = Enum.frequencies_by(proposals, & &1.outcome)

    if proposals != [],
      do:
        Mix.shell().info(
          "#{length(proposals)} proposals: #{Map.get(counts, :single, 0)} single, " <>
            "#{Map.get(counts, :several, 0)} several, #{Map.get(counts, :none, 0)} none" <>
            if(counts[:migrating], do: ", #{counts[:migrating]} migrating", else: "") <>
            if(counts[:single], do: "; --accept records the single ones", else: "")
        )
  end

  defp line(%{outcome: :migrating, settled: true} = p),
    do:
      "settled   #{codes(p)} → #{claims(p)}: every claim holds it; --accept (or " <>
        "mix surfex.suggest --accept) retires the section's relation"

  defp line(%{outcome: :migrating} = p),
    do:
      "migrating #{codes(p)} → #{claims(p)}: validate the claim's relation (evidence, or " <>
        "mix surfex.validate TEST CLAIM); the section keeps its relation until then"

  defp line(%{outcome: :none} = p),
    do:
      "none      #{codes(p)}: no claim inside #{p.unit} names it or has a test calling or " <>
        "reaching it: write the claim it realises (spec §11.1), or it doesn't belong here"

  defp line(%{outcome: :several} = p),
    do:
      "several   #{codes(p)} → " <>
        Enum.map_join(p.claims, "; ", &"#{&1.claim} (#{why(&1.why)})") <>
        ": which it realises is a judgement: mix surfex.migrate #{p.section} --code " <>
        "#{hd(p.codes)} --to CLAIM"

  defp line(%{outcome: :single, claims: [c]} = p),
    do: "single    #{codes(p)} → #{c.claim} (#{why(c.why)})"

  defp claims(p), do: Enum.map_join(p.claims, ", ", & &1.claim)

  defp codes(%{codes: [one], unit: unit, section: section}),
    do: one <> on(unit, section)

  defp codes(%{codes: many, unit: unit, section: section}),
    do: Enum.join(many, ", ") <> " (one definition)" <> on(unit, section)

  defp on(unit, unit), do: ""
  defp on(unit, _section), do: " on #{unit}"

  defp why(reasons) do
    reasons
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {:names, [{:names, key} | _]} ->
        "its key #{key} names it"

      {:calls, [{:calls, t}]} ->
        "called by its test #{t}"

      {:calls, [{:calls, t} | more]} ->
        "called by its test #{t} and #{length(more)} more"

      {:reaches, [{:reaches, through, t} | more]} ->
        "reached through #{through} by its test #{t}" <>
          if(more == [], do: "", else: " and #{length(more)} more")
    end)
  end

  defp report(%{sections: sections, population: pop}, refs) do
    if refs == [] do
      total = pop.units.implements + pop.prose.implements

      Mix.shell().info(
        "section-grain implements: #{total} in #{pop.units.sections + pop.prose.sections} sections"
      )

      Mix.shell().info(
        "  claims already units: #{pop.units.sections} sections, #{pop.units.implements} implements " <>
          "(they migrate today)"
      )

      Mix.shell().info(
        "  prose: #{pop.prose.sections} sections, #{pop.prose.implements} implements " <>
          "(their claims need ids first, spec §11.1)"
      )
    end

    for s <- sections do
      Mix.shell().info("")

      Mix.shell().info(
        "#{s.section} (#{if s.kind == :prose, do: "prose", else: "claims are units"}): " <>
          "#{s.relations} relations now → #{s.after} after; implements #{s.implements}: " <>
          "#{s.single} single · #{s.several} several · #{s.none} none" <>
          if(s.migrating > 0, do: " · #{s.migrating} migrating", else: "") <>
          if(s.marking > 0, do: "; marking dangles #{s.marking} once", else: "")
      )

      for w <- s.widths do
        Mix.shell().info(
          "  #{Enum.join(w.codes, ", ")}: #{w.now} now → #{w.after} after (#{w.outcome})"
        )
      end
    end
  end
end
