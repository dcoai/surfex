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

    # Conflicted exactly when more than one tip is in force (§13.1).
    def conflict_iff_tips?(log),
      do:
        Enum.all?(Status.derive(scans(), lines(log)).relations, fn r ->
          r.state == :conflicted == length(r.tips) > 1
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

    invariant :conflict_iff_tips, desc: "conflicted exactly when more than one tip is in force" do
      Log.conflict_iff_tips?(main) and Enum.all?(^branches, &Log.conflict_iff_tips?(work[&1]))
    end

    invariant :resolve_ends_conflict, desc: "resolving always ends the conflict" do
      resolved
    end

    invariant :grammatical, desc: "every entry written reads back under its id" do
      Log.grammatical?(main) and Enum.all?(^branches, &Log.grammatical?(work[&1]))
    end
  end

  defmodule Surfex.RelationLogModelTest do
    # The model, checked exhaustively: every invariant in every reachable state.
    use ExUnit.Case, async: true
    import ExTLA.Spec.Test

    @moduletag verifies: "log-model"
    @moduletag timeout: :infinity

    test "branches, merges and resolves keep the log's invariants in every reachable state" do
      assert_spec(Surfex.Model.RelationLog, %{
        constants: %{branches: MapSet.new([:a, :b]), max_entries: 2, max_log: 4},
        strict_coverage: true
      })
    end
  end
end
