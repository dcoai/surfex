defmodule Surfex.RawReadsTest do
  # #401, #403: `File.read!/1` reads through OTP's file server, and an idle file server
  # keeps the last binaries it handed out alive: on apu the 71 MB log after a check, and the
  # whole 1.15 GB evidence file after loading it. What the file server holds is global, so
  # this module runs alone.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag verifies: "raw-reads"

  alias Surfex.{Evidence, Files, Log}
  alias Surfex.Log.Entry

  # A name long enough that a few thousand lines make files of megabytes.
  @padding String.duplicate("x", 1000)
  @large 1_000_000

  defp entry(n),
    do:
      Entry.new!(
        at:
          "2026-11-14T10:#{String.pad_leading("#{div(n, 60)}", 2, "0")}:#{String.pad_leading("#{rem(n, 60)}", 2, "0")}Z",
        op: :relate,
        type: :tests,
        ends: [
          %{kind: :test, id: "T: #{n} #{@padding}", hash: "t"},
          %{kind: :code, id: "M.f/#{n}", hash: "c"}
        ]
      )

  defp record(n),
    do: %{
      test: "T: #{n} #{@padding}",
      test_hash: "t#{n}",
      result: :passed,
      at: "2026-11-14T10:00:00Z",
      run: "r1",
      seq: n,
      code: %{"M.f/#{n}" => "c"}
    }

  # The sizes of the binaries of a megabyte or more the file server keeps alive.
  defp held do
    {:binary, binaries} = Process.info(Process.whereis(:file_server_2), :binary)
    for {_, size, _} <- binaries, size >= @large, do: size
  end

  defp after_read(fun) do
    fun.()
    # The caller's own references go; only what the file server keeps is left.
    :erlang.garbage_collect()
    held()
  end

  setup %{tmp_dir: root} do
    Log.init(root)
    Log.append(root, Enum.map(1..2500, &entry/1))
    Evidence.append(Evidence.path(root), Enum.map(1..2500, &record/1))

    # What the file server holds from reads before this test isn't this test's to judge.
    :erlang.garbage_collect(Process.whereis(:file_server_2))
    assert held() == []
    :ok
  end

  # The recurrence guard rides here, as a read going back to the file server: the source
  # check fails on the call itself, and the measure on what it leaves held.
  test "reading the log, its checkpoint and the evidence leaves the file server holding none of them",
       %{tmp_dir: root} do
    open = Path.join([root, ".surfex", "surfex.log"])
    assert File.stat!(open).size > 2 * @large
    assert File.stat!(Evidence.path(root)).size > 2 * @large

    # A cold load reads every segment and writes the checkpoint; a warm one reads it back.
    assert after_read(fn -> Log.load(root) end) == []
    assert File.stat!(Path.join([root, ".surfex", "cache", "log.checkpoint"])).size > @large
    assert after_read(fn -> Log.load(root) end) == []
    assert after_read(fn -> Log.check(root) end) == []
    assert after_read(fn -> Log.verify(root) end) == []

    assert after_read(fn -> Evidence.load(Evidence.path(root)) end) == []
    assert after_read(fn -> Evidence.project(root) end) == []
    assert after_read(fn -> Evidence.project(root) end) == []

    # What is read is what File.read reads, and a missing file raises as File.read! does.
    assert Files.read!(open) == File.read!(open)
    missing = Path.join(root, "missing")
    assert Files.read(missing) == File.read(missing)
    error = assert_raise File.Error, fn -> Files.read!(missing) end
    assert error == %File.Error{reason: :enoent, action: "read file", path: missing}

    for file <- ["lib/surfex/log.ex", "lib/surfex/cache.ex", "lib/surfex/evidence.ex"] do
      assert file_server_reads(file) == [], "#{file} reads through the file server"
    end
  end

  # Calls in `file` that read through the file server: File's reads, and :file's unless raw.
  defp file_server_reads(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {{:., _, [{:__aliases__, _, [:File]}, fun]}, _, _} = node, acc
      when fun in [:read, :read!, :stream!, :open] ->
        {node, [{File, fun} | acc]}

      {{:., _, [:file, fun]}, _, args} = node, acc when fun in [:read_file, :open] ->
        raw? = match?([_, modes] when is_list(modes), args) and :raw in List.last(args)
        {node, if(raw?, do: acc, else: [{:file, fun} | acc])}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
