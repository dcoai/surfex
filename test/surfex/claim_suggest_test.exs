defmodule Surfex.ClaimSuggestTest do
  # #206 (B.2), #244: a claim's implements are proposed from what its verifying tests call
  # directly; code reached only through other code gets one line per entry, and the
  # section gets nothing (the direct-call rule, decided at evaluation, §15.1).
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "claim-suggestions"

  alias Surfex.{Scan, Status, Suggest}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  @meta [by: "tester", at: "2026-10-14T10:00:00Z"]

  @spec_md """
  # Carts
  <!-- surfex: carts -->

  Carts hold items.

  ```test:add
  adding an item puts it in the cart
  ```

  ```test:reply
  the stock server replies with the level
  ```

  ```test:lone
  nothing verifies this yet
  ```
  """

  defp code(id, calls \\ [], extra \\ %{}),
    do:
      struct!(
        %Scan{kind: :code, id: id, hash: "h", location: %{file: "lib/m.ex", lines: {1, 1}}},
        Map.merge(%{role: :function, calls: calls}, extra)
      )

  defp test_scan(id, declares, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t",
      location: %{file: "test/m_test.exs", lines: {1, 1}},
      declares: Enum.map(declares, &{:verifies, &1}),
      calls: calls
    }

  @default_tests [
    {"T: adds", ["add"], ["M", "M.direct/0", "M.entry/1"]},
    {"T: replies", ["reply"], ["M.handle_call/3"]},
    {"T: untagged", [], ["M.b/0"]}
  ]

  defp world(root, tests) do
    File.write!(Path.join(root, "spec.md"), @spec_md)

    Markdown.records(root, ["spec.md"]) ++
      [
        code("M", [], %{role: :module, hidden: %{"M.handle_call/3" => ["M.helper/1"]}}),
        code("M.entry/1", ["M.a/0", "M.b/0", "M"]),
        code("M.a/0"),
        code("M.b/0"),
        code("M.direct/0"),
        code("M.helper/1")
      ] ++ for({id, declares, calls} <- tests, do: test_scan(id, declares, calls))
  end

  defp suggest(root, entries, tests \\ @default_tests) do
    scans = world(root, tests)
    profile = Config.profile!([sources: ["spec.md"]], "M")
    {Suggest.all(profile, [], scans, entries, root), scans}
  end

  defp pairs(s), do: s.implements |> Enum.map(&{&1.spec.id, &1.code.id}) |> Enum.sort()

  @tag verifies: ["claim-suggestions", "claim-implements"]
  test "a claim's tests' direct calls are proposed, a hidden callback as its module", %{
    tmp_dir: root
  } do
    {s, _} = suggest(root, [])

    assert pairs(s) == [
             {"spec.md#add", "M.direct/0"},
             {"spec.md#add", "M.entry/1"},
             {"spec.md#reply", "M"}
           ]

    assert %{tests: ["T: adds"], cited_at: nil} =
             Enum.find(s.implements, &(&1.code.id == "M.entry/1"))
  end

  @tag verifies: ["claim-suggestions", "claim-implements"]
  test "code reached only through other code gets one line, never a list", %{tmp_dir: root} do
    {s, _} = suggest(root, [])

    assert s.reached == [
             %{spec: "spec.md#add", through: "M.entry/1", count: 2},
             %{spec: "spec.md#reply", through: "M.handle_call/3", count: 1}
           ]

    refute Enum.any?(s.implements, &(&1.code.id in ["M.a/0", "M.b/0", "M.helper/1"]))
  end

  @tag verifies: ["claim-suggestions", "claim-implements"]
  test "no verifying test, no proposal; the section gets none", %{tmp_dir: root} do
    {s, _} = suggest(root, [])
    refute Enum.any?(s.implements, &(&1.spec.id in ["spec.md#lone", "spec.md#carts"]))
  end

  @tag verifies: ["claim-suggestions", "accept-skips-claim-candidates"]
  test "a declined pair isn't proposed again, and accepting records none of the rest", %{
    tmp_dir: root
  } do
    {_, scans} = suggest(root, [])
    spec = Enum.find(scans, &(&1.id == "spec.md#add"))
    direct = Enum.find(scans, &(&1.id == "M.direct/0"))

    declined =
      Entry.new!(
        at: "2026-10-14T09:00:00Z",
        op: :retire,
        type: :implements,
        note: "a fixture, not the claim's code",
        ends: [
          %{kind: :spec, id: spec.id, hash: spec.hash},
          %{kind: :code, id: direct.id, hash: direct.hash}
        ]
      )

    {s, scans} = suggest(root, [declined])
    refute {"spec.md#add", "M.direct/0"} in pairs(s)
    assert Suggest.decline_command(:implements, "spec.md#add", "M.entry/1") =~ "mix surfex.retire"

    assert Enum.all?(s.implements, &Suggest.claim_derived?/1)

    {:ok, recorded} = Suggest.accept_all(s, scans, [declined], @meta)
    assert Enum.filter(recorded, &(&1.type == :implements)) == []
    assert Enum.any?(recorded, &(&1.type == :refines))
    assert Enum.any?(recorded, &(&1.type == :tests))

    status = Status.derive(scans, [declined | recorded])
    assert Enum.count(status.relations, &(&1.type == :implements and &1.state == :proposed)) == 0
  end

  defp claim_relate(scans, entries, spec, code) do
    {:ok, recorded} =
      Surfex.Record.relate(scans, entries, "spec:" <> spec, "code:" <> code, :implements, @meta)

    entries ++ recorded
  end

  @tag verifies: ["claim-candidates-unimplemented", "claim-implements"]
  test "a hint in a section that implements code proposes nothing; without it, its calls", %{
    tmp_dir: root
  } do
    {s, scans} = suggest(root, [])
    assert {"spec.md#add", "M.entry/1"} in pairs(s)

    held = claim_relate(scans, [], "spec.md#carts", "M.a/0")
    {s, _} = suggest(root, held)
    assert pairs(s) == []
    assert s.reached == []

    # Retired, the section's implements no longer holds its hints back.
    {:ok, retired} =
      Surfex.Record.retire(
        scans,
        held,
        "spec:spec.md#carts",
        "code:M.a/0",
        :implements,
        Keyword.put(@meta, :note, "not the carts' code")
      )

    {s, _} = suggest(root, held ++ retired)
    assert {"spec.md#add", "M.entry/1"} in pairs(s)
  end

  @tag verifies: ["claim-candidates-unimplemented", "claim-implements"]
  test "a claim with its own live implements proposes nothing claim-derived", %{tmp_dir: root} do
    {_, scans} = suggest(root, [])
    {s, _} = suggest(root, claim_relate(scans, [], "spec.md#add", "M.a/0"))
    assert pairs(s) == [{"spec.md#reply", "M"}]
  end

  @tag verifies: ["claim-candidates-specific", "claim-implements"]
  test "a call other claims' tests also make is counted, not proposed", %{tmp_dir: root} do
    tests = [
      {"T: adds", ["add"], ["M.direct/0", "M.entry/1"]},
      {"T: replies", ["reply"], ["M.handle_call/3", "M.direct/0"]},
      {"T: lone", ["lone"], ["M.direct/0"]}
    ]

    {s, _} = suggest(root, [], tests)

    # M.direct/0 is called by all three claims' tests: shared 2. It is lone's only call.
    assert pairs(s) == [
             {"spec.md#add", "M.entry/1"},
             {"spec.md#lone", "M.direct/0"},
             {"spec.md#reply", "M"}
           ]

    assert %{shared: 0} = Enum.find(s.implements, &(&1.code.id == "M.entry/1"))
    assert %{shared: 2} = Enum.find(s.implements, &(&1.code.id == "M.direct/0"))

    assert s.also_called == [
             %{spec: "spec.md#add", count: 1},
             %{spec: "spec.md#reply", count: 1}
           ]

    json = JSON.decode!(Suggest.json(s))

    assert %{"shared" => 2, "accept" => false, "cited_at" => nil, "tests" => ["T: lone"]} =
             Enum.find(json["implements"], &(&1["code"] == "M.direct/0"))

    assert json["also_called"] == [
             %{"spec" => "spec.md#add", "count" => 1},
             %{"spec" => "spec.md#reply", "count" => 1}
           ]
  end
end
