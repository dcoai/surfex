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

  defp world(root) do
    File.write!(Path.join(root, "spec.md"), @spec_md)

    Markdown.records(root, ["spec.md"]) ++
      [
        code("M", [], %{role: :module, hidden: %{"M.handle_call/3" => ["M.helper/1"]}}),
        code("M.entry/1", ["M.a/0", "M.b/0", "M"]),
        code("M.a/0"),
        code("M.b/0"),
        code("M.direct/0"),
        code("M.helper/1"),
        test_scan("T: adds", ["add"], ["M", "M.direct/0", "M.entry/1"]),
        test_scan("T: replies", ["reply"], ["M.handle_call/3"]),
        test_scan("T: untagged", [], ["M.b/0"])
      ]
  end

  defp suggest(root, entries, claims? \\ true) do
    scans = world(root)
    profile = Config.profile!([sources: ["spec.md"]], "M")
    {Suggest.all(profile, [], scans, entries, root, claims: claims?), scans}
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
  test "no verifying test, no proposal; the section gets none; off by default", %{
    tmp_dir: root
  } do
    {s, _} = suggest(root, [])
    refute Enum.any?(s.implements, &(&1.spec.id in ["spec.md#lone", "spec.md#carts"]))

    {off, _} = suggest(root, [], false)
    assert off.implements == [] and off.reached == []
    assert Config.claim_implements?([]) == false
    assert Config.claim_implements?(claim_implements: true)

    assert_raise ArgumentError, ~r/claim_implements: must be true or false/, fn ->
      Config.claim_implements?(claim_implements: :yes)
    end
  end

  test "a declined pair isn't proposed again, and accepting records the rest as proposed", %{
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

    {:ok, recorded} = Suggest.accept_all(s, scans, [declined], @meta)
    implements = Enum.filter(recorded, &(&1.type == :implements))
    assert length(implements) == 2
    assert Enum.all?(implements, &(&1.basis == :proposed))

    status = Status.derive(scans, [declined | recorded])
    assert Enum.count(status.relations, &(&1.type == :implements and &1.state == :proposed)) == 2
  end
end
