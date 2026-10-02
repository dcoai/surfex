defmodule Surfex.ReferenceTest do
  @moduledoc """
  Reading a spec and relating it, end to end, over an invented reference implementation
  ("Wren": a tiny packet protocol in C) and its spec, in `test/fixtures/reference/`. Every
  feature of citation reading and of excusing code has a case there, including the failure
  paths, and each test says which feature broke when it fails.
  """
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Scan, Status, Suggest}
  alias Surfex.Scan.{Classes, Markdown}
  alias Surfex.Status.Config

  @fixture Path.expand("../fixtures/reference", __DIR__)
  @meta [by: "tester", at: "2026-09-28T10:00:00Z"]

  setup_all do
    {items, _} = Code.eval_file(Path.join(@fixture, "items.exs"))
    {config, _} = Code.eval_file(Path.join(@fixture, "surfex.exs"))
    items = Enum.map(items, &struct!(Item, &1))
    profile = Config.profile!(config, nil)
    root = Path.join(@fixture, "sources")

    scans =
      Markdown.records(root, config[:sources]) ++ Scan.code(items) ++ Classes.records(config)

    %{
      config: config,
      items: items,
      root: root,
      scans: scans,
      profile: profile,
      suggestions: Suggest.all(profile, items, scans, [], root)
    }
  end

  # Each test reads the citations itself: what a test exercises is what it calls, not what
  # its setup prepared (§11).
  defp citations(c), do: Cite.citations(c.items, c.profile, c.root)

  # The sections, as {file, heading}, whose resolved citations name `key`.
  defp cited(c, key) do
    for %{status: :resolved, items: items} = x <- citations(c),
        key in items,
        uniq: true,
        do: {x.file, x.section}
  end

  defp citation(c, file, span),
    do: Enum.find(citations(c), &(&1.file == file and &1.span == span))

  describe "citations" do
    @describetag verifies: "citation-resolves"

    @tag verifies: "subject-sections"
    test "a subject section's heading cites what it is about", c do
      assert {"spec/02-wire.md", "1. Common header — 8 bytes"} in cited(c, "wren_hdr")
      assert {"spec/02-wire.md", "3. PING — 24 bytes"} in cited(c, "wren_ping_hdr")
    end

    @tag verifies: "subject-sections"
    test "a bare member in a subject section resolves to the subject's member", c do
      assert %{items: ["wren_hdr.kind"]} = citation(c, "spec/02-wire.md", "kind")
    end

    @tag verifies: "subject-sections"
    test "inside a subject section the member wins over a global of the same name", c do
      assert cited(c, "wren_ping_hdr.window") == [{"spec/02-wire.md", "3. PING — 24 bytes"}]
      assert cited(c, "window") == [{"spec/01-overview.md", "1. Sending and receiving"}]
    end

    @tag verifies: "citation-reading"
    test "table cells under a citing column need no backticks", c do
      assert %{items: ["wren_hdr.len"]} = citation(c, "spec/02-wire.md", "len")
      assert %{items: ["wren_hdr.seq"]} = citation(c, "spec/02-wire.md", "seq")
      assert %{items: ["PING"]} = citation(c, "spec/02-wire.md", "PING")
    end

    @tag verifies: "member-paths"
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

      assert {"spec/01-overview.md", "(code block)"} in cited(c, "wren_send")
    end

    @tag verifies: ["citation-status-kinds", "citation-statuses", "citation-notation"]
    test "every status is reached, and prose in backticks is not a citation", c do
      assert %{status: :unresolved} = citation(c, "spec/01-overview.md", "wren_send_all")
      assert %{status: :ambiguous} = citation(c, "spec/01-overview.md", "wren_twin")
      assert %{status: :external} = citation(c, "spec/01-overview.md", "wrend")
      assert %{status: :documented_absence} = citation(c, "notes/retry.md", "wren_retry")
      assert citation(c, "spec/01-overview.md", ":ok") == nil
    end
  end

  describe "relating it" do
    @tag verifies: "suggesting"
    test "a class excuses by kind and name, and parent_cited covers a member", c do
      suggestions = Suggest.all(c.profile, c.items, c.scans, [], c.root)

      assert suggestions.excuses |> Enum.map(&{&1.from.id, &1.to.id}) |> Enum.sort() == [
               {"internal constants", "WREN_BUCKETS"},
               {"internal constants", "wren_twin (impl_const)"},
               {"locking", "wren_lock"},
               {"members of a documented structure", "wren_ack.port"},
               {"reference prose", "protocol.md#Overview"}
             ]
    end

    @tag verifies: "status-states"
    test "status: what nothing implements or excuses is unmet, and broken citations fail", c do
      {:ok, entries} = Suggest.accept_all(c.suggestions, c.scans, [], @meta)
      citations = Config.broken_citations(c.config, c.items, c.root, nil)

      status =
        Status.derive(c.scans, entries, [code: [:implements, :excuses]], citations: citations)

      unmet = for %{scan: %{kind: :code} = s} <- status.unmet, do: {s.id, s.role}
      assert {"wren_orphan", :function} in unmet
      refute {"wren_lock", :function} in unmet

      # Two items with one key are related each on its own (#60): the constant is excused,
      # the function is described by nothing.
      assert {"wren_twin (function)", :function} in unmet
      refute {"wren_twin (impl_const)", :impl_const} in unmet

      assert Enum.map(status.citations, &{&1.span, &1.status}) == [
               {"wren_send_all", :unresolved},
               {"wren_twin", :ambiguous}
             ]

      assert Status.failing?(status)
    end
  end
end
