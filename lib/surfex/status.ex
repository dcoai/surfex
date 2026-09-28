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
    * **orphaned** — an end recorded at a hash is no longer scanned (removed, or renamed)
    * **planned** — an end was recorded without a hash, before it existed, and still
      isn't scanned. When it appears, the relation dangles on that end until confirmed.
    * **dangling** — both ids are scanned, but at least one is at a different hash than
      the tip recorded; the report names which ends changed
    * **current** — both ends are at the hashes the tip recorded

  A relation is also **impacted** when one of its ends depends on something (a
  `depends_on` relation from that end) whose relation is not current. That is a flag, not
  a failure: re-confirming everything downstream of every change would train people to
  confirm without reading.

  A scanned id in no relation at all is **new**. A spec id whose every live `implements`
  relation is planned is **unimplemented**. A test's declaration (`@tag verifies: "id"`)
  that names no spec unit, or a bare id more than one file has, is **broken**.

  ## Policy

  `require:` in `.surfex.exs` names, per kind or spec role, the relation types every
  scanned id of it must take part in, e.g. `require: [code: [:implements], test_hint:
  [:verifies]]`: every code item implements something, and every test hint is verified.
  An id with no non-retired relation of one of those types is **unmet**, once per rule it
  fails. A planned relation counts: the intent is on record.

  **Failing** means any dangling, orphaned or conflicted relation, any unmet id, or any
  broken declaration. Planned
  relations fail too when derived with `planned: :fail` (`mix surfex.status --no-planned`),
  for a check that everything planned has been built, such as a release's.
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @type state :: :current | :dangling | :orphaned | :conflicted | :retired | :planned
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
          broken: [%{scan: Scan.t(), type: atom, ref: String.t(), reason: term}],
          unimplemented: [Scan.t()],
          planned: :allow | :fail,
          scans: %{{atom, String.t()} => Scan.t()}
        }

  @doc """
  The status of every relation in `entries` against `scans`, the new ids, and the ids that
  fail the `require` policy.
  """
  @spec derive([Scan.t()], [Entry.t()], keyword, keyword) :: t
  def derive(scans, entries, require \\ [], opts \\ []) do
    planned = Keyword.get(opts, :planned, :allow)

    unless planned in [:allow, :fail],
      do: raise(ArgumentError, "planned: must be :allow or :fail, got #{inspect(planned)}")

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
      broken: broken(scans),
      unimplemented: unimplemented(scans, relations),
      planned: planned,
      scans: by_id
    }
  end

  @doc """
  Whether the status fails the check: any dangling, orphaned, conflicted or unmet, and any
  planned relation when it was derived with `planned: :fail`.
  """
  @spec failing?(t) :: boolean
  def failing?(status) do
    failing = [:dangling, :orphaned, :conflicted]
    failing = if status.planned == :fail, do: [:planned | failing], else: failing

    status.unmet != [] or status.broken != [] or
      Enum.any?(status.relations, &(&1.state in failing))
  end

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
  How many spec units were scanned, by role: sections, marked blocks and test hints.
  """
  @spec units(t) :: %{
          section: non_neg_integer,
          block: non_neg_integer,
          test_hint: non_neg_integer
        }
  def units(status) do
    counts =
      for {_key, %Scan{kind: :spec, role: role}} <- status.scans, reduce: %{} do
        acc -> Map.update(acc, role, 1, &(&1 + 1))
      end

    %{
      section: Map.get(counts, :section, 0),
      block: Map.get(counts, :block, 0),
      test_hint: Map.get(counts, :test_hint, 0)
    }
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

  # An end recorded at a hash and no longer scanned is gone: orphaned. An end recorded
  # without one (planned) and still not scanned is waiting: planned. Once a planned id is
  # scanned it differs from the recorded nil, so the relation dangles on that end until
  # someone confirms it, as with any other change.
  defp judge_tip(%Entry{ends: ends}, by_id) do
    looked = Enum.map(ends, &{{&1.kind, &1.id}, &1.hash, Map.get(by_id, {&1.kind, &1.id})})

    gone = for {key, hash, nil} <- looked, hash != nil, do: key
    waiting = for {key, nil, nil} <- looked, do: key

    cond do
      gone != [] ->
        {:orphaned, gone}

      waiting != [] ->
        {:planned, waiting}

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

  # A spec id whose every live `implements` relation is still planned: meant to be built,
  # and not built yet.
  defp unimplemented(scans, relations) do
    by_spec =
      for %{type: :implements, state: state, relation: {_, a, b}} <- relations,
          state != :retired,
          {:spec, _} = end_ <- [a, b],
          reduce: %{},
          do: (acc -> Map.update(acc, end_, [state], &[state | &1]))

    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        scan.kind == :spec,
        states = Map.get(by_spec, {:spec, scan.id}, []),
        states != [] and Enum.all?(states, &(&1 == :planned)),
        do: scan
  end

  # ── Policy ──────────────────────────────────────────────────────────────

  defp unmet(scans, relations, require) do
    live =
      for %{state: state, type: type, relation: {_, a, b}} <- relations,
          state != :retired,
          end_ <- [a, b],
          reduce: %{},
          do: (acc -> Map.update(acc, end_, MapSet.new([type]), &MapSet.put(&1, type)))

    # A kind's rule applies to every scan of that kind; a spec role's rule (`test_hint:`)
    # to every spec unit in that role. Each rule that isn't met is its own entry.
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        key <- Enum.uniq([scan.kind, scan.role]),
        key != nil,
        requires = Keyword.get(require, key, []),
        requires != [],
        not Enum.any?(
          requires,
          &MapSet.member?(Map.get(live, {scan.kind, scan.id}, MapSet.new()), &1)
        ),
        do: %{scan: scan, requires: requires}
  end

  # A declaration in a test (`@tag verifies: "id"`) that names no spec unit, or a bare id
  # that more than one file has.
  defp broken(scans) do
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        {type, ref} <- scan.declares,
        {:error, why} <- [Scan.resolve(scans, ref)],
        do: %{scan: scan, type: type, ref: ref, reason: why}
  end
end
