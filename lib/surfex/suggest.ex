defmodule Surfex.Suggest do
  @moduledoc """
  Candidate relations from what the spec already says: every place a spec section names a
  code item is a candidate `implements` relation between the two.

  It reads the spec's citations with `Surfex.Cite`, under the project's profile
  (`Surfex.Status.Config.profile!/2`). For each **resolved** citation, the candidate is the pair *(the innermost spec
  unit containing the citation's line, each code item the citation names)*: a citation in
  a marked block relates the block, not its section. A family (`Mod.fun`) names every
  member. Leaving things out:

    * a pair already related, in any state, including retired: suggesting it again would
      overrule a decision already on record
    * a citation inside a fenced code block, which has no line to place it in a section
    * a named item that is not a code scan (a file target, say)

  This is also how a project adopts the relation log: `mix surfex.log --init`, then
  `mix surfex.suggest --accept`.
  """

  alias Surfex.{Cite, Profile, Record, Scan}
  alias Surfex.Log.Entry

  @type candidate :: %{spec: Scan.t(), code: Scan.t(), cited_at: {String.t(), pos_integer}}

  @doc """
  The candidates, sorted by section then item, one per pair: the first citation that
  proposes a pair is where it was cited.
  """
  @spec candidates(Profile.t(), [Surfex.Item.t()], [Scan.t()], [Entry.t()], String.t()) :: [
          candidate
        ]
  def candidates(profile, items, scans, entries, root) do
    citations = Cite.citations(items, profile, root)
    sections = Enum.filter(scans, &(&1.kind == :spec))
    code = for s <- scans, s.kind == :code, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %{status: :resolved} = c <- citations,
        c.section != "(code block)",
        section = section_at(sections, c.file, c.line),
        section != nil,
        key <- c.items,
        item = Map.get(code, key),
        item != nil,
        not MapSet.member?(related, Entry.relation(:implements, section, item)) do
      %{spec: section, code: item, cited_at: {c.file, c.line}}
    end
    |> Enum.uniq_by(&{&1.spec.id, &1.code.id})
    |> Enum.sort_by(&{&1.spec.id, &1.code.id})
  end

  @doc """
  One `relate` entry per candidate, at the current hashes. It only ever creates relations
  that don't exist; it never confirms a dangling one.
  """
  @spec accept([candidate], [Scan.t()], [Entry.t()], keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept(candidates, scans, entries, meta) do
    Enum.reduce_while(candidates, {:ok, []}, fn c, {:ok, acc} ->
      case Record.relate(
             scans,
             entries ++ acc,
             "spec:" <> c.spec.id,
             "code:" <> c.code.id,
             :implements,
             meta
           ) do
        {:ok, recorded} -> {:cont, {:ok, acc ++ recorded}}
        error -> {:halt, error}
      end
    end)
  end

  @type move :: %{from: String.t(), to: Scan.t()}
  @type ambiguous :: %{from: [String.t()], to: [String.t()]}
  @type refinement :: %{from: Scan.t(), to: Scan.t()}
  @type pair :: %{from: Scan.t(), to: Scan.t()}
  @type suggestions :: %{
          moves: [move],
          ambiguous: [ambiguous],
          refines: [refinement],
          implements: [candidate],
          verifies: [pair],
          tests: [pair],
          excuses: [pair],
          undeclared: [%{test: String.t(), spec: String.t()}],
          refresh: [%{type: atom, from: Scan.t(), to: Scan.t()}]
        }

  @doc """
  Every suggestion at once, computed together so none repeats another:

    * **moves** — a spec or test id the log knows that is no longer scanned, and a new id
      of the same kind with no records of its own at the **same version**: a renamed
      heading or an added anchor; a test whose module, `describe` or file was renamed (a
      split test file). Only a one-to-one match is suggested.
    * **ambiguous** — versions found under more than one gone id or new id: reported, not
      suggested, since which is which is a judgement.
    * **refines** — each marked block and test hint `refines` the section or block it sits
      in (`within`), unless that relation exists in any state.
    * **implements** — `candidates/5`.
    * **verifies** — each test's declaration (`@tag verifies: "id"`) that resolves to a
      spec unit (`Surfex.Scan.resolve/2`).
    * **tests** — each test paired with each scanned code item it calls (in its body or
      the private helpers it reaches).
    * **refresh** — each dangling structural relation (`tests`, `refines`) whose fact the
      source still states: the test still calls or names the code, the unit still holds
      the block or hint. Judgement relations (`implements`, `verifies`, `excuses`) are never
      refreshed.
    * **undeclared** — each `verifies` relation whose test no longer declares it
      (`Surfex.Status`), to retire: the test's source no longer makes the claim.
    * **excuses** — each code item nothing implements (and no implements candidate will),
      paired with the class of the first rule it matches, as `Surfex.Coverage` matches
      them. A parent counts as cited when something implements it. `never_excused`
      kinds are never excused.

  Refines and implements are computed as if the moves were already recorded, so a moved
  section's relations aren't suggested again under its new id.
  """
  # Only for computing what the moves would leave; never recorded.
  @epoch "1970-01-01T00:00:00Z"

  @spec all(Profile.t(), [Surfex.Item.t()], [Scan.t()], [Entry.t()], String.t()) :: suggestions
  def all(profile, items, scans, entries, root) do
    {moves, ambiguous} = moves(scans, entries)

    {:ok, moved} =
      Enum.reduce(moves, {:ok, entries}, fn m, {:ok, acc} ->
        {:ok, recorded} =
          Record.move(scans, acc, prefixed(m.to.kind, m.from), prefixed(m.to), at: @epoch)

        {:ok, acc ++ recorded}
      end)

    implements = candidates(profile, items, scans, moved, root)

    %{
      moves: moves,
      ambiguous: ambiguous,
      refines: refinements(scans, moved),
      implements: implements,
      excuses: excusals(profile, items, scans, moved, implements),
      verifies: verifications(scans, moved),
      undeclared: Surfex.Status.derive(scans, moved).undeclared,
      refresh: refreshed(scans, moved),
      tests: exercised(scans, moved)
    }
  end

  @doc """
  Records suggestions: each move (`Surfex.Record.move/5`), then each other suggestion as
  a `relate` at the current hashes, and each undeclared `verifies` relation as a
  `retire`. `implements`, `verifies` and `excuses` relations are recorded as proposed,
  a `verifies` relation on its failing run when `opts[:evidence]` shows one (§18).
  Moves carry each relation's basis across. It re-records a dangling relation only
  when it is structural and the source still states it (refresh); it never confirms a
  dangling judgement.
  """
  @spec accept_all(suggestions, [Scan.t()], [Entry.t()], keyword, keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept_all(suggestions, scans, entries, meta, opts \\ []) do
    steps =
      Enum.map(suggestions.moves, fn m ->
        &Record.move(scans, &1, prefixed(m.to.kind, m.from), prefixed(m.to), meta)
      end) ++
        Enum.map(suggestions.refines, fn r ->
          &Record.relate(scans, &1, "spec:" <> r.from.id, "spec:" <> r.to.id, :refines, meta)
        end) ++
        Enum.map(suggestions.verifies, fn v ->
          &Record.relate(
            scans,
            &1,
            "test:" <> v.from.id,
            "spec:" <> v.to.id,
            :verifies,
            meta,
            opts
          )
        end) ++
        Enum.map(suggestions.tests, fn t ->
          &Record.relate(scans, &1, "test:" <> t.from.id, "code:" <> t.to.id, :tests, meta)
        end) ++
        Enum.map(suggestions.refresh, fn f ->
          &Record.relate(
            scans,
            &1,
            "#{f.from.kind}:#{f.from.id}",
            "#{f.to.kind}:#{f.to.id}",
            f.type,
            Keyword.put_new(meta, :note, "the source still states it")
          )
        end) ++
        Enum.map(suggestions.undeclared, fn u ->
          &Record.retire(
            scans,
            &1,
            "test:" <> u.test,
            "spec:" <> u.spec,
            :verifies,
            Keyword.put_new(meta, :note, "the test no longer declares that it verifies this")
          )
        end) ++
        Enum.map(suggestions.excuses, fn x ->
          &Record.relate(scans, &1, "class:" <> x.from.id, "code:" <> x.to.id, :excuses, meta)
        end)

    with {:ok, recorded} <-
           Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
             case step.(entries ++ acc) do
               {:ok, more} -> {:cont, {:ok, acc ++ more}}
               error -> {:halt, error}
             end
           end),
         {:ok, implemented} <- accept(suggestions.implements, scans, entries ++ recorded, meta) do
      {:ok, recorded ++ implemented}
    end
  end

  defp prefixed(kind, id), do: "#{kind}:#{id}"
  defp prefixed(%Scan{kind: kind, id: id}), do: prefixed(kind, id)

  # Moves of spec units and tests, and the matches too ambiguous to suggest.
  defp moves(scans, entries) do
    status = Surfex.Status.derive(scans, entries)
    scanned = MapSet.new(scans, &{&1.kind, &1.id})

    # Ends of orphaned relations, and a test's observations: a test may have records and
    # no relation (§14).
    # A retired relation's gone end counts too: its retirement is a decision to carry (§14).
    orphaned =
      for %{state: state, tip: %Entry{} = tip, changed: changed} <- status.relations,
          state in [:orphaned, :retired],
          end_ <- tip.ends,
          end_.kind in [:spec, :test],
          state == :retired or {end_.kind, end_.id} in changed,
          not MapSet.member?(scanned, {end_.kind, end_.id}),
          do: {end_.kind, end_.id, end_.hash}

    observed =
      for %Entry{op: :observe, ends: [%{kind: kind, id: id, hash: hash}]} <- entries,
          not MapSet.member?(scanned, {kind, id}),
          not Enum.any?(orphaned, &match?({^kind, ^id, _}, &1)),
          do: {kind, id, hash}

    gone =
      Enum.reduce(orphaned ++ observed, %{}, fn {kind, id, hash}, acc ->
        Map.update(acc, {kind, id}, MapSet.new([hash]), &MapSet.put(&1, hash))
      end)

    recorded = MapSet.new(for e <- entries, end_ <- e.ends, do: {end_.kind, end_.id})

    fresh =
      for %Scan{kind: kind} = s <- status.new,
          kind in [:spec, :test],
          not MapSet.member?(recorded, {kind, s.id}),
          do: s

    gone_by_version =
      gone
      |> Enum.filter(fn {_key, hashes} -> MapSet.size(hashes) == 1 end)
      |> Enum.group_by(fn {{kind, _id}, hashes} -> {kind, Enum.at(hashes, 0)} end, fn {{_k, id},
                                                                                       _} ->
        id
      end)

    fresh_by_version = Enum.group_by(fresh, &{&1.kind, &1.hash})

    matches =
      for {version, olds} <- gone_by_version,
          news = Map.get(fresh_by_version, version, []),
          news != [],
          do: {Enum.sort(olds), Enum.sort_by(news, & &1.id)}

    {for({[old], [new]} <- matches, do: %{from: old, to: new}),
     for(
       {olds, news} <- matches,
       length(olds) > 1 or length(news) > 1,
       do: %{from: olds, to: Enum.map(news, & &1.id)}
     )}
  end

  defp excusals(profile, items, scans, entries, implements) do
    classes = for %Scan{kind: :class} = s <- scans, into: %{}, do: {s.id, s}
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    implemented =
      MapSet.new(
        for(
          %Entry{type: :implements, op: :relate, ends: ends} <- live_tips(entries),
          %{kind: :code, id: id} <- ends,
          do: id
        ) ++ Enum.map(implements, & &1.code.id)
      )

    for item <- items,
        scan = Scan.for_item(Map.values(code), item),
        scan != nil,
        not MapSet.member?(implemented, scan.id),
        {:expected, class} <- [Surfex.Coverage.verdict(item, implemented, profile)],
        class_scan = Map.get(classes, class),
        class_scan != nil,
        not MapSet.member?(related, Entry.relation(:excuses, class_scan, scan)),
        uniq: true,
        do: %{from: class_scan, to: scan}
  end

  # The judgement in force for each relation, when there is exactly one.
  defp live_tips(entries) do
    entries
    |> Enum.group_by(&Entry.relation/1)
    |> Enum.flat_map(fn {relation, _} ->
      case Surfex.Status.representative(Surfex.Status.tips(entries, relation)) do
        nil -> []
        tip -> [tip]
      end
    end)
  end

  # A dangling structural relation whose fact the source still states: the test still
  # calls or names the code (`tests`), the block or hint still sits in the unit
  # (`refines`). It records a fact read from source, not a judgement, so re-reading the
  # source is what re-establishes it (§18). Judgement relations are never refreshed.
  defp refreshed(scans, entries) do
    by_id = Map.new(scans, &{{&1.kind, &1.id}, &1})

    for %{state: :dangling, type: type, relation: {_, a, b}} <-
          Surfex.Status.derive(scans, entries).relations,
        type in [:tests, :refines],
        from = by_id[a],
        to = by_id[b],
        still?(type, from, to),
        do: %{type: type, from: from, to: to}
  end

  defp still?(:tests, %Scan{calls: calls}, %Scan{id: id}), do: id in calls
  defp still?(:refines, %Scan{within: within}, %Scan{id: id}), do: within == id

  defp verifications(scans, entries) do
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :test, declares: declares} = test <- scans,
        {:verifies, ref} <- declares,
        {:ok, spec} <- [Scan.resolve(scans, ref)],
        not MapSet.member?(related, Entry.relation(:verifies, test, spec)),
        uniq: true,
        do: %{from: test, to: spec}
  end

  defp exercised(scans, entries) do
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :test, calls: calls} = test <- scans,
        id <- calls,
        item = Map.get(code, id),
        item != nil,
        not MapSet.member?(related, Entry.relation(:tests, test, item)),
        do: %{from: test, to: item}
  end

  defp refinements(scans, entries) do
    by_id = for %Scan{kind: :spec} = s <- scans, into: %{}, do: {s.id, s}
    related = MapSet.new(entries, &Entry.relation/1)

    for %Scan{kind: :spec, within: within} = unit <- scans,
        within != nil,
        parent = Map.fetch!(by_id, within),
        not MapSet.member?(related, Entry.relation(:refines, unit, parent)),
        do: %{from: unit, to: parent}
  end

  # The innermost spec unit whose lines contain `line` in `file`. Sections don't overlap
  # (each stops at the next heading), but a marked block sits inside its section, and a
  # citation in the block is about the block's requirement.
  defp section_at(sections, file, line) do
    sections
    |> Enum.filter(fn %Scan{location: %{file: f, lines: {first, last}}} ->
      f == file and line >= first and line <= last
    end)
    |> Enum.max_by(fn %Scan{location: %{lines: {first, _}}} -> first end, fn -> nil end)
  end
end
