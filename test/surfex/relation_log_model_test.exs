# The model of the relation log (#128), checked exhaustively by extla. extla is a dependency
# of the `model` Mix environment only, so these modules exist only there:
#
#     MIX_ENV=model mix test test/surfex/relation_log_model_test.exs
#
# Everywhere else this file defines nothing, and the rest of the suite neither fetches nor
# compiles extla.
if Code.ensure_loaded?(ExTLA.Spec) do
  defmodule Surfex.Model.Log do
    @moduledoc false
    # The real surfex code, driven by the model (#128): every entry is written by
    # `Surfex.Record` and every judgement made by `Surfex.Status.derive/4`, so the model's
    # invariants are checked against the code itself, not a reimplementation of it.

    alias Surfex.{Record, Scan, Status}
    alias Surfex.Log.Entry

    @spec_id "spec.md#s"
    @code_id "M.f/0"

    def scans,
      do: [
        %Scan{
          kind: :spec,
          id: @spec_id,
          hash: "s1",
          role: :section,
          location: %{file: "spec.md", lines: {1, 1}}
        },
        %Scan{kind: :code, id: @code_id, hash: "c1", location: %{file: "lib/m.ex", lines: {1, 1}}}
      ]

    # Who and when: the branch, and the log's length, so two branches recording the same step
    # write different entries (as two people would) and a state fingerprints stably.
    defp meta(log, branch),
      do: [by: "model-#{branch}", at: at(MapSet.size(log)), note: "model step on #{branch}"]

    defp at(n), do: "2026-01-01T00:00:#{String.pad_leading(Integer.to_string(n), 2, "0")}Z"

    # A log in the model is a set of entries: the order lines happen to land in is what
    # order_free?/1 checks, so it mustn't also split states. The code reads them in time order.
    def lines(log), do: Enum.sort_by(log, &{&1.at, &1.id})

    defp append(log, {:ok, entries}), do: MapSet.union(log, MapSet.new(entries))

    def relate(log, branch),
      do:
        append(
          log,
          Record.relate(scans(), lines(log), @spec_id, @code_id, :implements, meta(log, branch))
        )

    def retire(log, branch),
      do:
        append(
          log,
          Record.retire(scans(), lines(log), @spec_id, @code_id, :implements, meta(log, branch))
        )

    # Resolves the conflict by picking the tip with the smallest id: any pick must end it.
    def resolve(log, branch) do
      [%{tips: tips}] = conflicted(log)
      pick = tips |> Enum.map(& &1.id) |> Enum.min()

      append(
        log,
        Record.resolve(
          scans(),
          lines(log),
          @spec_id,
          @code_id,
          :implements,
          pick,
          meta(log, branch)
        )
      )
    end

    # Git's union merge: every line of either side, once.
    def merge(into, from), do: MapSet.union(into, from)

    def conflicted(log),
      do: for(%{state: :conflicted} = r <- Status.derive(scans(), lines(log)).relations, do: r)

    def conflicted?(log), do: conflicted(log) != []

    # What a log says, independent of how it is written down.
    defp verdict(log) do
      for r <- Status.derive(scans(), log).relations,
          do: {r.relation, r.state, r.tips |> Enum.map(& &1.id) |> Enum.sort()}
    end

    # The same lines in any order give the same status (§12.2: the union merge reorders).
    def order_free?(log) do
      v = verdict(lines(log))
      v == verdict(Enum.reverse(lines(log))) and v == verdict(Enum.sort_by(log, & &1.id))
    end

    # Conflicted exactly when the tips in force disagree (§13.1, #133): tips that record
    # the same judgement are one, however many there are.
    def conflict_iff_disagree?(log),
      do:
        Enum.all?(Status.derive(scans(), lines(log)).relations, fn r ->
          disagree =
            r.tips |> Enum.map(&{&1.op, &1.ends, &1.basis}) |> Enum.uniq() |> length() > 1

          r.state == :conflicted == disagree
        end)

    # Every entry written is one the log can read back, under the same id (§12.1).
    def grammatical?(log), do: Enum.all?(log, &(Entry.decode(Entry.encode(&1)) == {:ok, &1}))
  end

  defmodule Surfex.Model.RelationLog do
    @moduledoc false
    # Branches record relations, retire them and resolve conflicts; main takes each branch
    # by git's union merge, and a branch catches up with main the same way.
    use ExTLA.Spec

    alias Surfex.Model.Log

    constant :branches, default: MapSet.new([:a, :b])
    # A branch records at most max_entries steps of its own; a log holds at most max_log lines,
    # which bounds resolve too (two branches resolving one conflict make a new one, forever).
    constant :max_entries, default: 2
    constant :max_log, default: 4

    variable :main, type: :set
    variable :work, type: [^branches ~> :set]
    # Whether every resolve so far ended the conflict it picked a side of.
    variable :resolved, type: [true, false]

    init do
      main = MapSet.new()
      work = for_each(^branches, fn _ -> MapSet.new() end)
      resolved = true
    end

    action :relate, params: [b: ^branches] do
      require MapSet.size(work[b]) < ^max_entries
      work = update(work, b, &Log.relate(&1, b))
    end

    action :retire, params: [b: ^branches] do
      require MapSet.size(work[b]) < ^max_entries
      work = update(work, b, &Log.retire(&1, b))
    end

    action :resolve, params: [b: ^branches] do
      require Log.conflicted?(work[b])
      require MapSet.size(work[b]) < ^max_log
      let(after_resolve = Log.resolve(work[b], b))
      work = update(work, b, fn _ -> after_resolve end)
      resolved = resolved and not Log.conflicted?(after_resolve)
    end

    action :push, params: [b: ^branches] do
      require Log.merge(main, work[b]) != main
      main = Log.merge(main, work[b])
    end

    action :pull, params: [b: ^branches] do
      require Log.merge(work[b], main) != work[b]
      work = update(work, b, &Log.merge(&1, main))
    end

    # The model is bounded, so it ends: every branch has spent its steps, resolved what it
    # still may, and agrees with main.
    terminal :budget_spent do
      Enum.all?(^branches, fn b ->
        MapSet.size(work[b]) >= ^max_entries and
          (not Log.conflicted?(work[b]) or MapSet.size(work[b]) >= ^max_log) and
          Log.merge(main, work[b]) == main and Log.merge(work[b], main) == work[b]
      end)
    end

    invariant :order_free, desc: "a log's status doesn't depend on the order of its lines" do
      Log.order_free?(main) and Enum.all?(^branches, &Log.order_free?(work[&1]))
    end

    invariant :conflict_iff_disagree, desc: "conflicted exactly when the tips disagree" do
      Log.conflict_iff_disagree?(main) and
        Enum.all?(^branches, &Log.conflict_iff_disagree?(work[&1]))
    end

    invariant :resolve_ends_conflict, desc: "resolving always ends the conflict" do
      resolved
    end

    invariant :grammatical, desc: "every entry written reads back under its id" do
      Log.grammatical?(main) and Enum.all?(^branches, &Log.grammatical?(work[&1]))
    end
  end

  defmodule Surfex.Model.Proof do
    @moduledoc false
    # The real code again (#131), now with versions and test runs: a spec unit S, the code C
    # that implements it and a test T that verifies S and calls C, each at version 1 or 2.

    alias Surfex.{Evidence, Record, Scan, Status}
    alias Surfex.Log.Entry

    @spec_id "spec.md#s"
    @code_id "M.f/0"
    @test_id "T: t"
    @loc %{file: "f", lines: {1, 1}}

    def scans(v),
      do: [
        %Scan{kind: :spec, id: @spec_id, hash: "s#{v.spec}", role: :section, location: @loc},
        %Scan{kind: :code, id: @code_id, hash: "c#{v.code}", location: @loc},
        %Scan{
          kind: :test,
          id: @test_id,
          hash: "t#{v.test}",
          declares: [{:verifies, @spec_id}],
          calls: [@code_id],
          location: @loc
        }
      ]

    def lines(log), do: Enum.sort_by(log, &{&1.at, &1.id})
    defp at(n), do: "2026-01-01T00:#{pad(div(n, 60))}:#{pad(rem(n, 60))}Z"
    defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
    # An entry's time is the log's own count, not the runs': the same log reached by a
    # different interleaving of runs and records is the same state.
    defp meta(log, _ev), do: [by: "model", at: at(MapSet.size(log)), note: "model"]

    # One run of T at its version against the code's: it may pass or fail.
    def run(ev, v, result),
      do:
        ev ++
          [
            %{
              test: @test_id,
              test_hash: "t#{v.test}",
              result: result,
              at: at(100 + length(ev)),
              run: "r#{length(ev)}",
              seq: 0,
              code: %{@code_id => "c#{v.code}"}
            }
          ]

    defp append(log, {:ok, entries}), do: MapSet.union(log, MapSet.new(entries))
    defp append(log, {:error, _}), do: log

    # What `suggest --accept` would record for each relation the source states.
    def relate(log, v, ev, :verifies),
      do:
        append(
          log,
          Record.relate(
            scans(v),
            lines(log),
            "test:" <> @test_id,
            @spec_id,
            :verifies,
            meta(log, ev),
            evidence: ev
          )
        )

    def relate(log, v, ev, :tests),
      do:
        append(
          log,
          Record.relate(
            scans(v),
            lines(log),
            "test:" <> @test_id,
            @code_id,
            :tests,
            meta(log, ev)
          )
        )

    def relate(log, v, ev, :implements),
      do:
        append(
          log,
          Record.relate(scans(v), lines(log), @spec_id, @code_id, :implements, meta(log, ev))
        )

    def related?(log, type),
      do: Enum.any?(log, &(&1.type == type and Entry.relation?(&1)))

    def confirm_evidence(log, v, ev),
      do: append(log, Record.confirm_by_evidence(scans(v), lines(log), ev, meta(log, ev)))

    def validate(log, v, ev),
      do:
        append(
          log,
          Record.validate(scans(v), lines(log), "test:" <> @test_id, @spec_id, ev, meta(log, ev))
        )

    # A judgement: the spec reworded without a change of behaviour (§18).
    def judge(log, v, ev),
      do:
        append(
          log,
          Record.confirm(
            scans(v),
            lines(log),
            "test:" <> @test_id,
            @spec_id,
            :verifies,
            meta(log, ev)
          )
        )

    defp derive(log, v), do: Status.derive(scans(v), lines(log))

    # A current relation's ends are at the versions scanned now (§13.1).
    def current_means_current?(log, v) do
      now = Map.new(scans(v), &{{&1.kind, &1.id}, &1.hash})

      Enum.all?(derive(log, v).relations, fn
        %{state: :current, tip: tip} -> Enum.all?(tip.ends, &(now[{&1.kind, &1.id}] == &1.hash))
        _ -> true
      end)
    end

    # Code is shown, never asserted: a current implements rests on evidence or a review (§18).
    def shown_not_asserted?(log, v),
      do:
        Enum.all?(derive(log, v).relations, fn
          %{type: :implements, state: :current, tip: tip} -> tip.basis in [:evidence, :review]
          _ -> true
        end)

    # Every entry on evidence is borne out by runs that happened (§17): a verifies on its
    # test version's failing run; anything else on a red then green, in the runs or
    # recorded in the log as a red_green observation.
    def backed?(log, ev) do
      observed = for %Entry{op: :observe, type: :red_green, ends: [t]} <- log, do: t.hash

      discriminated? = fn hash ->
        Evidence.discriminating?(ev, @test_id, hash) or hash in observed
      end

      versions = ["t1", "t2"]

      Enum.all?(log, fn
        %Entry{basis: :evidence, type: :verifies, ends: ends} ->
          test = Enum.find(ends, &(&1.kind == :test))
          Enum.any?(ev, &(&1.test_hash == test.hash and &1.result == :failed))

        %Entry{basis: :evidence, op: :observe, ends: [t]} ->
          Evidence.discriminating?(ev, @test_id, t.hash)

        %Entry{basis: :evidence, type: :tests, ends: ends} ->
          discriminated?.(Enum.find(ends, &(&1.kind == :test)).hash)

        %Entry{basis: :evidence, type: :implements} ->
          Enum.any?(versions, discriminated?)

        _other ->
          true
      end)
    end

    # A review rests on a green run (§18): the test passed at the test version the review
    # records, against the code version it records.
    def reviewed_green?(log, ev) do
      Enum.all?(log, fn
        %Entry{basis: :review, ends: ends} ->
          at = fn kind -> Enum.find_value(ends, &(&1.kind == kind && &1.hash)) end
          {test, code} = {at.(:test), at.(:code)}

          Enum.any?(ev, fn r ->
            r.result == :passed and (test == nil or r.test_hash == test) and
              (code == nil or r.code[@code_id] == code)
          end)

        _other ->
          true
      end)
    end

    def grammatical?(log), do: Enum.all?(log, &(Entry.decode(Entry.encode(&1)) == {:ok, &1}))
  end

  defmodule Surfex.Model.EvidencePath do
    @moduledoc false
    # The evidence path (#131): the code changes; tests run red or green; the relations are
    # recorded as suggest records them and confirmed by evidence.
    use ExTLA.Spec

    alias Surfex.Model.Proof

    constant :max_runs, default: 3
    constant :max_log, default: 6

    variable :spec, type: 1..2
    variable :code, type: 1..2
    variable :test, type: 1..2
    variable :log, type: :set
    variable :ev, type: :seq

    init do
      spec = 1
      code = 1
      test = 1
      log = MapSet.new()
      ev = []
    end

    action :change_code do
      require code == 1
      code = 2
    end

    action :run, params: [result: [:passed, :failed]] do
      require length(ev) < ^max_runs
      ev = Proof.run(ev, %{spec: spec, code: code, test: test}, result)
    end

    action :relate, params: [type: [:verifies, :tests, :implements]] do
      require not Proof.related?(log, type) and MapSet.size(log) < ^max_log
      let after_relate = Proof.relate(log, %{spec: spec, code: code, test: test}, ev, type)
      require after_relate != log
      log = after_relate
    end

    action :confirm_evidence do
      require MapSet.size(log) < ^max_log
      let after_confirm = Proof.confirm_evidence(log, %{spec: spec, code: code, test: test}, ev)
      require after_confirm != log
      log = after_confirm
    end

    terminal :budget_spent do
      code == 2 and length(ev) >= ^max_runs
    end

    invariant :current_means_current, desc: "a current relation's ends are at their versions" do
      Proof.current_means_current?(log, %{spec: spec, code: code, test: test})
    end

    invariant :shown_not_asserted, desc: "a current implements rests on evidence or a review" do
      Proof.shown_not_asserted?(log, %{spec: spec, code: code, test: test})
    end

    invariant :backed_by_runs, desc: "every entry on evidence is borne out by runs" do
      Proof.backed?(log, ev)
    end

    invariant :grammatical, desc: "every entry written reads back under its id" do
      Proof.grammatical?(log)
    end
  end

  defmodule Surfex.Model.ReviewPath do
    @moduledoc false
    # The review path (#131): the spec and the test change; tests run; relations are
    # validated by a review, by a judgement on a reworded spec, or by evidence.
    use ExTLA.Spec

    alias Surfex.Model.Proof

    constant :max_runs, default: 3
    constant :max_log, default: 6

    variable :spec, type: 1..2
    variable :code, type: 1..2
    variable :test, type: 1..2
    variable :log, type: :set
    variable :ev, type: :seq

    init do
      spec = 1
      code = 1
      test = 1
      log = MapSet.new()
      ev = []
    end

    action :change_spec do
      require spec == 1
      spec = 2
    end

    action :change_test do
      require test == 1
      test = 2
    end

    action :run, params: [result: [:passed, :failed]] do
      require length(ev) < ^max_runs
      ev = Proof.run(ev, %{spec: spec, code: code, test: test}, result)
    end

    action :relate, params: [type: [:verifies, :tests, :implements]] do
      require not Proof.related?(log, type) and MapSet.size(log) < ^max_log
      let after_relate = Proof.relate(log, %{spec: spec, code: code, test: test}, ev, type)
      require after_relate != log
      log = after_relate
    end

    action :confirm_evidence do
      require MapSet.size(log) < ^max_log
      let after_confirm = Proof.confirm_evidence(log, %{spec: spec, code: code, test: test}, ev)
      require after_confirm != log
      log = after_confirm
    end

    action :validate do
      require MapSet.size(log) < ^max_log
      let after_validate = Proof.validate(log, %{spec: spec, code: code, test: test}, ev)
      require after_validate != log
      log = after_validate
    end

    action :judge do
      require MapSet.size(log) < ^max_log
      let after_judge = Proof.judge(log, %{spec: spec, code: code, test: test}, ev)
      require after_judge != log
      log = after_judge
    end

    terminal :budget_spent do
      spec == 2 and test == 2 and length(ev) >= ^max_runs
    end

    invariant :current_means_current, desc: "a current relation's ends are at their versions" do
      Proof.current_means_current?(log, %{spec: spec, code: code, test: test})
    end

    invariant :shown_not_asserted, desc: "a current implements rests on evidence or a review" do
      Proof.shown_not_asserted?(log, %{spec: spec, code: code, test: test})
    end

    invariant :backed_by_runs, desc: "every entry on evidence is borne out by runs" do
      Proof.backed?(log, ev)
    end

    invariant :grammatical, desc: "every entry written reads back under its id" do
      Proof.grammatical?(log)
    end

    invariant :reviewed_green, desc: "every review rests on a passing run at its versions" do
      Proof.reviewed_green?(log, ev)
    end
  end

  defmodule Surfex.RelationLogModelTest do
    # The model, checked exhaustively: every invariant in every reachable state.
    use ExUnit.Case, async: true
    import ExTLA.Spec.Test

    @moduletag verifies: "log-model"
    @moduletag timeout: :infinity

    @tag verifies: "log-model-validation"
    test "the evidence path: code changes, runs and confirm --evidence keep the invariants" do
      assert_spec(Surfex.Model.EvidencePath, %{
        constants: %{max_runs: 3, max_log: 6},
        strict_coverage: true
      })
    end

    @tag verifies: "log-model-validation"
    test "the review path: spec and test changes, reviews and judgements keep the invariants" do
      assert_spec(Surfex.Model.ReviewPath, %{
        constants: %{max_runs: 2, max_log: 5},
        strict_coverage: true
      })
    end

    test "branches, merges and resolves keep the log's invariants in every reachable state" do
      assert_spec(Surfex.Model.RelationLog, %{
        constants: %{branches: MapSet.new([:a, :b]), max_entries: 2, max_log: 4},
        strict_coverage: true
      })
    end
  end
end
