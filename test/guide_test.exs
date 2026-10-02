defmodule Surfex.GuideTest do
  @moduledoc """
  The specification guide's worked example (§10) makes claims about what Surfex does: which
  relations `mix surfex.suggest` proposes for each version of the Wren spec, and which of
  them dangle or are orphaned after each edit. This runs Surfex on the guide's own text,
  so a claim the scanner stops honouring fails here rather than misleading a reader.
  """
  use ExUnit.Case, async: true

  alias Surfex.{Item, Scan, Status, Suggest}
  alias Surfex.Status.Config
  alias Surfex.Scan.Markdown

  @moduletag :tmp_dir
  @moduletag verifies: "spec-guide"
  @guide Path.expand("../guides/writing-specs.md", __DIR__)
  @meta [by: "guide", at: "2026-09-28T10:00:00Z"]

  # The code the example's spec describes, as the Elixir scanner would report it.
  @items [
    %Item{kind: :module, name: "Wren.Queue", file: "lib/wren/queue.ex", hash: "00000001"},
    %Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/wren.ex", hash: "00000002"},
    %Item{kind: :function, name: "recv/1", parent: "Wren", file: "lib/wren.ex", hash: "00000003"},
    %Item{
      kind: :function,
      name: "max_len/0",
      parent: "Wren",
      file: "lib/wren.ex",
      hash: "00000004"
    }
  ]

  # A fenced example named by its info string, `markdown NAME`, at any fence length.
  defp example(name) do
    [_, _fence, body] =
      Regex.run(~r/^(`{3,})markdown #{name}\n(.*?)^\1$/ms, File.read!(@guide))

    body
  end

  # Relate the spec as `suggest --accept` would, apply `edit`, and derive the status.
  defp after_edit(root, spec, edit) do
    path = Path.join(root, "spec.md")
    File.write!(path, spec)
    profile = Config.profile!([sources: ["spec.md"]], "Wren")
    scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(@items)

    candidates = Suggest.candidates(profile, @items, scans, [], root)
    {:ok, proposed} = Suggest.accept(candidates, scans, [], @meta)
    # The process then validates them (§18); what dangles is what was validated.
    entries = Enum.map(proposed, &validated/1)

    edited = edit.(spec)
    assert edited != spec
    File.write!(path, edited)
    status = Status.derive(Markdown.records(root, ["spec.md"]) ++ Scan.code(@items), entries)
    {pairs(candidates), status}
  end

  defp validated(e),
    do:
      Surfex.Log.Entry.new!(
        at: e.at,
        op: e.op,
        type: e.type,
        parents: e.parents,
        ends: e.ends,
        basis: :review
      )

  defp pairs(candidates),
    do: candidates |> Enum.map(&{section(&1.spec.id), &1.code.id}) |> Enum.sort()

  defp section("spec.md#" <> path), do: path

  defp in_state(status, state) do
    # `implements` is undirected, so its ends are held sorted: code first.
    for %{state: ^state, relation: {:implements, {:code, c}, {:spec, s}}} <- status.relations,
        do: {section(s), c}
  end

  defp limit(spec), do: String.replace(spec, "at most 512 bytes", "at most 1024 bytes")

  test "before: suggest relates the one section to all four names, and a one-word edit dangles all four",
       %{tmp_dir: root} do
    {pairs, status} = after_edit(root, example("wren-before"), &limit/1)

    assert pairs == [
             {"Messaging", "Wren.Queue"},
             {"Messaging", "Wren.max_len/0"},
             {"Messaging", "Wren.recv/1"},
             {"Messaging", "Wren.send/3"}
           ]

    assert Enum.sort(in_state(status, :dangling)) == pairs
  end

  test "after: the same edit dangles only the two relations of Limits", %{tmp_dir: root} do
    {pairs, status} = after_edit(root, example("wren-after"), &limit/1)

    assert pairs == [
             {"Messaging", "Wren.Queue"},
             {"Messaging/Limits", "Wren.max_len/0"},
             {"Messaging/Limits", "Wren.send/3"},
             {"Messaging/Receiving", "Wren.recv/1"},
             {"Messaging/Sending", "Wren.send/3"}
           ]

    assert Enum.sort(in_state(status, :dangling)) == [
             {"Messaging/Limits", "Wren.max_len/0"},
             {"Messaging/Limits", "Wren.send/3"}
           ]

    assert length(in_state(status, :current)) == 3
  end

  test "after: reflowing a paragraph dangles nothing", %{tmp_dir: root} do
    reflow = fn spec ->
      spec
      |> String.replace("takes the next message, in", "takes   the next\nmessage, in")
      |> String.replace("queues a message for a peer.", "queues a message\n\nfor a peer.")
    end

    assert reflow.(example("wren-after")) =~ "takes   the next\nmessage"
    {_pairs, status} = after_edit(root, example("wren-after"), reflow)

    assert Enum.all?(status.relations, &(&1.state == :current))
  end

  test "after: renaming Limits keeps its version but orphans its two relations",
       %{tmp_dir: root} do
    spec = example("wren-after")
    {_pairs, status} = after_edit(root, spec, &String.replace(&1, "## Limits", "## Size limits"))

    assert Enum.sort(in_state(status, :orphaned)) == [
             {"Messaging/Limits", "Wren.max_len/0"},
             {"Messaging/Limits", "Wren.send/3"}
           ]

    versions = fn text -> text |> Markdown.sections("spec.md") |> Map.new(&{&1.id, &1.hash}) end

    assert versions.(spec)["spec.md#Messaging/Limits"] ==
             versions.(String.replace(spec, "## Limits", "## Size limits"))[
               "spec.md#Messaging/Size limits"
             ]
  end

  test "after: suggest proposes moving Limits' relations when its heading is renamed",
       %{tmp_dir: root} do
    spec = example("wren-after")
    {_pairs, status} = after_edit(root, spec, &String.replace(&1, "## Limits", "## Size limits"))
    profile = Config.profile!([sources: ["spec.md"]], "Wren")
    scans = Markdown.records(root, ["spec.md"]) ++ Scan.code(@items)
    entries = Enum.flat_map(status.relations, & &1.tips)
    suggestions = Suggest.all(profile, @items, scans, entries, root)

    assert [%{from: "spec.md#Messaging/Limits", to: %{id: "spec.md#Messaging/Size limits"}}] =
             suggestions.moves
  end

  # §2's marked block and §6's test hint: each is its own unit, left out of its section.
  test "a marked block and a test hint change only their own versions" do
    block = example("wren-block")
    units = fn text -> text |> Markdown.sections("spec.md") |> Map.new(&{&1.id, &1.hash}) end

    changed = fn text, from, to ->
      before = units.(text)
      edited = units.(String.replace(text, from, to))
      for {id, hash} <- before, edited[id] != hash, do: id
    end

    assert Map.keys(units.(block)) |> Enum.sort() == ["spec.md#limits", "spec.md#max-len"]
    assert changed.(block, "exhaust memory", "run out of memory") == ["spec.md#limits"]
    assert changed.(block, "at most 512 bytes", "at most 1024 bytes") == ["spec.md#max-len"]

    hint = "## Limits {#limits}\n\nBounded.\n\n" <> example("wren-hint")
    assert Map.keys(units.(hint)) |> Enum.sort() == ["spec.md#limits", "spec.md#max-len-test"]
    assert changed.(hint, "513-byte", "514-byte") == ["spec.md#max-len-test"]
  end
end
