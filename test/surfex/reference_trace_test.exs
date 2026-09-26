defmodule Surfex.ReferenceTraceTest do
  @moduledoc """
  A whole trace, end to end, over an invented reference implementation ("Wren": a tiny
  packet protocol in C) and its spec. Every feature a trace has is exercised by a case in
  `test/fixtures/reference_trace/`, including the failure paths.

  The rendered golden must equal `expected.md`, which was reviewed line by line when it
  was recorded. The per-feature tests below say *which* feature broke when it doesn't.
  """
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Trace}

  @fixture Path.expand("../fixtures/reference_trace", __DIR__)

  setup_all do
    {items, _} = Code.eval_file(Path.join(@fixture, "items.exs"))
    {config, _} = Code.eval_file(Path.join(@fixture, "trace.exs"))
    trace = Trace.new!(config)
    analysis = Trace.analyse(trace, Enum.map(items, &struct!(Item, &1)), sources())
    %{trace: trace, analysis: analysis, golden: Trace.render(trace, analysis)}
  end

  defp sources, do: Path.join(@fixture, "sources")

  defp cited(c, key), do: Map.get(c.analysis.by_item, key, [])

  defp citation(c, file, span),
    do: Enum.find(c.analysis.citations, &(&1.file == file and &1.span == span))

  defp row(c, item, kind),
    do: c.golden |> String.split("\n") |> Enum.find(&(&1 =~ "| `#{item}` | `#{inspect(kind)}` |"))

  test "the golden is the recorded one", c do
    assert c.golden == File.read!(Path.join(@fixture, "expected.md"))
  end

  describe "citations" do
    test "a subject section's heading cites what it is about", c do
      assert "spec/02 — 1. Common header — 8 bytes" in cited(c, "wren_hdr")
      assert "spec/02 — 3. PING — 24 bytes" in cited(c, "wren_ping_hdr")
    end

    test "a bare member in a subject section resolves to the subject's member", c do
      assert %{items: ["wren_hdr.kind"]} = citation(c, "spec/02-wire.md", "kind")
    end

    test "inside a subject section the member wins over a global of the same name", c do
      assert cited(c, "wren_ping_hdr.window") == ["spec/02 — 3. PING — 24 bytes"]
      assert cited(c, "window") == ["spec/01 — 1. Sending and receiving"]
    end

    test "table cells under a citing column need no backticks", c do
      assert %{items: ["wren_hdr.len"]} = citation(c, "spec/02-wire.md", "len")
      assert %{items: ["wren_hdr.seq"]} = citation(c, "spec/02-wire.md", "seq")
      assert %{items: ["PING"]} = citation(c, "spec/02-wire.md", "PING")
    end

    test "a member path walks through the member's type and cites every step", c do
      assert %{status: :resolved, items: ["wren_ping_hdr.ack", "wren_ack.id"]} =
               citation(c, "spec/02-wire.md", "ack.id")
    end

    test "normalisation, file targets, inner tokens and code blocks", c do
      assert %{items: ["wren_recv"]} = citation(c, "spec/01-overview.md", "wren_recv()")
      assert %{items: ["wren_ack"]} = citation(c, "spec/01-overview.md", "struct wren_ack")
      assert %{items: ["wren.h"]} = citation(c, "spec/01-overview.md", "wren.h")

      assert %{items: ["WREN_MAX_LEN"]} =
               citation(c, "spec/01-overview.md", "ioctl(fd, WREN_MAX_LEN)")

      assert "spec/01 — (code block)" in cited(c, "wren_send")
    end

    test "every status is reached, and prose in backticks is not a citation", c do
      assert %{status: :unresolved} = citation(c, "spec/01-overview.md", "wren_send_all")
      assert %{status: :ambiguous} = citation(c, "spec/01-overview.md", "wren_twin")
      assert %{status: :external} = citation(c, "spec/01-overview.md", "wrend")
      assert %{status: :documented_absence} = citation(c, "notes/retry.md", "wren_retry")
      assert citation(c, "spec/01-overview.md", ":ok") == nil
    end

    test "file labels rewrite a matching path; any other falls back to its stem", c do
      assert Cite.section_label(citation(c, "notes/retry.md", "wren_retry"), c.trace.profile) ==
               "retry — Retries"
    end
  end

  describe "verdicts" do
    test "a class excuses by kind and name; parent_cited covers a member", c do
      assert row(c, "wren_lock", :function) =~ "`— locking`"
      assert row(c, "wren_ack.port", :wire_field) =~ "`— members of a documented structure`"
      assert row(c, "WREN_BUCKETS", :impl_const) =~ "`— internal constants`"
      assert row(c, "protocol.md#Overview", :prose) =~ "`— reference prose`"
    end

    test "an uncited item no rule excuses is a GAP", c do
      assert row(c, "wren_orphan", :function) =~ "`:GAP`"
    end

    test "two items sharing a key keep their own verdicts", c do
      assert row(c, "wren_twin", :function) =~ "`:GAP`"
      assert row(c, "wren_twin", :impl_const) =~ "`— internal constants`"
    end

    test "failures name every GAP and broken citation", c do
      assert Trace.failures(c.trace, c.analysis) == [
               "GAP: `wren_orphan` is neither cited by the spec nor excused by a class",
               "GAP: `wren_twin` (`:function`) is neither cited by the spec nor excused by a class",
               "unresolved: `wren_send_all` at spec/01-overview.md:18, 2. Not yet",
               "ambiguous: `wren_twin` at spec/01-overview.md:18, 2. Not yet (could be wren_twin, wren_twin)"
             ]
    end
  end

  describe "the golden's layout" do
    test "prose blocks print each generated list", c do
      assert c.golden =~ "### Knowingly not catalogued\n\n- **static helpers** —"
      assert c.golden =~ "### Cited but outside the reference\n\n- `wrend` —"
      assert c.golden =~ "### Why a row may read `— <class>`\n\n- **reference prose** —"

      assert c.golden =~
               "### Naming what the reference does not have\n\n- `wren_retry` in `notes/retry.md` —"
    end

    test "groups in order, unlisted kinds after them, item noun and locus prefix", c do
      headings = Regex.scan(~r/^## (.+)$/m, c.golden, capture: :all_but_first) |> List.flatten()

      assert headings ==
               ~w(Structures Fields) ++
                 ["Packet types", "Constants", "Parameters", "Functions", "impl_const", "prose"]

      assert c.golden =~ "**24 reference items** · cited 17 · expected-silent 5 · GAPS 2"
      assert row(c, "wren_send", :function) =~ "`ref/wren.c`"
    end
  end
end
