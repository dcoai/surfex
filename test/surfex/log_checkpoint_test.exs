defmodule Surfex.LogCheckpointTest do
  # #382, #384: every command decoded every line of the log, though between two runs the
  # log only gains lines at its end.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "log-checkpoint"

  alias Surfex.Log
  alias Surfex.Log.Entry

  defp entry(n, parents \\ []),
    do:
      Entry.new!(
        at: "2026-11-09T10:00:#{String.pad_leading(to_string(n), 2, "0")}Z",
        op: :relate,
        type: :tests,
        parents: parents,
        ends: [
          %{kind: :test, id: "T: #{n}", hash: "t"},
          %{kind: :code, id: "M.f/#{n}", hash: "c"}
        ]
      )

  defp checkpoint(root), do: Path.join([root, ".surfex", "cache", "log.checkpoint"])
  defp open(root), do: Path.join([root, ".surfex", "surfex.log"])

  # What a load gives with no checkpoint at all.
  defp fresh(root) do
    File.rm_rf!(Path.join([root, ".surfex", "cache"]))
    Log.load(root)
  end

  setup %{tmp_dir: root} do
    Log.init(root)
    Log.append(root, Enum.map(1..40, &entry/1))
    :ok
  end

  test "a load makes a checkpoint, and a load from it gives what decoding every line does",
       %{tmp_dir: root} do
    cold = Log.load(root)
    assert File.exists?(checkpoint(root))
    assert Log.load(root) == cold
    assert cold == fresh(root)
  end

  test "lines appended after it are decoded and merged in order, without rewriting it",
       %{tmp_dir: root} do
    Log.load(root)
    made = File.read!(checkpoint(root))

    # Out of time order, and one a duplicate of a line it covers, as a union merge leaves.
    File.write!(open(root), [Entry.encode(entry(45)), "\n", Entry.encode(entry(3)), "\n"], [
      :append
    ])

    Log.append(root, [entry(41)])

    loaded = Log.load(root)
    assert File.read!(checkpoint(root)) == made
    assert loaded == fresh(root)

    assert Enum.map(loaded, & &1.id) ==
             Enum.map(Enum.map(1..41, &entry/1) ++ [entry(45)], & &1.id)
  end

  test "once the lines after it are many, it is rewritten to cover them", %{tmp_dir: root} do
    Log.load(root)
    made = File.read!(checkpoint(root))
    Log.append(root, Enum.map(41..59, &entry/1))

    loaded = Log.load(root)
    refute File.read!(checkpoint(root)) == made
    assert Log.load(root) == loaded
    assert loaded == fresh(root)
  end

  test "an edit to a line it covers is decoded in full, and raises as without it",
       %{tmp_dir: root} do
    Log.load(root)
    edited = String.replace(File.read!(open(root)), ~s("T: 5"), ~s("T: 6"), global: false)
    File.write!(open(root), edited)

    with_checkpoint = assert_raise ArgumentError, fn -> Log.load(root) end
    assert with_checkpoint.message =~ "does not match its content"
    assert assert_raise(ArgumentError, fn -> fresh(root) end) == with_checkpoint
    assert Enum.any?(Log.verify(root), &(&1 =~ "surfex.log:"))
  end

  test "a checkpoint that is damaged, or made by other code, is not used", %{tmp_dir: root} do
    expected = Log.load(root)

    File.write!(checkpoint(root), binary_part(File.read!(checkpoint(root)), 0, 100))
    assert Log.load(root) == expected

    # A well-formed one from other code, claiming the log holds nothing.
    content = File.read!(open(root))

    made = [{"surfex.log", byte_size(content), :crypto.hash(:sha256, content)}]
    Surfex.Cache.write(root, "log.checkpoint", :other_code, {made, []})
    assert Log.load(root) == expected
  end

  test "verify and check read every line, whatever the checkpoint says", %{tmp_dir: root} do
    content = File.read!(open(root))
    made = [{"surfex.log", byte_size(content), :crypto.hash(:sha256, content)}]

    # A checkpoint made by this code from these bytes, that says the log holds nothing.
    Surfex.Cache.write(
      root,
      "log.checkpoint",
      Surfex.Cache.fingerprint([Entry, Log]),
      {made, []}
    )

    assert Log.load(root) == []
    assert Log.check(root) == {Enum.map(1..40, &entry/1), []}
    assert Log.verify(root) == []
  end

  test "the cache ignores itself in git, and is never made without a log", %{tmp_dir: root} do
    Log.load(root)
    assert File.read!(Path.join([root, ".surfex", "cache", ".gitignore"])) == "*\n"

    elsewhere = Path.join(root, "no_log")
    File.mkdir_p!(elsewhere)
    assert Log.load(elsewhere) == []
    refute File.exists?(Log.dir(elsewhere))
  end

  test "a cache that can't be written doesn't fail the load", %{tmp_dir: root} do
    cache = Path.join([root, ".surfex", "cache"])
    File.mkdir_p!(cache)
    File.chmod!(cache, 0o500)
    on_exit(fn -> File.chmod(cache, 0o700) end)

    assert Log.load(root) == Enum.map(1..40, &entry/1)
  end
end
