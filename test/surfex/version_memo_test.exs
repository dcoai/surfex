defmodule Surfex.VersionMemoTest do
  # #383, #385: every scan pretty-printed every definition to hash it, though nearly every
  # definition is the same from one run to the next.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "version-memo"

  alias Surfex.{Cache, SourceScan, VersionMemo}

  # The defs of a few of surfex's own files: definitions as a real scan hashes them.
  @defs "lib/surfex/{log,source_scan,cache,parallel}.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

          ast
          |> Macro.prewalk([], fn
            {kind, _, _} = node, acc when kind in [:def, :defp, :defmacro] -> {node, [node | acc]}
            node, acc -> {node, acc}
          end)
          |> elem(1)
        end)

  defp versions(defs), do: Enum.map(defs, &SourceScan.definition_hash/1)

  defp saved(root) do
    {:ok, saved} = Cache.read(root, "versions", Cache.fingerprint([SourceScan]))
    saved
  end

  setup %{tmp_dir: root} do
    File.mkdir_p!(Surfex.Log.dir(root))
    :ok
  end

  test "every version in a memo, new or remembered, is the version without one", %{tmp_dir: root} do
    without = versions(@defs)
    assert length(without) > 50

    assert VersionMemo.run(root, fn -> versions(@defs) end) == without
    assert map_size(saved(root)) == length(Enum.uniq(Enum.map(@defs, &strip_like_source_scan/1)))
    assert VersionMemo.run(root, fn -> versions(@defs) end) == without
  end

  test "a changed definition has its own version, as without a memo", %{tmp_dir: root} do
    one = quote(do: def(f(x), do: x + 1))
    other = quote(do: def(f(x), do: x + 2))

    [a, b] = VersionMemo.run(root, fn -> versions([one, other]) end)
    assert a != b
    assert [a, b] == versions([one, other])
    assert VersionMemo.run(root, fn -> versions([other, one]) end) == [b, a]
  end

  test "Surfex.Parallel's tasks use and fill the caller's memo", %{tmp_dir: root} do
    defs = Enum.take(@defs, 200)

    VersionMemo.run(root, fn ->
      table = VersionMemo.current()
      seen = Surfex.Parallel.map(defs, &{VersionMemo.current(), SourceScan.definition_hash(&1)})
      assert Enum.all?(seen, fn {memo, _} -> memo == table end)
      assert Enum.map(seen, &elem(&1, 1)) == versions(defs)
    end)

    assert map_size(saved(root)) == length(Enum.uniq(Enum.map(defs, &strip_like_source_scan/1)))
  end

  test "a saved memo is read back; a damaged one, or one from other code, is not",
       %{tmp_dir: root} do
    one = quote(do: def(f(x), do: x))
    right = SourceScan.definition_hash(one)
    digest = digest(one)

    # A memo is trusted by its fingerprint: one claiming another version is used...
    Cache.write(root, "versions", Cache.fingerprint([SourceScan]), %{digest => {"remembered", 0}})
    assert VersionMemo.run(root, fn -> SourceScan.definition_hash(one) end) == "remembered"

    # ...but not one from other code, nor a damaged file.
    Cache.write(root, "versions", :other_code, %{digest => {"remembered", 0}})
    assert VersionMemo.run(root, fn -> SourceScan.definition_hash(one) end) == right

    File.write!(Path.join(Cache.dir(root), "versions"), "not a memo")
    assert VersionMemo.run(root, fn -> SourceScan.definition_hash(one) end) == right
  end

  test "a version unused through eight saves in a row is dropped", %{tmp_dir: root} do
    kept = quote(do: def(kept, do: :kept))
    VersionMemo.run(root, fn -> versions([kept]) end)

    for n <- 1..8 do
      VersionMemo.run(root, fn -> versions([quote(do: def(new, do: unquote(n)))]) end)
      assert Map.has_key?(saved(root), digest(kept))
    end

    VersionMemo.run(root, fn -> versions([quote(do: def(new, do: 9))]) end)
    refute Map.has_key?(saved(root), digest(kept))
  end

  test "a run that hashes nothing new saves nothing, and none is open outside a run",
       %{tmp_dir: root} do
    one = quote(do: def(f, do: 1))
    VersionMemo.run(root, fn -> versions([one]) end)
    file = Path.join(Cache.dir(root), "versions")
    made = File.read!(file)

    VersionMemo.run(root, fn -> versions([one]) end)
    assert File.read!(file) == made
    assert VersionMemo.current() == nil
  end

  test "a scan through the config keeps a memo, and gives the same items from it",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "lib/feed.ex"), """
    defmodule MyApp.Feed do
      @moduledoc "The feed."
      @doc "Feeds."
      def feed(feed, bytes), do: {feed, bytes}
    end
    """)

    File.write!(Path.join(root, "spec.md"), "# Feed\n\nIt feeds.\n")
    config = [sources: ["spec.md"], namespace: "MyApp"]

    # Every lookup misses the first time, so these versions are the hash's own.
    cold = Surfex.Status.Config.items(config, root)
    assert "MyApp.Feed.feed/2" in Enum.map(cold, &Surfex.Item.key/1)
    assert map_size(saved(root)) > 0
    assert Surfex.Status.Config.items(config, root) == cold
    assert VersionMemo.current() == nil
  end

  test "a project with no log keeps no memo", %{tmp_dir: root} do
    elsewhere = Path.join(root, "no_log")
    File.mkdir_p!(elsewhere)
    VersionMemo.run(elsewhere, fn -> versions([quote(do: def(f, do: 1))]) end)
    assert File.ls!(elsewhere) == []
  end

  # SourceScan's key for a definition: the digest of its stripped AST.
  defp digest(ast),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(strip_like_source_scan(ast), [:deterministic])
      )

  # SourceScan strips every 3-tuple's meta to [], literal pairs and lists included.
  defp strip_like_source_scan({form, _meta, args}),
    do: {strip_like_source_scan(form), [], strip_like_source_scan(args)}

  defp strip_like_source_scan(list) when is_list(list),
    do: Enum.map(list, &strip_like_source_scan/1)

  defp strip_like_source_scan({a, b}), do: {strip_like_source_scan(a), strip_like_source_scan(b)}
  defp strip_like_source_scan(leaf), do: leaf
end
