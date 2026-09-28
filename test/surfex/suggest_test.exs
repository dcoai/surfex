defmodule Surfex.SuggestTest do
  use ExUnit.Case, async: true

  alias Surfex.{Item, Scan, Status, Suggest, Trace}
  alias Surfex.Scan.Markdown

  @fixture Path.expand("../fixtures/reference_trace", __DIR__)
  @root Path.join(@fixture, "sources")
  @meta [by: "tester", at: "2026-09-28T10:00:00Z"]

  setup_all do
    {items, _} = Code.eval_file(Path.join(@fixture, "items.exs"))
    items = Enum.map(items, &struct!(Item, &1))
    {config, _} = Code.eval_file(Path.join(@fixture, "trace.exs"))
    trace = Trace.new!(config)
    scans = Markdown.records(@root, ["spec/**/*.md", "notes/**/*.md"]) ++ Scan.code(items)
    %{trace: trace, items: items, scans: scans}
  end

  defp candidates(c, entries \\ []),
    do: Suggest.candidates(c.trace, c.items, c.scans, entries, @root)

  defp pairs(candidates), do: Enum.map(candidates, &{&1.spec.id, &1.code.id})

  @wire "spec/02-wire.md#02 — Wire format"
  @overview "spec/01-overview.md#01 — Overview/1. Sending and receiving"

  test "a citation pairs its section with the item it names", c do
    pairs = pairs(candidates(c))
    assert {"#{@wire}/2. Packet types", "PING"} in pairs
    assert {@overview, "wren_recv"} in pairs
  end

  test "a subject heading, a table cell and a member path each propose their items", c do
    pairs = pairs(candidates(c))
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ping_hdr"} in pairs
    assert {"#{@wire}/1. Common header — 8 bytes", "wren_hdr.len"} in pairs
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ping_hdr.ack"} in pairs
    assert {"#{@wire}/3. PING — 24 bytes", "wren_ack.id"} in pairs
  end

  test "code-block citations, file targets and unresolved names propose nothing", c do
    candidates = candidates(c)
    refute Enum.any?(candidates, &(&1.code.id == "wren.h"))
    refute Enum.any?(candidates, &(&1.code.id in ["wren_send_all", "wren_twin", "wren_retry"]))
    # wren_send is cited both in prose and in a code block; only the prose citation counts.
    assert [%{cited_at: {"spec/01-overview.md", 7}}] =
             Enum.filter(candidates, &(&1.code.id == "wren_send"))
  end

  test "each candidate records where it was cited, once per pair", c do
    candidates = candidates(c)
    assert length(candidates) == length(Enum.uniq(pairs(candidates)))

    assert Enum.all?(
             candidates,
             &match?(%{cited_at: {"spec/" <> _, line}} when is_integer(line), &1)
           )
  end

  test "accept records one relation each, and a second run suggests nothing", c do
    first = candidates(c)
    {:ok, entries} = Suggest.accept(first, c.scans, [], @meta)
    assert length(entries) == length(first)
    assert Enum.all?(entries, &(&1.op == :relate and &1.type == :implements))
    assert Enum.all?(Status.derive(c.scans, entries).relations, &(&1.state == :current))
    assert candidates(c, entries) == []
  end

  test "a pair already related in any state is left alone, never re-confirmed", c do
    [one | _] = candidates(c)
    {:ok, [related]} = Suggest.accept([one], c.scans, [], @meta)

    # The item changes: the relation dangles, and suggest must not "fix" it.
    moved =
      Enum.map(c.scans, fn s ->
        if s.id == one.code.id and s.kind == :code, do: %{s | hash: "moved"}, else: s
      end)

    refute {one.spec.id, one.code.id} in pairs(
             Suggest.candidates(c.trace, c.items, moved, [related], @root)
           )

    assert [%{state: :dangling}] = Status.derive(moved, [related]).relations
  end
end
