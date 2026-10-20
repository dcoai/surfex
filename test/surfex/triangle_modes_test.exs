defmodule Surfex.TriangleModesTest do
  # #327 (for #326): `triangle:` takes a mode per spec file, so a project can close its
  # triangle chapter by chapter (§13.17).
  use ExUnit.Case, async: true

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Status.{Config, Report}

  @keys "spec/03-keys.md#keys"
  @run "spec/06-the-run.md#run"

  defp tm_scan(kind, id, file),
    do: %Scan{kind: kind, id: id, hash: "h", location: %{file: file, lines: {1, 2}}}

  defp tm_relate(type, {ak, a}, {bk, b}),
    do:
      Entry.new!(
        at: "2026-10-19T10:00:00Z",
        op: :relate,
        type: type,
        ends: [%{kind: ak, id: a, hash: "h"}, %{kind: bk, id: b, hash: "h"}]
      )

  # Two chapters, each with a unit something implements and no test verifies: one gap in
  # each file. `closed:` gives the keys chapter its test, closing its triangle.
  defp tm_status(triangle, closed \\ false) do
    scans = [
      tm_scan(:spec, @keys, "spec/03-keys.md"),
      tm_scan(:spec, @run, "spec/06-the-run.md"),
      tm_scan(:code, "M.keys/0", "lib/m.ex"),
      tm_scan(:code, "M.run/0", "lib/m.ex"),
      %{
        tm_scan(:test, "T: keys", "test/m_test.exs")
        | calls: ["M.keys/0"],
          declares: if(closed, do: [{:verifies, @keys}], else: [])
      }
    ]

    entries =
      [
        tm_relate(:implements, {:code, "M.keys/0"}, {:spec, @keys}),
        tm_relate(:implements, {:code, "M.run/0"}, {:spec, @run})
      ] ++
        if(closed, do: [tm_relate(:verifies, {:test, "T: keys"}, {:spec, @keys})], else: [])

    Status.derive(scans, entries, [], triangle: triangle)
  end

  defp tm_modes(status), do: Map.new(status.triangle, &{&1.spec, {&1.file, &1.mode}})

  @tag verifies: ["triangle-file-modes", "triangle-modes"]
  test "a gap in a fail: file fails, one elsewhere is reported; report: is the mirror" do
    for setting <- [
          [default: :report, fail: ["spec/03-*.md"]],
          [fail: ["spec/03-*.md"], default: :report],
          [default: :fail, report: ["spec/06-*.md"]]
        ] do
      open = tm_status(setting)

      assert tm_modes(open) == %{
               @keys => {"spec/03-keys.md", :fail},
               @run => {"spec/06-the-run.md", :report}
             }

      assert Status.failing?(open)

      # The keys chapter closed: what is left is reported, and the check passes.
      closed = tm_status(setting, true)
      assert [%{spec: @run, mode: :report}] = closed.triangle
      refute Status.failing?(closed)
    end

    # The resolved form is kept, `default:` first.
    assert tm_status(fail: ["spec/03-*.md"], default: :report).policy.triangle ==
             [default: :report, fail: ["spec/03-*.md"]]
  end

  @tag verifies: ["triangle-file-modes", "triangle-modes"]
  test "the plain :report and :fail forms are unchanged: every gap takes the one mode" do
    report = tm_status(:report)
    assert Enum.all?(report.triangle, &(&1.mode == :report)) and length(report.triangle) == 2
    refute Status.failing?(report)
    assert report.policy.triangle == :report

    failing = tm_status(:fail)
    assert Enum.all?(failing.triangle, &(&1.mode == :fail))
    assert Status.failing?(failing)
    assert Status.failing?(tm_status(:fail, true))
  end

  @tag verifies: ["triangle-file-modes", "triangle-modes"]
  test "the status lists the gaps by file with each file's mode, after the counts" do
    status = tm_status(default: :report, fail: ["spec/03-*.md"])
    text = Report.text(status)

    assert text =~
             """
             Triangle (a spec unit, its tests and its code don't meet): 1 failing (in fail files), 1 reported
               spec/03-keys.md (fail):
                 spec #{@keys}: no test verifies it
               spec/06-the-run.md (report):
                 spec #{@run}: no test verifies it
             """

    {json, :ok, _} = status |> Report.json() |> :json.decode(:ok, %{null: nil})

    assert [
             %{"spec" => @keys, "file" => "spec/03-keys.md", "mode" => "fail"},
             %{"spec" => @run, "file" => "spec/06-the-run.md", "mode" => "report"}
           ] = json["triangle"]
  end

  @tag verifies: ["triangle-file-refused", "triangle-modes"]
  test "any other shape is refused, in .surfex.exs and by derive alike" do
    for bad <- [
          [default: :report, fail: ["a"], report: ["b"]],
          [default: :report, report: ["a"]],
          [default: :report, other: ["a"]],
          [fail: ["a"]],
          [default: :maybe, fail: ["a"]],
          [default: :report, fail: "spec/*.md"],
          [default: :report, fail: [:a]],
          :maybe
        ] do
      assert [refusal] = Config.Keys.refusals(triangle: bad)
      assert refusal =~ "triangle: must be :report, :fail, [default: :report, fail: [glob, …]]"

      assert_raise ArgumentError, ~r/^triangle: must be :report, :fail, \[default: :report/, fn ->
        tm_status(bad)
      end
    end
  end

  @moduletag :tmp_dir

  @tag verifies: ["triangle-file-refused", "triangle-modes"]
  test "a glob matching no spec file is refused, naming it", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "spec"))
    File.write!(Path.join(root, "spec/03-keys.md"), "# 3. Keys\n\nKeys are read.\n")
    config = [sources: ["spec/*.md"], namespace: "MyLib"]

    assert {:ok, _} =
             Config.read_spec(
               config ++ [triangle: [default: :report, fail: ["spec/03-*.md"]]],
               root,
               nil
             )

    error =
      assert_raise ArgumentError, fn ->
        Config.read_spec(
          config ++ [triangle: [default: :report, fail: ["spec/03-*.md", "spec/04-*.md"]]],
          root,
          nil
        )
      end

    assert error.message == ~s{triangle: "spec/04-*.md" matches no spec file}

    assert Config.triangle!([triangle: [default: :fail, report: ["spec/*.md"]]], [
             "spec/03-keys.md"
           ]) == :ok
  end
end
