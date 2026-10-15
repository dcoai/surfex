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
  changed) is **undeclared**: a claim the source no longer makes. The other direction, a
  test's declaration resolving to a spec unit with no `verifies` relation between them in
  the log, is **unrecorded**: a claim the log doesn't hold. A declaration whose relation
  was retired is unrecorded too, listed as retired with the retire's note.

  A `refines` relation is a fact read from source: the unit sits in (`within`) the unit it
  refines. One whose unit no longer sits there, as when a marked block is moved unchanged
  into another section, is **moved**, naming where the unit sits now. Neither end's version
  changes on such a move, so without this the relation would stay current. A unit that
  sits in nothing (a section) states no such fact, so a `refines` from one isn't checked.

  A `verifies` tag that applies to no test or property block (a trailing `@tag`, a
  `@moduletag` on a module with no test, any tag in `test/support`) is **inert**: given as
  `inert:` (`Surfex.Scan.ExUnit.inert/2`), listed so a misplaced tag is visible, never a
  failure.

  A contract stated in several spec files whose statements differ (§13.10) is
  **restated**: the same function, of the same kind, at more than one version. Listed so
  the drift is visible, never a failure.

  Each declared dispatch function (`dispatch:`, §11.10) is listed under **dispatch** with
  what its table lists: the functions a call to it reaches, the literal entries naming no
  scanned function, and whether it is **unresolved** (its module lists no literal target,
  so a call to it reaches nothing beyond it). Information, never a failure.

  Each `not_claims:` pattern (§13.12), given as `not_claims:` (each pattern's `inspect/1`
  form, in order), is listed under **not_claims** with the lines of own text it matched
  and the units they sit in, a pattern matching nothing with `0`, so a pattern that starts
  swallowing prose shows. A pattern the scans record but the option doesn't name is listed
  too. Information, never a failure.

  A test that `mix test --only verifies:id` can't select by some of the ids it declares (a
  list tag of several, §11) is **unselectable**, with those ids. A list is legitimate, so
  this is information, never a failure.

  A spec unit a test declares with `@tag deviation: "<ref>"` (§11) is **deviating**: the
  spec is right, the code doesn't meet it yet, and the reference names what will fix it.
  Its test is red, and skipped to keep the suite green. Each is listed with its test and
  reference, and, given evidence, the test's last result there. The deviation **holds
  back** the unit and each unit it sits in (`held`, §13.11; under `claim_grain: true` the
  sections it sits under too). A proposed relation to a held unit is marked `deviates`
  (its references) and doesn't fail: it is reported, as a planned one is. A deviation
  test that failed is listed with its deviation, not as failed. One that **passed**, at
  its version, is a stale deviation and fails: the code meets the unit now, so the tag
  comes off and the relations are validated. A skipped test never passed, so without a
  run that includes it nothing is judged stale. A deviation tag on a test that declares no
  spec unit is broken.

  A test version that, in the evidence given, failed and then passed against the same
  code versions, and never discriminated, is **uncredited** (§17): its red→green can't be
  credited, since what changed is outside the code it reaches (a call the scanner doesn't
  see, a change outside the scanned code, or a flaky test). Each is listed with the code
  it reached, as information, never a failure.

  An `excuses` relation whose item its class no longer covers is **stale**: the item is
  now implemented, no rule matches it any more, or another class's rule matches it first.
  An excuse must stay true to its class's rules, not only to the versions it was confirmed
  at. Judging it needs the rules, given as `coverage:` (`Surfex.Profile.coverage!/1`).

  **Failing** means any dangling, orphaned or conflicted relation, any unmet id, any
  undeclared `verifies` relation, any moved `refines` relation, any unrecorded or broken
  declaration, any stale excuse or deviation, any contradicted relation to a classed spec
  unit (§13.6), or any broken citation. Planned relations fail too when derived with
  `planned: :fail` (`mix surfex.status --no-planned`), for a check that everything planned
  has been built, such as a release's, and deviations with `deviations: :fail`
  (`mix surfex.status --no-deviations`).

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
          deviates: [String.t()],
          migrates: String.t() | nil,
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
          unmet: [%{scan: Scan.t(), requires: [atom], why: nil | :contained | :unearned}],
          broken: [%{scan: Scan.t(), type: atom, ref: String.t(), reason: term}],
          triangle: [gap],
          unvalidated: [%{relation: tuple}],
          undeclared: [%{test: String.t(), spec: String.t()}],
          unrecorded: [
            %{test: String.t(), spec: String.t(), retired: nil | %{note: String.t() | nil}}
          ],
          moved: [%{from: String.t(), to: String.t(), now: String.t()}],
          migrating: [
            %{code: String.t(), section: String.t(), claims: [String.t()], settled: boolean}
          ],
          unselectable: [%{test: String.t(), ids: [String.t()]}],
          deviating: [
            %{
              spec: String.t(),
              test: String.t(),
              ref: String.t(),
              run: nil | :passed | :failed | :excluded | :skipped
            }
          ],
          failed: [%{relation: tuple, test: String.t()}],
          unproven: [%{relation: tuple, test: String.t() | nil, reason: atom}],
          uncredited: [%{test: String.t(), code: [String.t()]}],
          unchecked: [%{relation: tuple, test: String.t(), reason: :excluded | :skipped}],
          citations: [Surfex.Cite.t()],
          inert: [Surfex.Scan.ExUnit.inert()],
          restated: [Surfex.Status.Restated.t()],
          dispatch: [
            %{
              dispatcher: String.t(),
              targets: [String.t()],
              unscanned: [String.t()],
              unresolved: boolean
            }
          ],
          not_claims: [%{pattern: String.t(), lines: non_neg_integer, units: non_neg_integer}],
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
            baseline: :allow | :fail,
            deviations: :allow | :fail,
            claim_grain: boolean,
            unearned: :report | :fail
          },
          unimplemented: [Scan.t()],
          verdicts: %{String.t() => Surfex.Status.Verdict.verdict()},
          contained: [%{unit: String.t(), inside: [String.t()], location: map}],
          on_container: [%{test: String.t(), unit: String.t(), inside: [String.t()]}],
          containers: [%{unit: String.t(), claims: non_neg_integer, verified: non_neg_integer}],
          earning: %{
            inside: %{String.t() => [String.t()]},
            own: %{String.t() => MapSet.t(String.t())},
            exercises: %{String.t() => MapSet.t(term)},
            through: MapSet.t(tuple),
            held: %{String.t() => [String.t()]}
          },
          held: %{String.t() => [String.t()]},
          unearned: [
            %{
              code: String.t(),
              unit: String.t(),
              why: :unverified | :not_exercised | :nothing_inside | :deviates
            }
          ],
          excused: [
            %{
              unit: String.t(),
              name: String.t(),
              reason: String.t(),
              note: String.t() | nil,
              by: :marker | :pattern | :alias,
              claims: [String.t()],
              location: map
            }
          ],
          deferred: [
            %{
              unit: String.t(),
              ref: String.t(),
              reason: String.t() | nil,
              location: map,
              issue: Surfex.Issues.state() | nil
            }
          ],
          stale_deferrals: [
            %{unit: String.t(), ref: String.t(), reason: :built | :closed | :unresolved}
          ],
          contradicted: [
            %{type: :verifies | :implements | :declares, from: String.t(), unit: String.t()}
          ],
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

    deviations_policy = Keyword.get(opts, :deviations, :allow)

    unless deviations_policy in [:allow, :fail],
      do:
        raise(
          ArgumentError,
          "deviations: must be :allow or :fail, got #{inspect(deviations_policy)}"
        )

    claim_grain = Keyword.get(opts, :claim_grain, false)

    unless is_boolean(claim_grain),
      do: raise(ArgumentError, "claim_grain: must be true or false, got #{inspect(claim_grain)}")

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

    runs = latest_runs(Keyword.get(opts, :evidence))
    deviating = deviating(scans, resolver, runs)
    held = held(deviating, scans, claim_grain)

    relations = relations |> impacted() |> deviates(held) |> open_migrations()

    # A deviation test that fails is the state it declares: listed with its deviation, not
    # as failed (§13.1). Any other test's failure fails its relations.
    deviation_tests = MapSet.new(deviating, & &1.test)
    all_failed = failed(relations, runs, by_id)
    failed_relations = MapSet.new(all_failed, & &1.relation)
    failed = Enum.reject(all_failed, &MapSet.member?(deviation_tests, &1.test))

    # A claim this run left its test out of is not checked here, not disproved (§17). One
    # whose test failed is reported once, as failed, whatever its basis.
    {unchecked, unproven} =
      scans
      |> unproven(relations, runs)
      |> Enum.reject(&MapSet.member?(failed_relations, &1.relation))
      |> Enum.split_with(&(&1.reason in [:excluded, :skipped]))

    related =
      for r <- relations, {_type, a, b} = r.relation, end_ <- [a, b], into: MapSet.new(), do: end_

    discriminated =
      MapSet.new(
        for %Entry{op: :observe, type: :red_green, ends: [test]} <- other_entries,
            do: {test.id, test.hash}
      )

    # What verified means for each spec unit (§13.4), from one index of the units' `within`
    # chains: no credit moves up, none into a unit's own text.
    # A spec class or deferral (§11.7) is read under claim_grain: true (§13.6): the
    # classed unit's own text is excused, or deferred, rather than judged.
    classed = if claim_grain, do: classed(scans), else: %{}

    # The states of the issues the deferrals name, when the caller asked (§13.7): an
    # input, like evidence, never read here.
    issues = Keyword.get(opts, :issues)

    unless issues == nil or is_map(issues),
      do:
        raise(
          ArgumentError,
          "issues: must be a map of reference => state, got #{inspect(issues)}"
        )

    verdict = Surfex.Status.Verdict.index(scans, relations, &label/1, classed)

    # What each test and check exercises, by definition, built once for the triangle and
    # for earning (§13.1, §13.5).
    exercises = exercises(scans, relations)

    earning = %{
      inside: verdict.inside,
      own: verdict.own,
      exercises: exercises,
      through: through_reviewed(relations),
      # Under claim_grain: a unit a deviation holds back doesn't earn (§13.11).
      held: if(claim_grain, do: held, else: %{})
    }

    # Under claim_grain: true an implements counts only when it earns (§13.9): the ones
    # that don't are listed, and fail where `require: code:` asks for an implements.
    unearned =
      if claim_grain,
        do: unearned(%{earning: earning, verdicts: verdict.verdicts, scans: by_id}, relations),
        else: []

    status = %{
      relations: relations,
      verdicts: verdict.verdicts,
      # Information, not a failure (§13.4): a claim green only through a claim inside it,
      # and a verifies aimed at a unit with no text of its own.
      contained: verdict.contained,
      on_container: verdict.on_container,
      containers: verdict.containers,
      # What `earning/2` reads (§13.5): the claims inside each unit, each claim's own
      # verifiers, what each verifier exercises, and the relations reviewed through a
      # named path.
      earning: earning,
      # Each spec unit a deviation holds back, with its references (§13.11): what marks a
      # relation `deviates`, and what `mix surfex.confirm --evidence` doesn't validate.
      held: held,
      unearned: unearned,
      # Listed with or without claim_grain: (§13.6): what the source classes and defers.
      excused: excused(scans, verdict.inside),
      deferred: deferred(scans, issues),
      stale_deferrals: if(claim_grain, do: stale_deferrals(scans, verdict.own, issues), else: []),
      contradicted:
        if(claim_grain, do: contradicted(scans, relations, verdict.verdicts), else: []),
      new:
        scans
        |> Enum.reject(&MapSet.member?(related, {&1.kind, &1.id}))
        |> Enum.sort_by(&{&1.kind, &1.id}),
      unmet: unmet(scans, relations, require, verdict.verdicts, unearned),
      broken: broken(scans, resolver),
      deviating: deviating,
      undeclared: undeclared(scans, relations, resolver),
      unrecorded: unrecorded(scans, relations, resolver),
      moved: moved(relations, by_id),
      # Information, not a failure: a list of several ids is legitimate (§13.1).
      unselectable:
        for(
          %Scan{kind: :test, unselectable: [_ | _] = ids} = t <- scans,
          do: %{test: t.id, ids: ids}
        )
        |> Enum.sort_by(& &1.test),
      citations: Keyword.get(opts, :citations, []),
      # Information, not a failure (§11.5): a tag that verifies nothing, made visible.
      inert: Keyword.get(opts, :inert, []),
      # Information, not a failure (§13.10): one contract, stated differently in two files.
      restated: Surfex.Status.Restated.of(scans),
      # Information, not a failure (§11.10): what each declared dispatcher's table lists.
      dispatch: dispatch(scans),
      # Information, not a failure (§13.12): what each not_claims: pattern left out.
      not_claims: not_claims(scans, Keyword.get(opts, :not_claims, [])),
      stale: stale(scans, relations, Keyword.get(opts, :coverage)),
      failed: failed,
      unproven: unproven,
      unchecked: unchecked,
      triangle: triangle(scans, relations, exercises, verdict.verdicts),
      unvalidated: unvalidated(relations, baselined, scans),
      baselined: baselined,
      adoption: adoption.setting,
      marks: marks(mark_entries, by_id),
      discriminated: discriminated,
      # Information, not a failure (§17): a gap in what the test's calls reach.
      uncredited: uncredited(scans, Keyword.get(opts, :evidence), discriminated),
      policy: %{
        triangle: triangle,
        validated: validated,
        marks: marks_policy,
        baseline: baseline_policy,
        deviations: deviations_policy,
        claim_grain: claim_grain,
        unearned:
          if(claim_grain and :implements in Keyword.get(require, :code, []),
            do: :fail,
            else: :report
          )
      },
      unimplemented: unimplemented(scans, relations),
      planned: planned,
      scans: by_id
    }

    Map.put(status, :migrating, migrating(status))
  end

  # A claim relation a migration recorded (§14.1) migrates while its section relation holds:
  # the section keeps its relation until the claim's is validated, so `migrates` is kept
  # only while the relation from the same code to that section is live.
  defp open_migrations(relations) do
    live =
      for %{state: state, relation: relation} <- relations,
          state not in [:retired, :orphaned],
          into: MapSet.new(),
          do: relation

    Enum.map(relations, fn
      %{migrates: nil} = r ->
        r

      %{relation: {:implements, {:code, code}, _claim}, migrates: section, state: state} = r ->
        from = Entry.relation(:implements, %{kind: :code, id: code}, %{kind: :spec, id: section})

        if state in [:retired, :orphaned] or not MapSet.member?(live, from),
          do: %{r | migrates: nil},
          else: r
    end)
  end

  # Each code item moving from a section to its claims (§14.1), with whether every claim
  # relation is validated now: then the section relation is ready to retire.
  defp migrating(status) do
    status.relations
    |> Enum.filter(&(&1.migrates != nil))
    |> Enum.group_by(fn %{relation: {_, {:code, code}, _}, migrates: s} -> {code, s} end)
    |> Enum.map(fn {{code, section}, rs} ->
      %{
        code: code,
        section: section,
        claims:
          rs |> Enum.map(fn %{relation: {_, _, {:spec, claim}}} -> claim end) |> Enum.sort(),
        settled: Enum.all?(rs, &validated?(status, &1))
      }
    end)
    |> Enum.sort_by(&{&1.section, &1.code})
  end

  @doc """
  Whether the status fails the check: any dangling, orphaned, conflicted or unmet, and any
  planned relation when it was derived with `planned: :fail`, any open or orphaned mark
  with `marks: :fail`. A proposed relation that deviates doesn't fail, unless derived with
  `deviations: :fail`, which fails on any deviation; a stale deviation always fails.
  """
  @spec failing?(t) :: boolean
  def failing?(status) do
    failing = [:dangling, :orphaned, :conflicted, :proposed]
    failing = if status.planned == :fail, do: [:planned | failing], else: failing
    deviations_fail = status.policy.deviations == :fail

    # A proposed relation that deviates, or that a migration recorded while its section
    # still holds the relation (§14.1), doesn't fail.
    excused? = fn r ->
      r.state == :proposed and
        ((not deviations_fail and r.deviates != []) or r.migrates != nil)
    end

    status.unmet != [] or status.broken != [] or status.stale != [] or status.citations != [] or
      status.contradicted != [] or status.stale_deferrals != [] or
      (status.policy.unearned == :fail and status.unearned != []) or
      (status.policy.validated == true and status.unvalidated != []) or
      status.undeclared != [] or
      status.unrecorded != [] or
      status.moved != [] or
      status.failed != [] or
      status.unproven != [] or
      (status.policy.triangle == :fail and status.triangle != []) or
      (status.policy.marks == :fail and status.marks != []) or
      (status.policy.baseline == :fail and baseline_count(status) > 0) or
      (deviations_fail and status.deviating != []) or
      Enum.any?(status.deviating, &(&1.run == :passed)) or
      Enum.any?(status.relations, &(&1.state in failing and not excused?.(&1)))
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
  The verdict of the spec unit `unit` (§13.4): `:verified` (a claim with a current
  `verifies` of its own), `:contained` (a claim with none of its own, where a claim inside
  it is verified: its own text isn't), `:unverified` (no `verifies`, own or inside) or
  `:through_claims` (a container, a unit with no text of its own, whose claims answer for
  themselves). `nil` for an id no spec unit has.
  """
  @spec verdict(t, String.t()) :: Surfex.Status.Verdict.verdict() | nil
  def verdict(status, unit), do: Map.get(status.verdicts, unit)

  @doc """
  Whether the `implements` relation `relation` (a relation status, or its
  `{:implements, {:code, id}, {:spec, id}}`) earns (§13.5): `:earned`, or `{:unearned,
  why}`. It earns when its spec unit is `:verified`, or is a container or `:contained`
  and a verified claim inside it has a verifying test or check that exercises the code
  (by definition), or the relation is currently reviewed through a named path. `why` is
  `:unverified` (no evidence, own or inside), `:not_exercised` (a claim inside is
  verified, but none of its verifiers exercises the code) or `:nothing_inside` (a
  container with no claims). An excused or deferred unit (§13.6) has no evidence to earn
  through: `:unverified`. Under `claim_grain: true` a unit a deviation holds back (§13.11)
  is `{:unearned, :deviates}` before anything else is asked. The one definition of
  "earned".
  """
  @spec earning(t, relation_status | tuple) ::
          :earned | {:unearned, :unverified | :not_exercised | :nothing_inside | :deviates}
  def earning(status, %{relation: relation}), do: earning(status, relation)

  def earning(status, {:implements, {:code, _code}, {:spec, unit}} = relation) do
    # A deviation says the code doesn't meet the unit (§13.11): nothing else is asked.
    if Map.has_key?(status.earning.held, unit),
      do: {:unearned, :deviates},
      else: earning_by_evidence(status, relation)
  end

  defp earning_by_evidence(status, {:implements, {:code, code}, {:spec, unit}} = relation) do
    %{inside: inside, own: own, exercises: exercises, through: through} = status.earning
    claims = Map.get(inside, unit, [])
    verified = Enum.filter(claims, &(Map.get(status.verdicts, &1) == :verified))

    definition =
      case Map.fetch(status.scans, {:code, code}) do
        {:ok, scan} -> Scan.definition(scan)
        :error -> {:code, code}
      end

    exercised? = fn claim ->
      Enum.any?(Map.get(own, claim, []), fn verifier ->
        exercises |> Map.get(verifier, MapSet.new()) |> MapSet.member?(definition)
      end)
    end

    case Map.get(status.verdicts, unit) do
      :verified ->
        :earned

      # An excused or deferred unit has no evidence to earn through (§13.6).
      verdict when verdict in [nil, :unverified, :excused, :deferred] ->
        {:unearned, :unverified}

      _container_or_contained ->
        cond do
          claims == [] -> {:unearned, :nothing_inside}
          verified == [] -> {:unearned, :unverified}
          MapSet.member?(through, relation) -> :earned
          Enum.any?(verified, exercised?) -> :earned
          true -> {:unearned, :not_exercised}
        end
    end
  end

  @doc "Whether the `implements` relation earns (`earning/2`): `true` for `:earned`."
  @spec earned?(t, relation_status | tuple) :: boolean
  def earned?(status, relation), do: earning(status, relation) == :earned

  @doc """
  How many spec units were scanned, by role: sections, marked blocks, test hints, marked
  tables and their rows, rules and contracts.
  """
  @spec units(t) :: %{
          section: non_neg_integer,
          block: non_neg_integer,
          test_hint: non_neg_integer,
          table: non_neg_integer,
          row: non_neg_integer,
          rule: non_neg_integer,
          contract: non_neg_integer
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
      row: Map.get(counts, :row, 0),
      rule: Map.get(counts, :rule, 0),
      contract: Map.get(counts, :contract, 0)
    }
  end

  @doc """
  The marked tables' rows whose key looks like a list, a probable key naming two things
  (§11.2): a key holding `, `, ` / ` or ` and `, as `%{row, table, separator}`, in file and
  line order. A warning, never a failure: a key may hold a comma on purpose.
  """
  @spec list_keys(t) :: [%{row: Scan.t(), table: String.t(), separator: String.t()}]
  def list_keys(status) do
    for {_key, %Scan{kind: :spec, role: :row, within: table, id: id} = row} <- status.scans,
        key = String.replace_prefix(id, table <> "/", ""),
        separator = Enum.find([", ", " / ", " and "], &String.contains?(key, &1)),
        separator != nil do
      %{row: row, table: table, separator: separator}
    end
    |> Enum.sort_by(&{&1.row.location.file, &1.row.location.lines})
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
      deviates: [],
      migrates: migrates(type, group),
      tips: tips,
      tip: tip
    }
  end

  # The section a claim relation moves from: the latest of its entries that names one
  # (§14.1). Whether it still migrates is `open_migrations/1`'s to say.
  defp migrates(:implements, group) do
    case group |> Enum.filter(& &1.migrates) |> Enum.max_by(&{&1.at, &1.id}, fn -> nil end) do
      nil -> nil
      entry -> entry.migrates
    end
  end

  defp migrates(_type, _group), do: nil

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

  @doc """
  How many current relations rest on a review that named how its test exercises code no
  call reaches (`mix surfex.validate --through`, §18): a distinct kind of review, counted
  so an audit can find them.
  """
  @spec through_count(t) :: non_neg_integer
  def through_count(status),
    do:
      Enum.count(
        status.relations,
        &match?(%{state: :current, tip: %Entry{through: how}} when how != nil, &1)
      )

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

  # Each spec unit a deviation test declares (§13.1), with the test, its reference and,
  # given evidence, its latest result at its version there. Linear: each test's
  # declarations resolve against the derive's one resolver.
  defp deviating(scans, resolver, runs) do
    for %Scan{kind: :test, deviation: ref} = test <- scans,
        ref != nil,
        unit <- Enum.uniq(declared(resolver, test)) do
      %{spec: unit, test: test.id, ref: ref, run: run_of(runs, test.id, test.hash)}
    end
    |> Enum.sort_by(&{&1.spec, &1.test})
  end

  # A test's latest result at its version in the evidence, or nil when none was given or
  # it has no record. With several jobs' runs, a pass in any wins (the deviation is
  # stale), then a failure, then whatever a job recorded.
  defp run_of(nil, _test, _hash), do: nil

  defp run_of({:merged, runs}, test, hash) do
    results = for run <- runs, %{result: result} <- [run[{test, hash}]], do: result
    Enum.find([:passed, :failed], &(&1 in results)) || List.first(results)
  end

  defp run_of(latest, test, hash) do
    case latest[{test, hash}] do
      %{result: result} -> result
      nil -> nil
    end
  end

  # Each spec unit a deviation holds back (§13.11), with its references sorted: every
  # deviating unit and each unit it sits in, by `within` and, under claim_grain:, by
  # `under` too, so a section holding a deviating unit at any depth is held. Each deviating
  # unit's chain is walked once.
  defp held([], _scans, _claim_grain), do: %{}

  defp held(deviating, scans, claim_grain) do
    outer =
      for %Scan{kind: :spec} = s <- scans,
          o = s.within || if(claim_grain, do: s.under),
          o != nil,
          into: %{},
          do: {s.id, o}

    deviating
    |> Enum.reduce(%{}, fn d, acc ->
      Map.update(acc, d.spec, MapSet.new([d.ref]), &MapSet.put(&1, d.ref))
    end)
    |> verifying(outer)
    |> Map.new(fn {unit, refs} -> {unit, Enum.sort(refs)} end)
  end

  # Marks each proposed relation that deviates with the references (§13.1): a spec end of
  # it is a unit a deviation holds back (`held/3`). A deviation test's own verifies is to
  # its deviating unit. Other relations are left as they are.
  defp deviates(relations, held) when map_size(held) == 0, do: relations

  defp deviates(relations, held) do
    Enum.map(relations, fn
      %{state: :proposed, relation: {_type, a, b}} = r ->
        refs =
          for {:spec, unit} <- [a, b],
              ref <- Map.get(held, unit, []),
              uniq: true,
              do: ref

        %{r | deviates: Enum.sort(refs)}

      r ->
        r
    end)
  end

  # The spec/test/code triangle, for each spec unit that something implements: a test
  # should verify it (or a block or hint inside it), and that test should exercise the code
  # that implements it. Only when tests are scanned at all; otherwise every unit would
  # report no test for a project that doesn't scan them.
  defp triangle(scans, relations, exercises, verdicts) do
    if Enum.any?(scans, &(&1.kind in [:test, :check])) do
      live = Enum.reject(relations, &(&1.state == :retired))
      implements = pairs(live, :implements, fn {{:code, c}, {:spec, s}} -> {s, c} end)
      verifies = pairs(live, :verifies, fn {from, {:spec, s}} -> {s, label(from)} end)
      definition = definitions(scans)

      within = for %Scan{kind: :spec, within: w} = s <- scans, w != nil, into: %{}, do: {s.id, w}

      verifying = verifying(verifies, within)

      # A review that named how its test exercises code no call reaches (`--through`, §18)
      # stands for the path the source doesn't show: that code counts as exercised by the
      # unit's verifying tests while the review is current.
      through =
        for %{type: :implements, state: :current, tip: %Entry{through: how}} = r <- live,
            how != nil,
            {_, {:code, c}, {:spec, s}} = r.relation,
            reduce: %{},
            do: (acc ->
                   Map.update(
                     acc,
                     s,
                     MapSet.new([definition.(c)]),
                     &MapSet.put(&1, definition.(c))
                   ))

      # An excused or deferred unit isn't judged: a relation to one is contradicted, or
      # waits on its issue (§13.6).
      for {spec, codes} <- Enum.sort(implements),
          Map.get(verdicts, spec) not in [:excused, :deferred],
          tests = Map.get(verifying, spec, MapSet.new()),
          stated = Map.get(through, spec, MapSet.new()),
          exercised =
            Map.new(tests, &{&1, MapSet.union(Map.get(exercises, &1, MapSet.new()), stated)}),
          gap <- gaps(spec, codes, tests, exercised, definition),
          do: gap
    else
      []
    end
  end

  # Each test and check (by label) => the code it exercises, by definition (§13.1): code
  # is compared by its definition, so a test calling `f/1` exercises the `f/2` that a spec
  # unit names, when both are one function with a default argument. Empty when no test or
  # check is scanned.
  defp exercises(scans, relations) do
    if Enum.any?(scans, &(&1.kind in [:test, :check])) do
      live = Enum.reject(relations, &(&1.state == :retired))
      definition = definitions(scans)
      recorded = pairs(live, :tests, fn {{:test, t}, {:code, c}} -> {t, definition.(c)} end)

      # What a test reaches is a fact of the source (§11, §13.1): the scanned code it calls,
      # and what that code calls, transitively. It counts whether or not a `tests` relation
      # records it, so a project that doesn't record them sees no false gaps; code not
      # written yet is reached by nothing.
      reached =
        for {t, ids} <- Scan.reach(scans), into: %{}, do: {t, MapSet.new(ids, definition)}

      # A check exercises the code in the files it inspects (§11.4).
      files = Enum.group_by(for(%Scan{kind: :code} = s <- scans, do: s), & &1.location.file)

      inspected =
        for %Scan{kind: :check, id: id, check: %{inputs: inputs}} <- scans,
            into: %{},
            do:
              {label({:check, id}),
               MapSet.new(
                 for(f <- Map.keys(inputs), s <- Map.get(files, f, []), do: s.id),
                 definition
               )}

      reached
      |> Map.merge(recorded, fn _test, a, b -> MapSet.union(a, b) end)
      |> Map.merge(inspected)
    else
      %{}
    end
  end

  # Each declared dispatch function with its reading, from its module's record (§11.10).
  defp dispatch(scans) do
    for %Scan{kind: :code, dispatch: dispatch} <- scans,
        {id, %{targets: targets, unscanned: unscanned}} <- dispatch do
      %{
        dispatcher: id,
        targets: targets,
        unscanned: unscanned,
        unresolved: targets == [] and unscanned == []
      }
    end
    |> Enum.sort_by(& &1.dispatcher)
  end

  # Each not_claims: pattern with the own-text lines it matched and the units holding them
  # (§13.12): the configured ones in order, a pattern matching nothing with 0, then any
  # other the scans record, sorted.
  defp not_claims(scans, patterns) do
    counts =
      for %Scan{kind: :spec, not_claims: %{lines: lines}} <- scans,
          {pattern, n} <- lines,
          reduce: %{} do
        acc -> Map.update(acc, pattern, {n, 1}, fn {l, u} -> {l + n, u + 1} end)
      end

    order = Enum.uniq(patterns ++ (counts |> Map.keys() |> Enum.sort()))

    for pattern <- order do
      {lines, units} = Map.get(counts, pattern, {0, 0})
      %{pattern: pattern, lines: lines, units: units}
    end
  end

  # The implements relations a current review named a path for (`--through`, §18.2).
  defp through_reviewed(relations) do
    for %{type: :implements, state: :current, tip: %Entry{through: how}, relation: r} <-
          relations,
        how != nil,
        into: MapSet.new(),
        do: r
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

  # ── Classes and deferrals (§13.6) ───────────────────────────────────────

  # Each classed or deferred spec unit => how its own text is read.
  defp classed(scans) do
    for %Scan{kind: :spec} = s <- scans,
        s.class != nil or s.deferred != nil,
        into: %{},
        do: {s.id, if(s.deferred, do: :deferred, else: :excused)}
  end

  defp excused(scans, inside) do
    for %Scan{kind: :spec, class: %{} = class} = s <- Enum.sort_by(scans, & &1.id),
        do:
          Map.merge(class, %{unit: s.id, claims: Map.get(inside, s.id, []), location: s.location})
  end

  defp deferred(scans, issues) do
    for %Scan{kind: :spec, deferred: %{} = d} = s <- Enum.sort_by(scans, & &1.id),
        do: Map.merge(d, %{unit: s.id, location: s.location, issue: issue(issues, d.ref)})
  end

  defp issue(nil, _ref), do: nil
  defp issue(issues, ref), do: Map.get(issues, ref, :unresolved)

  # A deferral that no longer holds (§13.7): the unit has its own evidence now (`built`),
  # its issue is closed (`closed`), or, when the caller asked the tracker, the tracker
  # couldn't say (`unresolved`). Without issue states only `built` can be judged.
  defp stale_deferrals(scans, own, issues) do
    for %Scan{kind: :spec, deferred: %{ref: ref}} = s <- Enum.sort_by(scans, & &1.id),
        reason = stale_reason(Map.has_key?(own, s.id), issue(issues, ref)),
        reason != nil,
        do: %{unit: s.id, ref: ref, reason: reason}
  end

  defp stale_reason(true = _built, _issue), do: :built
  defp stale_reason(false, issue) when issue in [:closed, :unresolved], do: issue
  defp stale_reason(false, _open_or_unasked), do: nil

  # What says something checks or realises a classed unit's text, which its class says
  # asserts nothing (§13.6): a live verifies to a classed unit, a live implements to an
  # excused one (an implements to a classed unit with claims inside is a container's), and
  # a test's declaration naming a classed unit that no live verifies records yet.
  defp contradicted(scans, relations, verdicts) do
    classed = for %Scan{kind: :spec, class: %{}} = s <- scans, into: MapSet.new(), do: s.id
    live = Enum.reject(relations, &(&1.state == :retired))

    recorded =
      for %{type: type, relation: {_, from, {:spec, unit}}} <- live,
          (type == :verifies and MapSet.member?(classed, unit)) or
            (type == :implements and Map.get(verdicts, unit) == :excused),
          do: %{type: type, from: end_label(from), unit: unit}

    seen = MapSet.new(recorded, &{&1.from, &1.unit})
    resolver = Scan.resolver(scans)

    declared =
      for %Scan{kind: kind, declares: declares} = t <- scans,
          kind in [:test, :check],
          {:verifies, ref} <- declares,
          {:ok, %Scan{id: unit}} <- [Scan.resolve(resolver, ref)],
          MapSet.member?(classed, unit),
          not MapSet.member?(seen, {label({kind, t.id}), unit}),
          uniq: true,
          do: %{type: :declares, from: label({kind, t.id}), unit: unit}

    Enum.sort_by(recorded ++ declared, &{&1.unit, &1.type, &1.from})
  end

  defp end_label({:code, id}), do: id
  defp end_label(verifier), do: label(verifier)

  # ── Policy ──────────────────────────────────────────────────────────────

  defp unmet(scans, relations, require, verdicts, unearned) do
    # An unearned implements meets no rule (§13.9): it is listed, and the code is judged
    # by the relations it does earn.
    unearned_relations =
      MapSet.new(unearned, &{:implements, {:code, &1.code}, {:spec, &1.unit}})

    live =
      for %{state: state, type: type, relation: {_, a, b} = relation} <- relations,
          state != :retired,
          not MapSet.member?(unearned_relations, relation),
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

    # The definitions whose implements didn't earn: why their rule isn't met.
    code_scans = for %Scan{kind: :code} = s <- scans, into: %{}, do: {s.id, s}

    unearned_defs =
      for %{code: code} <- unearned,
          {:ok, scan} <- [Map.fetch(code_scans, code)],
          into: MapSet.new(),
          do: Scan.definition(scan)

    met = fn
      %Scan{kind: :code} = scan -> Map.get(by_definition, Scan.definition(scan), MapSet.new())
      scan -> Map.get(live, {scan.kind, scan.id}, MapSet.new())
    end

    # A kind's rule applies to every scan of that kind; a spec role's rule (`test_hint:`)
    # to every spec unit in that role. Each rule that isn't met is its own entry. A spec
    # rule judges claims only (§13.4): a container has no text of its own, and its claims
    # answer under their own roles. A contained claim a `verifies` rule fails says why.
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        claim?(scan, verdicts),
        key <- Enum.uniq([scan.kind, scan.role]),
        key != nil,
        requires = Keyword.get(require, key, []),
        requires != [],
        not Enum.any?(requires, &MapSet.member?(met.(scan), &1)),
        do: %{
          scan: scan,
          requires: requires,
          why: unmet_why(scan, requires, verdicts, unearned_defs)
        }
  end

  defp claim?(%Scan{kind: :spec, id: id}, verdicts),
    do: Map.get(verdicts, id) in [:verified, :contained, :unverified]

  defp claim?(_scan, _verdicts), do: true

  defp unmet_why(%Scan{kind: :spec, id: id}, requires, verdicts, _unearned_defs) do
    if :verifies in requires and Map.get(verdicts, id) == :contained, do: :contained
  end

  defp unmet_why(%Scan{kind: :code} = scan, requires, _verdicts, unearned_defs) do
    if :implements in requires and MapSet.member?(unearned_defs, Scan.definition(scan)),
      do: :unearned
  end

  defp unmet_why(_scan, _requires, _verdicts, _unearned_defs), do: nil

  # Every implements that doesn't earn (§13.9), in relation order, with why. A retired,
  # orphaned or planned relation is judged by its state, not by earning.
  defp unearned(status, relations) do
    for %{type: :implements, state: state, relation: {_, {:code, code}, {:spec, unit}} = r} <-
          relations,
        state not in [:retired, :orphaned, :planned],
        {:unearned, why} <- [earning(status, r)],
        do: %{code: code, unit: unit, why: why}
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

  # Each scanned test, at its version, whose red→green the evidence can't credit
  # (`Surfex.Evidence.uncredited/1`) and the log doesn't record as discriminated, with the
  # code versions its red run recorded. Several jobs' runs are read as one history.
  defp uncredited(_scans, nil, _discriminated), do: []

  defp uncredited(scans, {:merged, runs}, discriminated),
    do: uncredited(scans, Surfex.Evidence.combined(runs), discriminated)

  defp uncredited(scans, evidence, discriminated) do
    pairs = Surfex.Evidence.uncredited(evidence)

    for %Scan{kind: :test, id: id, hash: hash} <- scans,
        not MapSet.member?(discriminated, {id, hash}),
        {:ok, {red, _green}} <- [Map.fetch(pairs, {id, hash})] do
      %{test: id, code: red.code |> Map.keys() |> Enum.sort()}
    end
    |> Enum.sort_by(& &1.test)
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
  defp failed(_relations, nil, _by_id), do: []

  defp failed(relations, runs, by_id) do
    tests =
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

    # A check failed at the version the relation holds: its declaration's run, against
    # the inputs that make that version (§17.1).
    checks =
      for %{state: :current, relation: {:verifies, {:check, c}, _} = relation, tip: tip} <-
            relations,
          %Scan{check: %{declaration: declaration}} <- [Map.get(by_id, {:check, c})],
          version = hash_of(tip, :check, c),
          check_failed?(runs, c, declaration, version),
          do: %{relation: relation, test: c}

    Enum.sort_by(tests ++ checks, & &1.relation)
  end

  defp failed?({:merged, runs}, test, hash), do: Enum.any?(runs, &failed?(&1, test, hash))
  defp failed?(latest, test, hash), do: match?(%{result: :failed}, latest[{test, hash}])

  defp check_failed?({:merged, runs}, check, declaration, version),
    do: Enum.any?(runs, &check_failed?(&1, check, declaration, version))

  defp check_failed?(latest, check, declaration, version) do
    case latest[{check, declaration}] do
      %{result: :failed, code: inputs} ->
        Surfex.Scan.Checks.version(declaration, inputs) == version

      _ ->
        false
    end
  end

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
      |> Enum.reduce(%{}, fn
        {{{:test, t}, {:spec, unit}}, place}, acc ->
          Map.update(acc, t, [{place, unit}], &[{place, unit} | &1])

        {{{:check, _}, _}, _place}, acc ->
          acc
      end)

    checks = for %Scan{kind: :check, id: id, check: c} <- scans, into: %{}, do: {id, c}
    index = {testing, verifying, within, definition, checks}

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
         {_, _, _, definition, _}
       ) do
    test_hash = hash_of(tip, :test, t)
    code_hash = hash_of(tip, :code, c)
    fn latest -> passes(latest, t, test_hash, c, code_hash, definition) end
  end

  defp claim_judge(
         %{type: :implements, relation: {_, {:code, c}, {:spec, s}}},
         tip,
         {testing, verifying, within, definition, _}
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

  # A check's claim: its declaration ran and passed against the inputs that make the
  # version the relation holds (§17.1). A check this run didn't run didn't run.
  defp claim_judge(
         %{type: :verifies, relation: {_, {:check, c}, _}},
         tip,
         {_, _, _, _, checks}
       ) do
    version = hash_of(tip, :check, c)
    declaration = checks |> Map.fetch!(c) |> Map.fetch!(:declaration)

    fn latest ->
      case Map.get(latest, {c, declaration}) do
        nil ->
          %{test: c, reason: :not_run}

        %{result: :passed, code: inputs} ->
          if Surfex.Scan.Checks.version(declaration, inputs) == version,
            do: nil,
            else: %{test: c, reason: :other_code}

        %{result: result} when result in [:excluded, :skipped] ->
          %{test: c, reason: result}

        _failed ->
          %{test: c, reason: :failed}
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
    declaring =
      for %Scan{kind: k} = s <- scans, k in [:test, :check], into: %{}, do: {{k, s.id}, s}

    for %{type: :verifies, state: state, relation: {_, from, {:spec, unit}}} <- relations,
        state != :retired,
        test = Map.get(declaring, from),
        test != nil,
        unit not in declared(resolver, test),
        do: %{test: label(from), spec: unit}
  end

  # How a verifier is named in a list: a test by its id, a check as `check ID` (§11.4).
  defp label({:test, t}), do: t
  defp label({:check, c}), do: "check #{c}"

  # A test's declaration that resolves to a spec unit with no verifies relation between
  # them in the log, in any state: the source claims what the log doesn't record (§13.1).
  # One whose relation was retired is listed as retired, with the retire's note: the log
  # decided against what the source still asserts. The relations are indexed once, so
  # this stays linear in the declarations.
  defp unrecorded(scans, relations, resolver) do
    verifies = for %{type: :verifies} = r <- relations, into: %{}, do: {r.relation, r}

    for %Scan{kind: kind} = test <- Enum.sort_by(scans, &{&1.kind == :check, &1.id}),
        kind in [:test, :check],
        unit <- Enum.uniq(declared(resolver, test)),
        relation = Entry.relation(:verifies, test, %{kind: :spec, id: unit}),
        retired <- retired(Map.fetch(verifies, relation)),
        do: %{test: label({kind, test.id}), spec: unit, retired: retired}
  end

  # A live refines relation, both ends scanned, whose unit sits inside another unit but no
  # longer the one it refines (§13.1): a block moved unchanged to another section changes
  # neither end's version, so only re-reading `within` shows it. A unit that sits in
  # nothing (a section) states no such fact, so a refines from it, related by hand, isn't
  # checked. Linear: one lookup per relation in the derive's scan index.
  defp moved(relations, by_id) do
    for %{type: :refines, state: state, relation: {_, {:spec, a}, {:spec, b}}} <- relations,
        state != :retired,
        %Scan{within: within} <- [Map.get(by_id, {:spec, a})],
        within != nil,
        Map.has_key?(by_id, {:spec, b}),
        within != b,
        do: %{from: a, to: b, now: within}
  end

  # [nil] when nothing is recorded, [%{note: …}] when the tip retires it, [] otherwise.
  defp retired(:error), do: [nil]
  defp retired({:ok, %{state: :retired, tip: tip}}), do: [%{note: tip.note}]
  defp retired({:ok, _recorded}), do: []

  @doc false
  # The spec units a test declares it verifies, resolved against the scans or a resolver
  # built from them (`Surfex.Scan.resolve/2`).
  def declared(scans_or_resolver, %Scan{declares: declares}) do
    for {:verifies, ref} <- declares,
        {:ok, unit} <- [Scan.resolve(scans_or_resolver, ref)],
        do: unit.id
  end

  # A declaration that names no spec unit, or an ambiguous bare id; and a deviation tag on
  # a test that declares no unit, so deviates from nothing it names (§13.1).
  defp broken(scans, resolver) do
    for scan <- Enum.sort_by(scans, &{&1.kind, &1.id}),
        why <- declaration_errors(scan, resolver),
        do: Map.put(why, :scan, scan)
  end

  defp declaration_errors(scan, resolver) do
    unresolved =
      for {type, ref} <- scan.declares,
          {:error, why} <- [Scan.resolve(resolver, ref)],
          do: %{type: type, ref: ref, reason: why}

    deviation =
      if scan.kind == :test and scan.deviation != nil and scan.declares == [],
        do: [%{type: :deviation, ref: scan.deviation, reason: :no_unit}],
        else: []

    unresolved ++ deviation
  end
end
