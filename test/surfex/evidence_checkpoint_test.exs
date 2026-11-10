defmodule Surfex.EvidenceCheckpointTest do
  # #398, #400: every --evidence command decoded the whole evidence file, though it only
  # grows between runs. Counting decoded lines is global, so this module runs alone.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "evidence-checkpoint"

  alias Surfex.Evidence

  @decode_mfa {Surfex.Evidence, :decode, 1}

  # A run's records, one per test, each test's code map shared by its runs.
  defp run(n, tests \\ 40) do
    for t <- 1..tests do
      %{
        test: "T: #{t}",
        test_hash: "t#{t}",
        result: if(rem(t + n, 9) == 0, do: :failed, else: :passed),
        at: "2026-11-10T10:#{String.pad_leading("#{n}", 2, "0")}:00Z",
        run: "r#{n}",
        seq: t,
        code: %{"M.f/1" => "c#{rem(t, 4)}", "M.g/0" => "g#{rem(n, 3)}"}
      }
    end
  end

  defp project(root) do
    File.mkdir_p!(Path.join(root, ".surfex"))
    root
  end

  defp checkpoint(root), do: Path.join([root, ".surfex", "cache", "evidence.checkpoint"])

  # How many lines `fun` decodes, and what it gives.
  defp decoded(fun) do
    :erlang.trace_pattern(@decode_mfa, true, [:local, :call_count])
    result = fun.()
    {:call_count, n} = :erlang.trace_info(@decode_mfa, :call_count)
    :erlang.trace_pattern(@decode_mfa, false, [:local, :call_count])
    {n, result}
  end

  test "a warm read gives what load/1 gives, decoding only the lines appended", %{tmp_dir: tmp} do
    root = project(tmp)
    path = Evidence.path(root)
    Evidence.append(path, Enum.flat_map(1..20, &run/1))

    {cold, records} = decoded(fn -> Evidence.project(root) end)
    assert cold == 800
    assert records == Evidence.load(path)
    assert File.exists?(checkpoint(root))

    assert {0, ^records} = decoded(fn -> Evidence.project(root) end)

    # A small append is decoded after the checkpoint, which isn't rewritten for it.
    before = File.read!(checkpoint(root))
    Evidence.append(path, run(21))
    {warm, records} = decoded(fn -> Evidence.project(root) end)
    assert warm == 40
    assert records == Evidence.load(path)
    assert File.read!(checkpoint(root)) == before

    # Past an eighth of what it covers, it is rewritten to cover the whole file.
    Evidence.append(path, Enum.flat_map(22..25, &run/1))
    {warm, records} = decoded(fn -> Evidence.project(root) end)
    assert warm == 200
    assert records == Evidence.load(path)
    assert {0, ^records} = decoded(fn -> Evidence.project(root) end)
  end

  test "records appended out of time order, or in the same second, sort as load/1 sorts them",
       %{tmp_dir: tmp} do
    root = project(tmp)
    path = Evidence.path(root)
    Evidence.append(path, Enum.flat_map(10..20, &run/1))
    Evidence.project(root)

    # A CI job's run from earlier, and a second copy of the last run's records.
    Evidence.append(path, run(5) ++ run(20, 3))
    assert Evidence.project(root) == Evidence.load(path)
  end

  test "a file that no longer starts with the bytes it covered is decoded in full", %{
    tmp_dir: tmp
  } do
    root = project(tmp)
    path = Evidence.path(root)
    Evidence.append(path, Enum.flat_map(1..10, &run/1))
    Evidence.project(root)

    # Rewritten to the same length, with a different first record.
    content = File.read!(path)
    File.write!(path, String.replace(content, ~s("run":"r1"), ~s("run":"q1"), global: false))
    {n, records} = decoded(fn -> Evidence.project(root) end)
    assert n == 400
    assert records == Evidence.load(path)

    # Truncated: shorter than what the checkpoint covered.
    Evidence.project(root)
    [first | _] = String.split(File.read!(path), "\n")
    File.write!(path, first <> "\n")
    assert Evidence.project(root) == Evidence.load(path)
    assert length(Evidence.project(root)) == 1

    # Mix clean: no file, no evidence.
    File.rm!(path)
    assert Evidence.project(root) == []
  end

  test "a damaged checkpoint is not used, and no checkpoint is written without a log", %{
    tmp_dir: tmp
  } do
    root = project(tmp)
    path = Evidence.path(root)
    Evidence.append(path, Enum.flat_map(1..10, &run/1))
    Evidence.project(root)

    File.write!(checkpoint(root), binary_part(File.read!(checkpoint(root)), 0, 200))
    {n, records} = decoded(fn -> Evidence.project(root) end)
    assert n == 400
    assert records == Evidence.load(path)

    bare = Path.join(tmp, "bare")
    Evidence.append(Evidence.path(bare), run(1))
    assert Evidence.project(bare) == Evidence.load(Evidence.path(bare))
    refute File.exists?(Path.join(bare, ".surfex"))
  end
end
