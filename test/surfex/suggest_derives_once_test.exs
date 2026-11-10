defmodule Surfex.SuggestDerivesOnceTest do
  # #390, #392: Suggest.all/5 derived the status of the same log twice when nothing moved.
  # Counting calls is global, so this module runs alone.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "suggest-derives-once"

  alias Surfex.{Item, Scan, Suggest}
  alias Surfex.Status.Config
  alias Surfex.Scan.Markdown

  @meta [by: "tester", at: "2026-11-10T10:00:00Z"]
  @wren [
    %Item{kind: :function, name: "send/3", parent: "Wren", file: "lib/w.ex", hash: "00000001"}
  ]
  @test_body "test \"t1\", do: assert(Wren.send(:a, :b, 1))"

  # How many times `fun` derives a status (every arity of Status.derive ends in derive/4),
  # and how many times it regroups the log for a relation's tips (Status.tips/2).
  @derive_mfa {Surfex.Status, :derive, 4}
  @tips_mfa {Surfex.Status, :tips, 2}

  defp counted(fun) do
    for mfa <- [@derive_mfa, @tips_mfa],
        do: :erlang.trace_pattern(mfa, true, [:local, :call_count])

    result = fun.()

    [derives, tips] =
      for mfa <- [@derive_mfa, @tips_mfa], do: elem(:erlang.trace_info(mfa, :call_count), 1)

    for mfa <- [@derive_mfa, @tips_mfa],
        do: :erlang.trace_pattern(mfa, false, [:local, :call_count])

    {%{derives: derives, tips: tips}, result}
  end

  defp scans(root, test_module) do
    File.write!(Path.join(root, "spec.md"), "# Sending\n\n`Wren.send/3` sends.\n")

    Markdown.records(root, ["spec.md"]) ++
      Scan.code(@wren) ++
      Scan.ExUnit.tests(
        "defmodule #{test_module} do\n  use ExUnit.Case\n  #{@test_body}\nend\n",
        "test/wren_test.exs"
      )
  end

  test "suggest derives once when nothing moves, and again after recording a move", %{
    tmp_dir: root
  } do
    profile = Config.profile!([sources: ["spec.md"]], "Wren")
    old = scans(root, "WrenTest")

    {:ok, entries} =
      Suggest.accept_all(Suggest.all(profile, @wren, old, [], root), old, [], @meta)

    {n, s} = counted(fn -> Suggest.all(profile, @wren, old, entries, root) end)
    assert s.moves == []
    assert n.derives == 1

    # The test's module renamed: one move, and the rest is suggested as the move leaves it.
    new = scans(root, "WrenOneTest")
    {n, s} = counted(fn -> Suggest.all(profile, @wren, new, entries, root) end)
    assert Enum.map(s.moves, &{&1.from, &1.to.id}) == [{"WrenTest: t1", "WrenOneTest: t1"}]
    assert s.tests == []
    assert n.derives == 2
  end

  # #391, #393: the judgements in force come from the status, never from regrouping the log.
  # (Recording a move reads tips itself, so this holds where nothing moves.)
  test "suggest reads each relation's judgement in force from its status", %{tmp_dir: root} do
    profile = Config.profile!([sources: ["spec.md"]], "Wren")
    scans = scans(root, "WrenTest")

    {:ok, entries} =
      Suggest.accept_all(Suggest.all(profile, @wren, scans, [], root), scans, [], @meta)

    {n, s} = counted(fn -> Suggest.all(profile, @wren, scans, entries, root) end)
    assert s.moves == []
    assert n.tips == 0
    # The accepted relations are judged, so nothing they hold is suggested again.
    assert s.implements == [] and s.verifies == [] and s.tests == []
  end
end
