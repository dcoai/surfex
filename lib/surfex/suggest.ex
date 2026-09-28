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
  @type refinement :: %{from: Scan.t(), to: Scan.t()}
  @type pair :: %{from: Scan.t(), to: Scan.t()}
  @type suggestions :: %{
          moves: [move],
          refines: [refinement],
          implements: [candidate],
          verifies: [pair],
          tests: [pair],
          excuses: [pair]
        }

  @doc """
  Every suggestion at once, computed together so none repeats another:

    * **moves** — a spec id the log relates that is no longer scanned, and a new id in no
      relation at the **same version**: a renamed heading, or an anchor added. Only a
      one-to-one match is suggested; two candidates with one version are left alone.
    * **refines** — each marked block and test hint `refines` the section or block it sits
      in (`within`), unless that relation exists in any state.
    * **implements** — `candidates/5`.
    * **verifies** — each test's declaration (`@tag verifies: "id"`) that resolves to a
      spec unit (`Surfex.Scan.resolve/2`).
    * **tests** — each test paired with each scanned code item it calls (in its body or
      the private helpers it reaches).
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
    moves = moves(scans, entries)

    {:ok, moved} =
      Enum.reduce(moves, {:ok, entries}, fn m, {:ok, acc} ->
        {:ok, recorded} = Record.move(scans, acc, m.from, "spec:" <> m.to.id, at: @epoch)
        {:ok, acc ++ recorded}
      end)

    implements = candidates(profile, items, scans, moved, root)

    %{
      moves: moves,
      refines: refinements(scans, moved),
      implements: implements,
      excuses: excusals(profile, items, scans, moved, implements),
      verifies: verifications(scans, moved),
      tests: exercised(scans, moved)
    }
  end

  @doc """
  Records suggestions: each move (`Surfex.Record.move/5`), then each refinement and
  implements candidate as a `relate` at the current hashes. It only creates relations
  that don't exist and carries judgements across moves; it never confirms a dangling
  relation.
  """
  @spec accept_all(suggestions, [Scan.t()], [Entry.t()], keyword) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def accept_all(suggestions, scans, entries, meta) do
    steps =
      Enum.map(suggestions.moves, fn m ->
        &Record.move(scans, &1, m.from, "spec:" <> m.to.id, meta)
      end) ++
        Enum.map(suggestions.refines, fn r ->
          &Record.relate(scans, &1, "spec:" <> r.from.id, "spec:" <> r.to.id, :refines, meta)
        end) ++
        Enum.map(suggestions.verifies, fn v ->
          &Record.relate(scans, &1, "test:" <> v.from.id, "spec:" <> v.to.id, :verifies, meta)
        end) ++
        Enum.map(suggestions.tests, fn t ->
          &Record.relate(scans, &1, "test:" <> t.from.id, "code:" <> t.to.id, :tests, meta)
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

  defp moves(scans, entries) do
    status = Surfex.Status.derive(scans, entries)

    gone =
      for %{state: :orphaned, tips: [tip], changed: changed} <- status.relations,
          end_ <- tip.ends,
          end_.kind == :spec,
          {:spec, end_.id} in changed,
          reduce: %{},
          do: (acc ->
                 Map.update(acc, end_.id, MapSet.new([end_.hash]), &MapSet.put(&1, end_.hash)))

    fresh = for %Scan{kind: :spec} = s <- status.new, do: s

    gone_by_hash =
      gone
      |> Enum.filter(fn {_id, hashes} -> MapSet.size(hashes) == 1 end)
      |> Enum.group_by(fn {_id, hashes} -> Enum.at(hashes, 0) end, &elem(&1, 0))

    fresh_by_hash = Enum.group_by(fresh, & &1.hash)

    for {hash, [old]} <- gone_by_hash,
        [new] <- [Map.get(fresh_by_hash, hash, [])],
        do: %{from: old, to: new}
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
      case Surfex.Status.tips(entries, relation) do
        [tip] -> [tip]
        _ -> []
      end
    end)
  end

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
