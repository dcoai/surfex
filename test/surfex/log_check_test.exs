defmodule Surfex.LogCheckTest do
  # #379, #380: --verify decoded every line, then the status decoded them all again.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "log-check-once"

  alias Surfex.Log
  alias Surfex.Log.Entry

  defp entry(n, parents \\ []),
    do:
      Entry.new!(
        at: "2026-11-09T10:00:0#{n}Z",
        op: :relate,
        type: :tests,
        parents: parents,
        ends: [
          %{kind: :test, id: "T: #{n}", hash: "t"},
          %{kind: :code, id: "M.f/#{n}", hash: "c"}
        ]
      )

  test "check/1 gives load/1's entries and verify/1's problems from one reading", %{tmp_dir: root} do
    Log.init(root)
    one = entry(1)
    Log.append(root, [entry(3), one, entry(2, [one.id])])

    assert Log.check(root) == {Log.load(root), Log.verify(root)}
    assert {_, []} = Log.check(root)
  end

  test "a tampered or orphaned log is reported by check/1 as by verify/1", %{tmp_dir: root} do
    Log.init(root)
    one = entry(1)
    Log.append(root, [one, entry(2, [one.id])])

    path = Path.join(Log.dir(root), "surfex.log")
    lines = path |> File.read!() |> String.split("\n", trim: true)
    edited = Enum.map(lines, &String.replace(&1, ~s("M.f/1"), ~s("M.f/9")))
    File.write!(path, Enum.join(edited, "\n") <> "\n")

    {entries, problems} = Log.check(root)
    assert problems == Log.verify(root)
    assert Enum.any?(problems, &(&1 =~ "does not match its content"))
    assert Enum.any?(problems, &(&1 =~ "which no segment has"))
    assert length(entries) == 1
  end
end
