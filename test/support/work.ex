defmodule Surfex.Test.Work do
  @moduledoc """
  The work a function does, counted exactly: what the linearity guards (suggest-linear,
  derive-linear, evidence-check-linear) compare across project sizes (#268).

  Reductions are the right unit, since they count work done rather than time taken. But
  counting them in the calling process, as the guards first did, mixes in the reductions
  the VM charges for garbage collection. That charge is not a function of the work: the
  same computation with the same number of collections is charged differently from run
  to run, and more so when the schedulers are busy (measured on #268: identical runs
  spread by up to 6% with collections, by under 0.1% without). A guard that subtracts
  two large counts, or compares a small one with a large one, turns that into a ratio
  that crosses its bound under a loaded suite.

  `reductions/1` takes the collections out. It runs the function once unmeasured, which
  loads the code it calls and shows how much it allocates. Then it runs it again in a
  fresh process whose heap (and binary heap) already holds all of that, so no collection
  happens, and counts that run's reductions. Collections are traced, and a run in which one happened
  anyway is discarded and repeated with twice the heap.
  """

  import Bitwise

  # The smallest heap a measured run starts with, in words.
  @floor 1 <<< 20

  # A heap this large and still collecting means the work isn't what the caller thinks.
  @ceiling 1 <<< 30

  @doc """
  The reductions `fun` takes, run in a fresh process in which no garbage collection
  happens. `fun` runs at least twice: once to warm up and size the heap, then measured.
  """
  @spec reductions((-> term)) :: non_neg_integer
  def reductions(fun) do
    %{needed: needed} = run(fun, [])
    measured(fun, max(@floor, 2 * needed))
  end

  defp measured(_fun, heap) when heap > @ceiling,
    do: raise(ArgumentError, "work still collected garbage with a heap of #{heap} words")

  defp measured(fun, heap) do
    # The binary heap too: refc binaries past its size start a collection of their own.
    case run(fun, min_heap_size: heap, min_bin_vheap_size: heap) do
      %{collections: 0, reductions: reductions} -> reductions
      %{} -> measured(fun, 2 * heap)
    end
  end

  # One traced run of `fun` in a fresh process spawned with `opts`: its reductions, the
  # collections that happened during it, and the heap it needs to run with none: every
  # word that was ever on its young heap (what it holds at the end, plus what each
  # collection took away, heap fragments included).
  defp run(fun, opts) do
    parent = self()

    pid =
      :erlang.spawn_opt(
        fn ->
          receive do: (:go -> :ok)
          used = fn -> Process.info(self(), :garbage_collection_info) |> elem(1) end
          {:reductions, start} = Process.info(self(), :reductions)
          fun.()
          {:reductions, finish} = Process.info(self(), :reductions)
          later = used.()
          send(parent, {self(), finish - start, later[:heap_size] + later[:mbuf_size]})
          receive do: (:stop -> :ok)
        end,
        [:link | opts]
      )

    1 = :erlang.trace(pid, true, [:garbage_collection, {:tracer, self()}])
    send(pid, :go)

    {reductions, held} = receive do: ({^pid, r, held} -> {r, held})

    # Every trace message the run caused is in the mailbox before its collections count.
    delivered = :erlang.trace_delivered(pid)
    receive do: ({:trace_delivered, ^pid, ^delivered} -> :ok)
    events = traced(pid, [])
    send(pid, :stop)

    starts = for {start, info} <- events, start in [:gc_minor_start, :gc_major_start], do: info
    ends = for {stop, info} <- events, stop in [:gc_minor_end, :gc_major_end], do: info

    taken =
      Enum.sum(for i <- starts, do: i[:heap_size] + i[:mbuf_size]) -
        Enum.sum(for i <- ends, do: i[:heap_size])

    %{
      reductions: reductions,
      collections: length(starts),
      needed: held + taken
    }
  end

  defp traced(pid, events) do
    receive do
      {:trace, ^pid, event, info} -> traced(pid, [{event, info} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
