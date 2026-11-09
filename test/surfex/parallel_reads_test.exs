defmodule Surfex.ParallelReadsTest do
  # #379, #381: reading in parallel must change nothing a reader can see.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "parallel-reads"

  alias Surfex.{Log, Scan}
  alias Surfex.Log.Entry

  defp entry(n),
    do:
      Entry.new!(
        at: "2026-11-09T10:00:00Z",
        op: :relate,
        type: :tests,
        ends: [
          %{kind: :test, id: "T: #{n}", hash: "t"},
          %{kind: :code, id: "M.f/#{n}", hash: "c"}
        ]
      )

  test "the log loads as reading its lines one at a time does, in the same order", %{
    tmp_dir: root
  } do
    Log.init(root)
    entries = for n <- Enum.shuffle(1..2_500), do: entry(n)
    Log.append(root, entries)

    one_at_a_time =
      Path.join(Log.dir(root), "surfex.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, ~s({"segment")))
      |> Enum.map(&Entry.decode!/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{&1.at, &1.id})

    assert Log.load(root) == one_at_a_time
    assert {^one_at_a_time, []} = Log.check(root)
  end

  test "an edited line raises on load as it would one at a time", %{tmp_dir: root} do
    Log.init(root)
    Log.append(root, for(n <- 1..1_200, do: entry(n)))
    path = Path.join(Log.dir(root), "surfex.log")
    File.write!(path, String.replace(File.read!(path), ~s("M.f/700"), ~s("M.f/7000")))

    {error, log} =
      ExUnit.CaptureLog.with_log(fn -> assert_raise ArgumentError, fn -> Log.load(root) end end)

    assert log == ""
    assert error.message =~ "does not match its content"
    assert [problem] = Log.verify(root)
    assert problem =~ "surfex.log:"
  end

  test "test files scan the same each time, and a file that doesn't parse raises naming it", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "test"))

    for n <- 1..20 do
      File.write!(Path.join(root, "test/t#{n}_test.exs"), """
      defmodule T#{n}Test do
        use ExUnit.Case
        test "one", do: assert(true)
        test "two", do: assert(true)
      end
      """)
    end

    first = Scan.ExUnit.read_files(root, ["test/*_test.exs"])
    assert first == Scan.ExUnit.read_files(root, ["test/*_test.exs"])
    {records, []} = first

    assert Enum.map(records, & &1.location.file) ==
             Enum.sort(Enum.map(records, & &1.location.file))

    File.write!(Path.join(root, "test/t13_test.exs"), "defmodule Broken do\n  def (\nend\n")

    {error, log} =
      ExUnit.CaptureLog.with_log(fn ->
        assert_raise MismatchedDelimiterError, fn ->
          Scan.ExUnit.read_files(root, ["test/*_test.exs"])
        end
      end)

    assert Exception.message(error) =~ "t13_test.exs"
    # The error is raised here, not by a task crashing, so nothing else is reported.
    assert log == ""
  end
end
