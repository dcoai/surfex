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

  # #386: the chain hash comes from check/1's own decode, so a line that fails it must still
  # chain by the id it carries, or every edit would also be reported as a broken chain.
  test "an edited line in a closed segment is reported once, and its segment still chains",
       %{tmp_dir: root} do
    Log.init(root)
    Log.append(root, [entry(1), entry(2)])
    Log.break(root)
    Log.append(root, [entry(3)])

    path = Path.join(Log.dir(root), "surfex_1.log")
    File.write!(path, String.replace(File.read!(path), ~s("M.f/1"), ~s("M.f/9")))

    {entries, problems} = Log.check(root)
    assert problems == Log.verify(root)
    assert [problem] = problems
    assert problem =~ ~r/^surfex_1\.log:\d+: entry .* does not match its content/
    assert length(entries) == 2
  end

  # #387: the chain hashed every line's "id" as read from JSON, so a line that is JSON but no
  # entry raised a KeyError (or BadMapError) out of verify/1 instead of being reported.
  describe "a JSON line that is no entry" do
    @describetag verifies: "log-non-entry"

    # Two segments, the closed one returned, so its successor's header checks its hash.
    defp two_segments(root) do
      Log.init(root)
      Log.append(root, [entry(1), entry(2)])
      Log.break(root)
      Log.append(root, [entry(3)])
      Path.join(Log.dir(root), "surfex_1.log")
    end

    test "no id, a non-string id, a list or a number is reported with its line, and its segment still chains",
         %{tmp_dir: tmp} do
      for {kind, line} <- [
            no_id: ~s({"foo":1}),
            integer_id: ~s({"id":7,"op":"relate"}),
            list: ~s([1,2]),
            number: ~s(5)
          ] do
        root = Path.join(tmp, Atom.to_string(kind))
        closed = two_segments(root)
        File.write!(closed, File.read!(closed) <> line <> "\n")

        {entries, problems} = Log.check(root)
        assert problems == Log.verify(root), "#{kind}"
        assert [problem] = problems, "#{kind}: #{inspect(problems)}"
        assert problem =~ ~r/^surfex_1\.log:\d+: not a log entry: /, "#{kind}"
        assert length(entries) == 3, "#{kind}"
      end
    end

    test "break and rechain hash past it, and verify lists only the line", %{tmp_dir: root} do
      closed = two_segments(root)
      File.write!(closed, File.read!(closed) <> ~s({"foo":1}) <> "\n")
      open = Path.join(Log.dir(root), "surfex.log")
      File.write!(open, File.read!(open) <> ~s([1]) <> "\n")

      Log.rechain(root)
      Log.break(root)
      Log.append(root, [entry(4)])

      assert [a, b] = Log.verify(root)
      assert a =~ ~r/^surfex_1\.log:\d+: not a log entry: \{"foo":1\}/
      assert b =~ ~r/^surfex_2\.log:\d+: not a log entry: \[1\]/
    end
  end
end
