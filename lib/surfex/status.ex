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

  A **broken citation** is a name the spec cites that resolves to nothing, or to more than
  one item (`Surfex.Cite`): given as `citations:`, so the spec can't name what doesn't exist.

  A scanned id in no relation at all is **new**. A spec id whose every live `implements`
  relation is planned is **unimplemented**. A test's declaration (`@tag verifies: "id"`)
  that names no spec unit, or a bare id more than one file has, is **broken**.

  ## Policy

  `require:` in `.surfex.exs` names, per kind or spec role, the relation types every
  scanned id of it must take part in, e.g. `require: [code: [:implements], test_hint:
  [:verifies]]`: every code item implements something, and every test hint is verified.
  An id with no non-retired relation of one of those types is **unmet**, once per rule it
  fails. A planned relation counts: the intent is on record.

  A `verifies` relation whose test no longer declares its spec unit (the tag was removed or
  changed) is **undeclared**: a claim the source no longer makes.

  A test that `mix test --only verifies:id` can't select by some of the ids it declares (a
  list tag of several, §11) is **unselectable**, with those ids. A list is legitimate, so
  this is information, never a failure.

  An `excuses` relation whose item its class no longer covers is **stale**: the item is
  now implemented, no rule matches it any more, or another class's rule matches it first.
  An excuse must stay true to its class's rules, not only to the versions it was confirmed
  at. Judging it needs the rules, given as `coverage:` (`Surfex.Profile.coverage!/1`).

  **Failing** means any dangling, orphaned or conflicted relation, any unmet id, any
  undeclared `verifies` relation, any broken declaration, any stale excuse, or any broken citation. Planned relations fail too when derived with
  `planned: :fail` (`mix surfex.status --no-planned`), for a check that everything planned
  has been built, such as a release's.

  ## The triangle

  When tests are scanned, each spec unit that something `implements` should be verified
  by a test (`verifies`, to it or to a block or hint inside it), and that test should
  exercise the implementing code: a `tests` relation, or a call its scan record lists. The
  **triangle** lists each side missing:
  `:no_test`, `:test_misses_code` (a verifying test reaches none of the code), and
  `:code_untested` (implementing code no verifying test reaches). It is reported, and
  fails the check only when derived with `triangle: :fail`.
  """

  alias Surfex.Log.Entry
  alias Surfex.Scan

  @type state :: :current | :dangling | :orphaned | :conflicted | :retired | :planned | :proposed
  @type relation_status :: %{
          relation: {atom, {atom, String.t()}, {atom, String.t()}},
          type: atom,
          state: state,
          changed: [{atom, String.t()}],
          impacted: boolean,
          tips: [Entry.t()],
          tip: Entry.t() | nil
        }
  @type gap :: %{
          spec: String.t(),
          gap: :no_test | :test_misses_code | :code_untested,
          test: String.t() | nil,
          code: String.t() | nil
        }
  @type t :: %{
          relations: [relation_status],
          new: [Scan.t()],
          unmet: [%{scan: Scan.t(), requires: [atom]}],
          broken: [%{scan: Scan.t(), type: atom, ref: String.t(), reason: term}],
          triangle: [gap],
          unvalidated: [%{relation: tuple}],
          undeclared: [%{test: String.t(), spec: String.t()}],
          unselectable: [%{test: String.t(), ids: [String.t()]}],
          failed: [%{relation: tuple, test: String.t()}],
          unproven: [%{relation: tuple, test: String.t() | nil, reason: atom}],
          unchecked: [%{relation: tuple, test: String.t(), reason: :excluded | :skipped}],
          citations: [Surfex.Cite.t()],
          stale: [
            %{
              class: String.t(),
              code: String.t(),
              reason: :implemented | :unmatched | {:other_class, String.t()}
            }
          ],
          marks: [
            %{
              id: String.t(),
              state: :open | :orphaned,
              type: atom,
              unit: String.t(),
              note: String.t() | nil,
              by: String.t() | nil,
              at: String.t(),
              location: map | nil
            }
          ],
          discriminated: MapSet.t({String.t(), String.t()}),
          baselined: MapSet.t({String.t(), String.t()}),
          adoption: term,
          policy: %{
            triangle: :report | :fail,
            validated: boolean,
            marks: :allow | :fail,
            baseline: :allow | :fail
          },
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
    unique!(scans)
    planned = Keyword.get(opts, :planned, :allow)
    validated = Keyword.get(opts, :validated, false)
    adoption = Keyword.get(opts, :adoption, %{setting: :reevaluate, trusted: MapSet.new()})
    baseline_policy = Keyword.get(opts, :baseline, :allow)

    unless baseline_policy in [:allow, :fail],
      do:
        raise(
          ArgumentError,
          "baseline: must be :allow or :fail, got #{inspect(baseline_policy)}"
        )

    triangle = Keyword.get(opts, :triangle, :report)

    unless planned in [:allow, :fail],
      do: raise(ArgumentError, "planned: must be :allow or :fail, got #{inspect(planned)}")

    unless triangle in [:report, :fail],
      do: raise(ArgumentError, "triangle: must be :report or :fail, got #{inspect(triangle)}")

    marks_policy = Keyword.get(opts, :marks, :allow)

    unless marks_policy in [:allow, :fail],
      do: raise(ArgumentError, "marks: must be :allow or :fail, got #{inspect(marks_policy)}")

    by_id = Map.new(scans, &{{&1.kind, &1.id}, &1})
    # Every test's declarations resolve against one index, built once (§13).
    resolver = Scan.resolver(scans)

    # Marks and observations aren't relations (§12.1): the relations are judged without them.
    {other_entries, entries} = Enum.split_with(entries, &(not Entry.relation?(&1)))

    # The baselined test versions still in force (§18.1): unchanged, and still trusted.
    baselined =
      MapSet.new(
        for %Entry{op: :observe, type: :baseline, ends: [test]} <- other_entries,
            %Scan{hash: hash, location: %{file: file}} <- [Map.get(by_id, {:test, test.id})],
            hash == test.hash,
            Surfex.Status.Config.trusted?(adoption, file),
            do: {test.id, test.hash}
      )

    mark_entries = Enum.filter(other_entries, &Entry.mark?/1)

    relations =
      entries
      |> Enum.group_by(&Entry.relation/1)
      |> Enum.map(fn {relation, group} -> judge(relation, group, by_id) end)
      |> Enum.sort_by(& &1.relation)

    relations = impacted(relations)

    runs = latest_runs(Keyword.get(opts, :evidence))
    failed = failed(relations, runs)
    failed_relations = MapSet.new(failed, & &1.relation)

    # A claim this run left its test out of is not checked here, not disproved (§17). One
    # whose test failed is reported once, as failed, whatever its basis.
    {unchecked, unproven} =
      scans
      |> unproven(relations, runs)
      |> Enum.reject(&MapSet.member?(failed_relations, &1.relation))
      |> Enum.split_with(&(&1.reason in [:excluded, :skipped]))

    related =
      for r <- relations, {_type, a, b} = r.relation, end_ <- [a, b], into: MapSet.new(), do: end_

    %{
      relations: relations,
      new:
        scans
        |> Enum.reject(&MapSet.member?(related, {&1.kind, &1.id}))
        |> Enum.sort_by(&{&1.kind, &1.id}),
      unmet: unmet(scans, relations, require),
      broken: broken(scans, resolver),
      undeclared: undeclared(scans, relations, resolver),
      # Information, not a failure: a list of several ids is legitimate (§13.1).
      unselectable:
        for(
          %Scan{kind: :test, unselectable: [_ | _] = ids} = t <- scans,
          do: %{test: t.id, ids: ids}
        )
        |> Enum.sort_by(& &1.test),
      citations: Keyword.get(opts, :citations, []),
      stale: stale(scans, relations, Keyword.get(opts, :coverage)),
      failed: failed,
      unproven: unproven,
      unchecked: unchecked,
      triangle: triangle(scans, relations),
      unvalidated: unvalidated(relations, baselined, scans),
      baselined: baselined,
      adoption: adoption.setting,
      marks: marks(mark_entries, by_id),
      discriminated:
        MapSet.new(
          for %Entry{op: :observe, type: :red_green, ends: [test]} <- other_entries,
              do: {test.id, test.hash}
        ),
      policy: %{
        triangle: triangle,
        validated: validated,
        marks: marks_policy,
        baseline: baseline_policy
      },
      unimplemented: unimplemented(scans, relations),
      planned: planned,
      scans: by_id
    }
  end

  @doc """
  Whether the status fails the check: any dangling, orphaned, conflicted or unmet, and any
  planned relation when it was derived with `planned: :fail`, any open or orphaned mark
  with `marks: :fail`.
  """
  @spec failing?(t) :: boolean
  def failing?(status) do
    failing = [:dangling, :orphaned, :conflicted, :proposed]
    failing = if status.planned == :fail, do: [:planned | failing], else: failing

    status.unmet != [] or status.broken != [] or status.stale != [] or status.citations != [] or
      (status.policy.validated == true and status.unvalidated != []) or
      status.undeclared != [] or
      status.failed != [] or
      status.unproven != [] or
      (status.policy.triangle == :fail and status.triangle != []) or
      (status.policy.marks == :fail and status.marks != []) or
      (status.policy.baseline == :fail and baseline_count(status) > 0) or
      Enum.any?(status.relations, &(&1.state in failing))
  end

  # The marks still standing (§13.1): open while the unit is at the version marked,
  # orphaned once it isn't scanned. A resolved mark (the unit moved) and a withdrawn one (a
  # retire names it) are history, not status.
  defp marks(entries, by_id) do
    withdrawn =
      for %Entry{op: :retire} = e <- entries, id <- e.parents, into: MapSet.new(), do: id

    for %Entry{op: :mark, ends: [unit]} = m <- entries,
        not MapSet.member?(withdrawn, m.id),
        # A generator, not `scan = …`: a `nil` scan (orphaned) must not filter the mark out.
        scan <- [Map.get(by_id, {:spec, unit.id})],
        state = mark_state(scan, unit),
        state != :resolved do
      %{
        id: m.id,
        state: state,
        type: m.type,
        unit: unit.id,
        note: m.note,
        by: m.by,
        at: m.at,
        location: scan && scan.location
      }
    end
    |> Enum.sort_by(&{&1.unit, &1.at, &1.id})
  end

  defp mark_state(nil, _unit), do: :orphaned
  defp mark_state(%Scan{hash: hash}, %{hash: hash}), do: :open
  defp mark_state(_scan, _unit), do: :resolved

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
  How many spec units were scanned, by role: sections, marked blocks, test hints, and marked
  tables and their rows.
  """
  @spec units(t) :: %{
          section: non_neg_integer,
          block: non_neg_integer,
          test_hint: non_neg_integer,
          table: non_neg_integer,
          row: non_neg_integer
        }
  def units(status) do
    counts =
      for {_key, %Scan{kind: :spec, role: role}} <- status.scans, reduce: %{} do
        acc -> Map.update(acc, role, 1, &(&1 + 1))
      end

    %{
      section: Map.get(counts, :section, 0),
      block: Map.get(counts, :block, 0),
      test_hint: Map.get(counts, :test_hint, 0),
      table: Map.get(counts, :table, 0),
      row: Map.get(counts, :row, 0)
    }
  end

  @doc """
  The tips of `relation` among `entries`: its entries that no other entry of it names as a
  parent, oldest first. One tip, or several that agree (`representative/1`), is the
  judgement in force; tips that disagree are a conflict; none means the log has never
  recorded the relation.
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
    tip = representative(tips)

    {state, changed} =
      case tip do
        %Entry{} -> judge_tip(tip, by_id)
        nil -> {:conflicted, []}
      end

    %{
      relation: relation,
      type: type,
      state: state,
      changed: changed,
      impacted: false,
      tips: tips,
      tip: tip
    }
  end

  @doc """
  The one judgement a relation's tips record (§13.1): the tip itself when there is one;
  when several tips agree (the same operation, ends at the same versions, and basis,
  recorded without seeing each other), the one with the smallest id; `nil` when they
  disagree, which is a conflict, or when there are none. Who recorded a tip, when, on which
  commit and with which note are context, not part of the judgement.
  """
  @spec representative([Entry.t()]) :: Entry.t() | nil
  def representative([]), do: nil

  def representative(tips) do
    case tips |> Enum.map(&judgement/1) |> Enum.uniq() do
      [_one] -> Enum.min_by(tips, & &1.id)
      _disagree -> nil
    end
  end

  defp judgement(%Entry{} = e),
    do: {e.op, e.type, Enum.map(e.ends, &{&1.kind, &1.id, &1.hash}), e.basis}

  defp judge_tip(%Entry{op: :retire}, _by_id), do: {:retired, []}

  # An end recorded at a hash and no longer scanned is gone: orphaned. An end recorded
  # without one (planned) and still not scanned is waiting: planned. Once a planned id is
  # scanned it differs from the recorded nil, so the relation dangles on that end until
  # someone confirms it, as with any other change.
  defp judge_tip(%Entry{ends: ends, basis: basis}, by_id) do
    looked = Enum.map(ends, &{{&1.kind, &1.id}, &1.hash, Map.get(by_id, {&1.kind, &1.id})})

    gone = for {key, hash, nil} <- looked, hash != nil, do: key
    waiting = for {key, nil, nil} <- looked, do: key

    cond do
      gone != [] ->
        {:orphaned, gone}

      waiting != [] ->
        {:planned, waiting}

      true ->
        changed = for {key, hash, scan} <- looked, scan.hash != hash, do: key

        cond do
          # A claim nothing has validated (§18): it fails like a dangling relation until
          # evidence or a review validates it.
          basis == :proposed -> {:proposed, changed}
          changed == [] -> {:current, []}
          true -> {:dangling, changed}
        end
    end
  end

  # A current implements or verifies relation whose tip has no validating basis (§18): one
  # recorded before validation existed, or by hand. Reported; failing under `validated:`.
  # Current relations nothing validates now (§18): no validating basis, or a `baseline`
  # that no longer holds (§18.1). A baselined verifies holds while its test's version is
  # baselined; a baselined implements, while a baselined test verifies the unit (or a unit
  # inside it) and exercises the code.
  defp unvalidated(relations, baselined, scans) do
    within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}
    current = for %{state: :current, tip: %Entry{} = tip} = r <- relations, do: {r, tip}
    pairs = fn type -> for {%{type: ^type, relation: {_, a, b}}, _} <- current, do: {a, b} end
    tests = MapSet.new(pairs.(:tests))
    trusted = MapSet.new(baselined, fn {t, _hash} -> t end)

    # Each spec unit => the baselined tests that verify it or a unit inside it, each
    # verifies unit's `within` chain walked once (§13).
    trusted_verifying =
      for {{:test, t}, {:spec, unit}} <- pairs.(:verifies),
          MapSet.member?(trusted, t),
          reduce: %{} do
        acc -> Map.update(acc, unit, MapSet.new([t]), &MapSet.put(&1, t))
      end
      |> verifying(within)

    holds? = fn
      %{relation: {:verifies, {:test, t}, _}}, tip ->
        MapSet.member?(baselined, {t, Enum.find(tip.ends, &(&1.kind == :test)).hash})

      %{relation: {:implements, {:code, c}, {:spec, s}}}, _tip ->
        trusted_verifying
        |> Map.get(s, MapSet.new())
        |> Enum.any?(&MapSet.member?(tests, {{:test, &1}, {:code, c}}))
    end

    shapes = for %Scan{kind: :code, shape: true, id: id} <- scans, into: MapSet.new(), do: id

    validating? = fn r, tip ->
      case {r.relation, tip.basis} do
        # Code with behaviour is shown by a run, never judged: only a shape is (§18).
        {{:implements, {:code, c}, _spec}, :judgement} -> MapSet.member?(shapes, c)
        {_relation, basis} when basis in [:evidence, :review, :judgement] -> true
        {_relation, :baseline} -> holds?.(r, tip)
        _none_or_proposed -> false
      end
    end

    for {%{type: type, relation: relation} = r, tip} <- current,
        type in [:implements, :verifies],
        not validating?.(r, tip),
        do: %{relation: relation}
  end

  @doc """
  Whether a relation is validated now (§18): current, on a validating basis, and not
  unvalidated (a `baseline` that still holds, §18.1).
  """
  @spec validated?(t, map) :: boolean
  def validated?(status, %{state: :current, tip: %Entry{} = tip, relation: relation}),
    do:
      tip.basis in [:evidence, :review, :judgement, :baseline] and
        not Enum.any?(status.unvalidated, &(&1.relation == relation))

  def validated?(_status, _relation), do: false

  @doc "How many current relations rest on the baseline (§18.1)."
  @spec baseline_count(t) :: non_neg_integer
  def baseline_count(status),
    do: Enum.count(status.relations, &match?(%{state: :current, tip: %{basis: :baseline}}, &1))

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

  # The spec/test/code triangle, for each spec unit that something implements: a test
  # should verify it (or a block or hint inside it), and that test should exercise the code
  # that implements it. Only when tests are scanned at all; otherwise every unit would
  # report no test for a project that doesn't scan them.
  defp triangle(scans, relations) do
    if Enum.any?(scans, &(&1.kind == :test)) do
      live = Enum.reject(relations, &(&1.state == :retired))
      implements = pairs(live, :implements, fn {{:code, c}, {:spec, s}} -> {s, c} end)
      verifies = pairs(live, :verifies, fn {{:test, t}, {:spec, s}} -> {s, t} end)
      # Code is compared by its definition, so a test calling `f/1` exercises the `f/2`
      # that a spec unit names, when both are one function with a default argument.
      definition = definitions(scans)
      recorded = pairs(live, :tests, fn {{:test, t}, {:code, c}} -> {t, definition.(c)} end)

      # What a test reaches is a fact of the source (§11, §13.1): the scanned code it calls,
      # and what that code calls, transitively. It counts whether or not a `tests` relation
      # records it, so a project that doesn't record them sees no false gaps; code not
      # written yet is reached by nothing.
      reached =
        for {t, ids} <- Scan.reach(scans), into: %{}, do: {t, MapSet.new(ids, definition)}

      exercises = Map.merge(reached, recorded, fn _test, a, b -> MapSet.union(a, b) end)
      within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}

      verifying = verifying(verifies, within)

      for {spec, codes} <- Enum.sort(implements),
          tests = Map.get(verifying, spec, MapSet.new()),
          gap <- gaps(spec, codes, tests, exercises, definition),
          do: gap
    else
      []
    end
  end

  defp pairs(relations, type, fun) do
    for %{type: ^type, relation: {_, a, b}} <- relations, reduce: %{} do
      acc ->
        {key, value} = fun.({a, b})
        Map.update(acc, key, MapSet.new([value]), &MapSet.put(&1, value))
    end
  end

  # Each spec unit => the tests that verify it, or any unit inside it. Each verifies unit's
  # `within` chain is walked once, so a unit's verifying tests are a lookup, not a walk of
  # every verifies unit's chain per spec unit (§13).
  defp verifying(verifies, within) do
    for {unit, tests} <- verifies, enclosing <- enclosing(unit, within), reduce: %{} do
      acc -> Map.update(acc, enclosing, tests, &MapSet.union(&1, tests))
    end
  end

  # `unit` and every unit it sits inside, innermost first: what `inside?/3` is true of.
  defp enclosing(unit, within), do: enclosing(unit, within, [])

  defp enclosing(unit, within, seen) do
    # A cycle can't come from a scanner, but must end the walk rather than loop.
    if unit in seen do
      Enum.reverse(seen)
    else
      case Map.fetch(within, unit) do
        {:ok, parent} -> enclosing(parent, within, [unit | seen])
        :error -> Enum.reverse([unit | seen])
      end
    end
  end

  defp inside?(spec, spec, _within), do: true

  defp inside?(unit, spec, within) do
    case Map.fetch(within, unit) do
      {:ok, parent} -> inside?(parent, spec, within)
      :error -> false
    end
  end

  # code id => its definition (`Surfex.Scan.definition/1`); an id no longer scanned is its
  # own.
  defp definitions(scans) do
    by_id = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, Scan.definition(s)}
    fn id -> Map.get(by_id, id, {:code, id}) end
  end

  defp gaps(spec, codes, tests, exercises, definition) do
    if MapSet.size(tests) == 0,
      do: [%{spec: spec, gap: :no_test, test: nil, code: nil}],
      else: sides(spec, codes, tests, exercises, definition)
  end

  defp sides(spec, codes, tests, exercises, definition) do
    reached = fn test -> Map.get(exercises, test, MapSet.new()) end
    implemented = MapSet.new(codes, definition)

    misses =
      for test <- Enum.sort(tests),
          MapSet.disjoint?(reached.(test), implemented),
          do: %{spec: spec, gap: :test_misses_code, test: test, code: nil}

    untested =
      for code <- Enum.sort(codes),
          not Enum.any?(tests, &MapSet.member?(reached.(&1), definition.(code))),
          do: %{spec: spec, gap: :code_untested, test: nil, code: code}

    misses ++ untested
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

    # Code is one item per definition to the policy, as it is to the triangle: a
    # function's default-argument arities share one, so a relation to either meets the
    # rule for both (#146).
    by_definition =
      for %Scan{kind: :code} = scan <- scans,
          types = Map.get(live, {:code, scan.id}),
          types != nil,
          reduce: %{} do
        acc -> Map.update(acc, Scan.definition(scan), types, &MapSet.union(&1, types))
      end

    met = fn
      %Scan{kind: :code} = scan -> Map.get(by_definition, Scan.definition(scan), MapSet.new())
      scan -> Map.get(live, {scan.kind, scan.id}, MapSet.new())
    end

    # A kind's rule applies to every scan of that kind; a spec role's rule (`test_hint:`)
    # to every spec unit in that role. Each rule that isn't met is its own entry.
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        key <- Enum.uniq([scan.kind, scan.role]),
        key != nil,
        requires = Keyword.get(require, key, []),
        requires != [],
        not Enum.any?(requires, &MapSet.member?(met.(scan), &1)),
        do: %{scan: scan, requires: requires}
  end

  # A declaration in a test (`@tag verifies: "id"`) that names no spec unit, or a bare id
  # that more than one file has.
  # A live excuse whose item its class no longer covers: the item is now implemented, no
  # rule of any class matches it, or another class's rule matches it first. Judged by
  # `Surfex.Coverage.verdict/3`, as the suggestion was, with a parent counting as cited when
  # something implements it.
  defp stale(_scans, _relations, nil), do: []

  defp stale(scans, relations, coverage) do
    code = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}

    implemented =
      for %{type: :implements, state: state, relation: {_, {:code, id}, _}} <- relations,
          state != :retired,
          into: MapSet.new(),
          do: id

    for %{type: :excuses, state: state, relation: {_, {:class, class}, {:code, id}}} <- relations,
        state != :retired,
        scan = Map.get(code, id),
        scan != nil,
        verdict = Surfex.Coverage.verdict(item(scan), implemented, coverage),
        verdict != {:expected, class},
        do: %{class: class, code: id, reason: stale_reason(verdict)}
  end

  defp item(%Scan{id: id, role: kind, within: parent, location: %{file: file}, hash: hash}) do
    key = String.replace_suffix(id, " (#{kind})", "")
    name = if parent, do: String.replace_prefix(key, parent <> ".", ""), else: key
    %Surfex.Item{kind: kind, name: name, parent: parent, file: file, hash: hash}
  end

  defp stale_reason(:cited), do: :implemented
  defp stale_reason(:gap), do: :unmatched
  defp stale_reason({:expected, other}), do: {:other_class, other}

  # Two records with one kind and id would be one relation end: a relation would silently
  # be judged against whichever came last. A scanner must never produce them.
  defp unique!(scans) do
    scans
    |> Enum.group_by(&{&1.kind, &1.id})
    |> Enum.find(fn {_key, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {{kind, id}, group} ->
        where = Enum.map_join(group, ", ", &"#{&1.location.file}:#{inspect(&1.location.lines)}")
        raise ArgumentError, "two #{kind} records have the id #{inspect(id)} (#{where})"
    end
  end

  # Why a claim isn't borne out, strongest first (§17).
  @reasons [:failed, :other_code, :not_run, :excluded, :skipped]

  # The evidence given to derive, each run reduced to its latest records
  # (`latest_records/1`), which the checks below look tests up in; nil when none was given.
  defp latest_runs(nil), do: nil
  defp latest_runs({:merged, runs}), do: {:merged, Enum.map(runs, &latest_records/1)}
  defp latest_runs(run), do: latest_records(run)

  # Every current relation with a test end (`verifies`, `tests`) whose test failed at the
  # version the relation holds, whatever its basis (§17): a review judged that the test
  # covers the claim, and relied on the run to say whether it passes. With several jobs'
  # runs, a failure in any of them. Excluded, skipped and unrun tests aren't failures.
  defp failed(_relations, nil), do: []

  defp failed(relations, runs) do
    for %{
          state: :current,
          type: type,
          relation: {_, {:test, t}, _} = relation,
          tip: %Entry{} = tip
        } <-
          relations,
        type in [:verifies, :tests],
        test_hash = hash_of(tip, :test, t),
        test_hash != nil,
        failed?(runs, t, test_hash),
        do: %{relation: relation, test: t}
  end

  defp failed?({:merged, runs}, test, hash), do: Enum.any?(runs, &failed?(&1, test, hash))
  defp failed?(latest, test, hash), do: match?(%{result: :failed}, latest[{test, hash}])

  # A current relation confirmed by evidence (`Surfex.Evidence.claimed?/1`) whose claim the
  # given evidence (this run's) doesn't bear out: its test, at the version the relation
  # holds, must have passed against the code's version. For `implements`, some test with
  # a current `verifies` to the spec unit (or inside it) that has a current `tests` to the
  # code, or reaches it (§13.1), must. `nil` evidence means no check; `{:merged, runs}` is
  # several CI jobs' runs (§17).
  #
  # It grows with the project in proportion (§17): what each claim looks up, its candidate
  # tests and each test's latest record, is indexed once here, not scanned per claim.
  defp unproven(_scans, _relations, nil), do: []

  defp unproven(scans, relations, runs) do
    definition = definitions(scans)
    within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}
    current = for %{state: :current, tip: %Entry{} = tip} = r <- relations, do: {r, tip}
    pairs = fn type -> for {%{type: ^type, relation: {_, a, b}}, _} <- current, do: {a, b} end
    reached = for {t, ids} <- Scan.reach(scans), id <- ids, do: {{:test, t}, {:code, id}}

    # A code definition => the tests that test or reach it.
    testing =
      Enum.reduce(pairs.(:tests) ++ reached, %{}, fn {{:test, t}, {:code, c}}, acc ->
        Map.update(acc, definition.(c), MapSet.new([t]), &MapSet.put(&1, t))
      end)

    # A test => the spec units it verifies, each with its place among the verifies pairs,
    # which orders the candidates as the pairs do.
    verifying =
      pairs.(:verifies)
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{{:test, t}, {:spec, unit}}, place}, acc ->
        Map.update(acc, t, [{place, unit}], &[{place, unit} | &1])
      end)

    index = {testing, verifying, within, definition}

    for {%{relation: relation} = r, tip} <- current,
        Surfex.Evidence.claimed?(tip),
        judge = claim_judge(r, tip, index),
        failure = against(runs, judge),
        failure != nil,
        do: Map.put(failure, :relation, relation)
  end

  # A run's latest record of each test, and of each test at each version: what `passes/5`
  # reads, so a claim looks its test up instead of scanning the run.
  defp latest_records(run) do
    Enum.reduce(run, %{}, fn %{test: t, test_hash: h} = record, acc ->
      acc |> Map.put({t, nil}, record) |> Map.put({t, h}, record)
    end)
  end

  # A claim's verdict on one run (`against/2`). The candidate tests of an `implements`
  # depend on the log and the scans, not the run, so they're found once per claim.
  defp claim_judge(
         %{type: :tests, relation: {_, {:test, t}, {:code, c}}},
         tip,
         {_, _, _, definition}
       ) do
    test_hash = hash_of(tip, :test, t)
    code_hash = hash_of(tip, :code, c)
    fn latest -> passes(latest, t, test_hash, c, code_hash, definition) end
  end

  defp claim_judge(
         %{type: :implements, relation: {_, {:code, c}, {:spec, s}}},
         tip,
         {testing, verifying, within, definition}
       ) do
    code_hash = hash_of(tip, :code, c)

    candidates =
      for t <- Map.get(testing, definition.(c), []),
          places = for({place, unit} <- verifying[t] || [], inside?(unit, s, within), do: place),
          places != [] do
        {Enum.min(places), t}
      end
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    fn latest ->
      if candidates == [] do
        %{test: nil, reason: :no_verifying_test}
      else
        failures =
          for t <- candidates, f = passes(latest, t, nil, c, code_hash, definition), do: f

        # Every candidate failed to bear it out: the strongest reason wins, so an exclusion
        # never hides a disproof or a test that didn't run.
        if length(failures) == length(candidates),
          do: Enum.min_by(failures, &Enum.find_index(@reasons, fn r -> r == &1.reason end)),
          else: nil
      end
    end
  end

  defp claim_judge(_other, _tip, _index), do: fn _latest -> nil end

  # One run's verdict on a claim; or, for several jobs' runs merged (§17), a disproof in
  # any run, else borne out by any, else no job ran it.
  defp against({:merged, runs}, judge) do
    verdicts = Enum.map(runs, judge)

    cond do
      disproof = Enum.find(verdicts, &match?(%{reason: r} when r in [:failed, :other_code], &1)) ->
        disproof

      structural = Enum.find(verdicts, &match?(%{reason: :no_verifying_test}, &1)) ->
        structural

      runs != [] and Enum.any?(verdicts, &is_nil/1) ->
        nil

      true ->
        %{test: Enum.find_value(verdicts, & &1[:test]), reason: :no_job}
    end
  end

  defp against(run, judge), do: judge.(run)

  # nil when the run's latest record of `test` (at `test_hash`, or at any version when nil;
  # `latest_records/1`) passed against the code (any id of its definition) at `code_hash`;
  # otherwise why not.
  defp passes(latest_records, test, test_hash, code, code_hash, definition) do
    latest = Map.get(latest_records, {test, test_hash})

    cond do
      latest == nil ->
        %{test: test, reason: :not_run}

      # Left out of this run on purpose: not checked here, not disproved (§17).
      latest.result in [:excluded, :skipped] ->
        %{test: test, reason: latest.result}

      latest.result != :passed ->
        %{test: test, reason: :failed}

      not Enum.any?(latest.code, fn {id, h} ->
        h == code_hash and definition.(id) == definition.(code)
      end) ->
        %{test: test, reason: :other_code}

      true ->
        nil
    end
  end

  defp hash_of(%{ends: ends}, kind, id),
    do: Enum.find_value(ends, fn e -> if e.kind == kind and e.id == id, do: e.hash end)

  # A live verifies relation whose test no longer declares its spec unit: the claim was
  # removed from the test's source, but the relation still asserts it. A tag is not part of
  # a test's version, so without this the relation would stay current.
  defp undeclared(scans, relations, resolver) do
    tests = for %Scan{kind: :test} = s <- scans, into: %{}, do: {s.id, s}

    for %{type: :verifies, state: state, relation: {_, {:test, t}, {:spec, unit}}} <- relations,
        state != :retired,
        test = Map.get(tests, t),
        test != nil,
        unit not in declared(resolver, test),
        do: %{test: t, spec: unit}
  end

  @doc false
  # The spec units a test declares it verifies, resolved against the scans or a resolver
  # built from them (`Surfex.Scan.resolve/2`).
  def declared(scans_or_resolver, %Scan{declares: declares}) do
    for {:verifies, ref} <- declares,
        {:ok, unit} <- [Scan.resolve(scans_or_resolver, ref)],
        do: unit.id
  end

  defp broken(scans, resolver) do
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        {type, ref} <- scan.declares,
        {:error, why} <- [Scan.resolve(resolver, ref)],
        do: %{scan: scan, type: type, ref: ref, reason: why}
  end
end
