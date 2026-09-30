defmodule Surfex.ChangeTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Change, Scan, Status}
  alias Surfex.Status.Config
  alias Surfex.Log.Entry

  @unit "spec.md#Carts"

  defp scan(kind, id, hash, lines \\ {1, 1}, file \\ "f"),
    do: %Scan{kind: kind, id: id, hash: hash, location: %{file: file, lines: lines}}

  defp rel(type, {ak, a, ah}, {bk, b, bh}, basis \\ :review),
    do:
      Entry.new!(
        at: "2026-09-28T10:00:00Z",
        op: :relate,
        type: type,
        basis: if(type in [:implements, :verifies], do: basis),
        ends: [%{kind: ak, id: a, hash: ah}, %{kind: bk, id: b, hash: bh}]
      )

  defp mark,
    do:
      Entry.new!(
        at: "2026-09-28T11:00:00Z",
        op: :mark,
        type: :needs_update,
        ends: [%{kind: :spec, id: @unit, hash: "s1"}],
        note: "carts forget their lines on reload",
        by: "Tester"
      )

  # A spec file with the unit's text, a section, its code and a test that closes the
  # triangle; `extra` adds scans and `entries` more entries.
  defp world(root, extra \\ [], entries \\ []) do
    File.write!(Path.join(root, "spec.md"), "# Carts\n\nA cart keeps its lines.\n")

    scans =
      [
        scan(:spec, @unit, "s1", {1, 3}, "spec.md"),
        scan(:code, "M.add/2", "c1", {3, 5}, "lib/m.ex"),
        scan(:test, "T: keeps lines", "t1", {7, 9}, "test/m_test.exs")
      ] ++ extra

    base = [
      rel(:implements, {:spec, @unit, "s1"}, {:code, "M.add/2", "c1"}),
      rel(:verifies, {:test, "T: keeps lines", "t1"}, {:spec, @unit, "s1"}),
      rel(:tests, {:test, "T: keeps lines", "t1"}, {:code, "M.add/2", "c1"})
    ]

    scans
    |> Status.derive(base ++ entries, code: [:implements])
    |> Map.put(:triangle, [])
  end

  describe "drafts" do
    @describetag verifies: "change-drafts"

    test "an open mark: its note, the unit's text, the tests and code it touches, the steps",
         %{tmp_dir: root} do
      [draft] = Change.drafts(world(root, [], [mark()]), root, [])

      assert %Change{source: :mark, id: @unit} = draft
      assert draft.title == "Spec needs an update: spec.md#Carts"
      assert draft.problem =~ "carts forget their lines on reload"
      assert draft.problem =~ "Tester, 2026-09-28T11:00:00Z"

      assert [%{id: @unit, location: "spec.md:1-3", text: "# Carts\n\nA cart keeps its lines."}] =
               draft.units

      assert [%{id: "T: keeps lines", location: "test/m_test.exs:7-9", state: :current}] =
               draft.tests

      assert [%{id: "M.add/2", location: "lib/m.ex:3-5", state: :current}] = draft.code
      assert hd(draft.steps) =~ "Rewrite the spec unit"
      assert Enum.any?(draft.steps, &(&1 =~ "failing test"))
    end

    test "an unmet id and a triangle gap each make a draft", %{tmp_dir: root} do
      status = world(root, [scan(:code, "M.other/0", "o1", {8, 8}, "lib/m.ex")])
      gap = %{spec: @unit, gap: :no_test, test: nil, code: nil}
      drafts = Change.drafts(%{status | triangle: [gap]}, root, [])

      assert [
               %Change{source: :unmet, id: "M.other/0", title: unmet},
               %Change{source: :gap, id: @unit, title: gap_title}
             ] = drafts

      assert unmet == "Unmet: code M.other/0 needs implements"
      assert gap_title == "Triangle gap: spec.md#Carts has no verifying test"
    end

    test "named ids: a marked unit's marks, or a draft to change the item", %{tmp_dir: root} do
      status = world(root, [], [mark()])
      assert [%Change{source: :mark}] = Change.drafts(status, root, [@unit])

      assert [%Change{source: :item, id: "M.add/2", title: "Change to code M.add/2"} = item] =
               Change.drafts(status, root, ["M.add/2"])

      assert [%{id: @unit, state: :current}] = item.units
      assert [%{id: "T: keeps lines"}] = item.tests

      assert_raise ArgumentError, ~r/M.gone\/0 is not scanned/, fn ->
        Change.drafts(status, root, ["M.gone/0"])
      end
    end

    test "markdown for a person, JSON for tools", %{tmp_dir: root} do
      [draft] = Change.drafts(world(root, [], [mark()]), root, [])
      md = Change.markdown(draft)

      assert md =~ "# Spec needs an update: spec.md#Carts\n"
      assert md =~ "## Problem\n\ncarts forget their lines on reload"
      assert md =~ "## Touches\n"
      assert md =~ "- spec `spec.md#Carts` (spec.md:1-3)"
      assert md =~ "> A cart keeps its lines."
      assert md =~ "- test `T: keeps lines` (test/m_test.exs:7-9): current"
      assert md =~ "## Steps\n\n1. Rewrite the spec unit"

      {json, :ok, _} = [draft] |> Change.json() |> :json.decode(:ok, %{null: nil})

      assert [
               %{
                 "title" => "Spec needs an update: spec.md#Carts",
                 "source" => "mark",
                 "id" => @unit,
                 "units" => [%{"id" => @unit, "text" => _}],
                 "tests" => [%{"id" => "T: keeps lines", "state" => "current"}],
                 "code" => [%{"id" => "M.add/2"}],
                 "steps" => [_ | _]
               }
             ] = json
    end
  end

  describe "hand-off" do
    # A stand-in for a tracker's CLI: it records its argv and the file it was given.
    defp recorder(root, halt \\ 0) do
      script = Path.join(root, "record.exs")

      File.write!(script, """
      [title, file, body] = System.argv()
      out = Path.join(Path.dirname(__ENV__.file), "calls.txt")
      File.write!(out, [title, "\\n", File.read!(file), "\\n---\\n", body, "\\n===\\n"], [:append])
      IO.puts("filed " <> title)
      if #{halt} != 0, do: (IO.puts("tracker refused"); System.halt(#{halt}))
      """)

      {:command, ["elixir", script, "{title}", "{file}", "{body}"]}
    end

    @tag verifies: "change-hand-off"
    test ":print gives each draft's markdown", %{tmp_dir: root} do
      [draft] = Change.drafts(world(root, [], [mark()]), root, [])
      assert {:ok, [md]} = Change.hand_off([draft], :print, root)
      assert md == Change.markdown(draft)
    end

    @tag verifies: "change-hand-off"
    test "a command runs once per draft, with {title}, {file} and {body} substituted", %{
      tmp_dir: root
    } do
      status = world(root, [scan(:code, "M.other/0", "o1")], [mark()])
      drafts = Change.drafts(status, root, [])
      assert length(drafts) == 2

      assert {:ok, outputs} = Change.hand_off(drafts, recorder(root), root)
      assert Enum.map(outputs, &String.trim/1) == Enum.map(drafts, &("filed " <> &1.title))

      calls = File.read!(Path.join(root, "calls.txt"))
      [first | _] = String.split(calls, "\n===\n", trim: true)
      [title, rest] = String.split(first, "\n", parts: 2)
      [file_text, body] = String.split(rest, "\n---\n")
      assert title == hd(drafts).title
      assert file_text == Change.markdown(hd(drafts))
      assert body == Change.markdown(hd(drafts))
    end

    @tag verifies: "change-hand-off"
    test "a failing command stops the hand-off, with its output", %{tmp_dir: root} do
      [draft] = Change.drafts(world(root, [], [mark()]), root, [])
      assert {:error, message} = Change.hand_off([draft, draft], recorder(root, 3), root)
      assert message =~ "exited with 3"
      assert message =~ "tracker refused"
      # It stopped at the first.
      assert length(String.split(File.read!(Path.join(root, "calls.txt")), "===")) == 2
    end

    @tag verifies: "status-config-read"
    test "process: is :print by default, or {:command, argv}, and nothing else" do
      assert Config.process!([]) == :print

      assert Config.process!(process: {:command, ["glab", "{title}"]}) ==
               {:command, ["glab", "{title}"]}

      for bad <- [:mail, {:command, []}, {:command, "glab"}, {:command, [:glab]}] do
        assert_raise ArgumentError, ~r/process: must be :print or \{:command, argv\}/, fn ->
          Config.process!(process: bad)
        end
      end
    end
  end
end
