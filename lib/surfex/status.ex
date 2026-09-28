defmodule Surfex.Status do
  @moduledoc """
  The state of every relation, derived from the scans (what the spec and code are now) and
  the relation log (what was confirmed). Pure: the same scans and log always give the same
  status.

  ## A relation's state

  A relation is a type and two ends (`Surfex.Log.Entry.relation/1`). The judgement in
  force is its **tip**: an entry of the relation that no other entry of it names as a
  parent.

    * **conflicted** — more than one tip: two entries recorded without seeing each other
      (sharing a parent, or both with none, on two branches)
    * **retired** — the tip retires it
    * **orphaned** — an end's id is no longer scanned (removed, or renamed)
    * **dangling** — both ids are scanned, but at least one is at a different hash than
      the tip recorded; the report names which ends changed
    * **current** — both ends are at the hashes the tip recorded

  A relation is also **impacted** when one of its ends depends on something (a
  `depends_on` relation from that end) whose relation is not current. That is a flag, not
  a failure: re-confirming everything downstream of every change would train people to
  confirm without reading.

  A scanned id in no relation at all is **new**.

  ## Policy

  `require:` in `.surfex.exs` names, per kind, the relation types every scanned id of that
  kind must take part in, e.g. `require: [code: [:implements, :excuses], spec:
  [:implements]]`. An id with no non-retired relation of one of those types is **unmet**.

  **Failing** means any dangling, orphaned or conflicted relation, or any unmet id.
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @type state :: :current | :dangling | :orphaned | :conflicted | :retired
  @type relation_status :: %{
          relation: {atom, {atom, String.t()}, {atom, String.t()}},
          type: atom,
          state: state,
          changed: [{atom, String.t()}],
          impacted: boolean,
          tips: [Entry.t()]
        }
  @type t :: %{
          relations: [relation_status],
          new: [Scan.t()],
          unmet: [%{scan: Scan.t(), requires: [atom]}],
          scans: %{{atom, String.t()} => Scan.t()}
        }

  @doc """
  The status of every relation in `entries` against `scans`, the new ids, and the ids that
  fail the `require` policy.
  """
  @spec derive([Scan.t()], [Entry.t()], keyword) :: t
  def derive(scans, entries, require \\ []) do
    by_id = Map.new(scans, &{{&1.kind, &1.id}, &1})

    relations =
      entries
      |> Enum.group_by(&Entry.relation/1)
      |> Enum.map(fn {relation, group} -> judge(relation, group, by_id) end)
      |> Enum.sort_by(& &1.relation)

    relations = impacted(relations)

    related =
      for r <- relations, {_type, a, b} = r.relation, end_ <- [a, b], into: MapSet.new(), do: end_

    %{
      relations: relations,
      new:
        scans
        |> Enum.reject(&MapSet.member?(related, {&1.kind, &1.id}))
        |> Enum.sort_by(&{&1.kind, &1.id}),
      unmet: unmet(scans, relations, require),
      scans: by_id
    }
  end

  @doc "Whether the status fails the check: any dangling, orphaned, conflicted or unmet."
  @spec failing?(t) :: boolean
  def failing?(status),
    do:
      status.unmet != [] or
        Enum.any?(status.relations, &(&1.state in [:dangling, :orphaned, :conflicted]))

  @doc """
  Counts per relation type and state, plus the new and unmet totals: the summary a person
  reads first.
  """
  @spec summary(t) :: %{atom => %{state => non_neg_integer}}
  def summary(status) do
    status.relations
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, rs} -> {type, Enum.frequencies_by(rs, & &1.state)} end)
  end

  @doc """
  The tips of `relation` among `entries`: its entries that no other entry of it names as a
  parent, oldest first. One tip is the judgement in force; more than one is a conflict;
  none means the log has never recorded the relation.
  """
  @spec tips([Entry.t()], {atom, {atom, String.t()}, {atom, String.t()}}) :: [Entry.t()]
  def tips(entries, relation),
    do: entries |> Enum.filter(&(Entry.relation(&1) == relation)) |> tips_of()

  defp tips_of(group) do
    named = group |> Enum.flat_map(& &1.parents) |> MapSet.new()
    group |> Enum.reject(&MapSet.member?(named, &1.id)) |> Enum.sort_by(&{&1.at, &1.id})
  end

  # ── Judging one relation ────────────────────────────────────────────────

  defp judge({type, _a, _b} = relation, group, by_id) do
    tips = tips_of(group)

    {state, changed} =
      case tips do
        [tip] -> judge_tip(tip, by_id)
        _ -> {:conflicted, []}
      end

    %{relation: relation, type: type, state: state, changed: changed, impacted: false, tips: tips}
  end

  defp judge_tip(%Entry{op: :retire}, _by_id), do: {:retired, []}

  defp judge_tip(%Entry{ends: ends}, by_id) do
    looked = Enum.map(ends, &{{&1.kind, &1.id}, &1.hash, Map.get(by_id, {&1.kind, &1.id})})

    cond do
      Enum.any?(looked, fn {_, _, scan} -> scan == nil end) ->
        {:orphaned, for({key, _, nil} <- looked, do: key)}

      true ->
        case for({key, hash, scan} <- looked, scan.hash != hash, do: key) do
          [] -> {:current, []}
          changed -> {:dangling, changed}
        end
    end
  end

  # A relation is impacted when an end of it depends on something whose dependency
  # relation is not current.
  defp impacted(relations) do
    troubled =
      for %{type: :depends_on, state: state, relation: {_, from, _to}} <- relations,
          state != :current and state != :retired,
          into: MapSet.new(),
          do: from

    Enum.map(relations, fn %{relation: {_type, a, b}} = r ->
      %{
        r
        | impacted:
            r.type != :depends_on and (MapSet.member?(troubled, a) or MapSet.member?(troubled, b))
      }
    end)
  end

  # ── Policy ──────────────────────────────────────────────────────────────

  defp unmet(scans, relations, require) do
    live =
      for %{state: state, type: type, relation: {_, a, b}} <- relations,
          state != :retired,
          end_ <- [a, b],
          reduce: %{},
          do: (acc -> Map.update(acc, end_, MapSet.new([type]), &MapSet.put(&1, type)))

    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        requires = Keyword.get(require, scan.kind, []),
        requires != [],
        not Enum.any?(
          requires,
          &MapSet.member?(Map.get(live, {scan.kind, scan.id}, MapSet.new()), &1)
        ),
        do: %{scan: scan, requires: requires}
  end
end
