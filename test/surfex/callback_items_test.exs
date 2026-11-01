defmodule Surfex.CallbackItemsTest do
  # #345 (for #337): a behaviour's callbacks are items of their own (§5.2.1), judged with
  # their module until related (§13.19); a shape is not on the triangle's code side
  # (§13.20); a callback contract resolves to its callback item (§6.9).
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Item, Scan, SourceScan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Scanner.Elixir, as: ElixirScanner
  alias Surfex.Status.Config

  @moduletag :tmp_dir

  @store """
  defmodule MyApp.Store do
    @moduledoc "A store."

    @doc "Fetches a key."
    @callback fetch(key :: term) :: {:ok, term} | :error

    @doc "Builds a store at compile time."
    @macrocallback build(opts :: keyword) :: Macro.t()

    @doc false
    @callback internal() :: :ok

    @callback put(key :: term, value :: term) :: :ok
    @callback put(key :: term, value :: term, opts :: keyword) :: :ok

    @doc "Reads through the configured store."
    def fetch(key), do: {:ok, key}
  end
  """

  defp cb_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp cb_items(root, text) do
    cb_write(root, "lib/store.ex", text)
    ElixirScanner.items(root)
  end

  defp cb_by_key(items), do: Map.new(items, &{Item.key(&1), &1})

  describe "the Elixir scanner's callback items" do
    @tag verifies: ["callback-item-versions", "callback-items"]
    test "each public callback is a shape in its module, versioned by its declaration and its @doc",
         %{tmp_dir: root} do
      items = cb_by_key(cb_items(root, @store))

      assert %Item{
               kind: :callback,
               name: "callback:fetch/1",
               parent: "MyApp.Store",
               file: "lib/store.ex",
               shape: true,
               aliases: [],
               calls: [],
               lines: {5, 5}
             } = items["MyApp.Store.callback:fetch/1"]

      # Read with Map.get: the field is new (#345).
      assert Map.get(items["MyApp.Store.callback:fetch/1"], :in_parent) == true
      assert %Item{kind: :macrocallback} = items["MyApp.Store.macrocallback:build/1"]
      assert Map.get(items["MyApp.Store.macrocallback:build/1"], :in_parent) == true

      # @doc false hides it; two arities are two callbacks; the function keeps its key.
      refute Map.has_key?(items, "MyApp.Store.callback:internal/0")
      assert Map.has_key?(items, "MyApp.Store.callback:put/2")
      assert Map.has_key?(items, "MyApp.Store.callback:put/3")
      assert %Item{kind: :function} = items["MyApp.Store.fetch/1"]

      # Only callbacks are in their parent: no other item is.
      for {_key, item} <- items,
          item.kind not in [:callback, :macrocallback],
          do: refute(Map.get(item, :in_parent))

      # The module's version is its surface's, as before: callbacks change nothing in it.
      [node] = @store |> Code.string_to_quoted!() |> SourceScan.defmodules()
      assert items["MyApp.Store"].hash == SourceScan.module_hash(node)

      # A reworded @doc moves the doc version alone; a changed signature, the version alone,
      # and of that callback only.
      reworded =
        cb_by_key(cb_items(root, String.replace(@store, "Fetches a key.", "Fetches one key.")))

      fetch = items["MyApp.Store.callback:fetch/1"]
      assert reworded["MyApp.Store.callback:fetch/1"].hash == fetch.hash
      refute reworded["MyApp.Store.callback:fetch/1"].doc == fetch.doc

      changed =
        cb_by_key(cb_items(root, String.replace(@store, "{:ok, term} | :error", "term")))

      refute changed["MyApp.Store.callback:fetch/1"].hash == fetch.hash
      assert changed["MyApp.Store.callback:fetch/1"].doc == fetch.doc

      for key <- ["MyApp.Store.macrocallback:build/1", "MyApp.Store.callback:put/2"] do
        assert changed[key].hash == items[key].hash
        assert reworded[key].doc == items[key].doc
      end

      # Moving a callback, or re-wrapping its doc, changes neither.
      moved =
        cb_by_key(
          cb_items(
            root,
            String.replace(
              @store,
              ~s|@doc "Fetches a key."|,
              ~s|\n\n  @doc """\n  Fetches\n  a key.\n  """|
            )
          )
        )

      assert moved["MyApp.Store.callback:fetch/1"].hash == fetch.hash
      assert moved["MyApp.Store.callback:fetch/1"].doc == fetch.doc

      # A module under @moduledoc false lists no callbacks.
      hidden = String.replace(@store, ~s|@moduledoc "A store."|, "@moduledoc false")
      assert [] = cb_items(root, hidden)
    end
  end

  # ── judged with its parent (§13.19) ───────────────────────────────────────

  @spec_text """
  ## Store
  <!-- surfex: store -->

  The store fetches.
  """

  defp cb_scans do
    Markdown.sections(@spec_text, "spec.md") ++
      Scan.code([
        %Item{kind: :module, name: "MyApp.Store", file: "lib/store.ex", hash: "m", lines: {1, 9}},
        struct(Item,
          kind: :callback,
          name: "callback:fetch/1",
          parent: "MyApp.Store",
          file: "lib/store.ex",
          hash: "cb",
          lines: {3, 3},
          shape: true,
          in_parent: true
        )
      ])
  end

  defp cb_implements(code, hash, extra \\ []) do
    unit = Enum.find(cb_scans(), &(&1.id == "spec.md#store"))

    Entry.new!(
      at: Keyword.get(extra, :at, "2026-11-01T10:00:00Z"),
      op: Keyword.get(extra, :op, :relate),
      type: :implements,
      basis: if(Keyword.get(extra, :op, :relate) == :relate, do: :judgement),
      by: "t",
      note: "checked",
      parents: Keyword.get(extra, :parents, []),
      ends: [%{kind: :spec, id: unit.id, hash: unit.hash}, %{kind: :code, id: code, hash: hash}]
    )
  end

  # The unit verified, so an implements of it earns (§13.5).
  defp cb_status(entries, require \\ [code: [:implements, :excuses]]) do
    test = cb_test(["MyApp.Other.run/0"])
    Status.derive(cb_scans() ++ [test], [cb_verifies(test) | entries], require)
  end

  defp cb_unmet(status), do: for(u <- status.unmet, u.scan.kind == :code, do: u.scan.id)
  defp cb_new(status), do: for(s <- status.new, s.kind == :code, do: s.id)
  defp cb_counted(status), do: Completeness.report(status).scores.code.total

  describe "a member judged with its parent" do
    @tag verifies: ["in-parent-judged", "in-parent"]
    test "until a relation names it, it is not new, not unmet and not counted; then it is" do
      alone = cb_status([])
      assert cb_new(alone) == ["MyApp.Store"]
      assert cb_unmet(alone) == ["MyApp.Store"]
      assert cb_counted(alone) == 1

      module_only = cb_status([cb_implements("MyApp.Store", "m")])
      assert cb_new(module_only) == []
      assert cb_unmet(module_only) == []
      assert cb_counted(module_only) == 1

      # Named by a relation of its own, it is judged and counted as any item.
      named = cb_implements("MyApp.Store.callback:fetch/1", "cb")
      both = cb_status([cb_implements("MyApp.Store", "m"), named])
      assert cb_counted(both) == 2
      assert cb_unmet(both) == []

      excused_by_nothing = cb_status([cb_implements("MyApp.Store", "m"), named], code: [:excuses])

      assert cb_unmet(excused_by_nothing) == ["MyApp.Store", "MyApp.Store.callback:fetch/1"]

      # Retired, it is judged with its parent again.
      retired =
        cb_implements("MyApp.Store.callback:fetch/1", "cb",
          op: :retire,
          parents: [named.id],
          at: "2026-11-01T11:00:00Z"
        )

      back = cb_status([cb_implements("MyApp.Store", "m"), named, retired])
      assert cb_counted(back) == 1
      assert cb_new(back) == []
      assert cb_unmet(back) == []
    end
  end

  # ── the triangle's code side (§13.20) ─────────────────────────────────────

  defp cb_test(calls),
    do: %Scan{
      kind: :test,
      id: "T: verifies the store",
      hash: "t1",
      calls: calls,
      declares: [{:verifies, "spec.md#store"}],
      location: %{file: "test/store_test.exs", lines: {1, 5}}
    }

  defp cb_verifies(test) do
    unit = Enum.find(cb_scans(), &(&1.id == "spec.md#store"))

    Entry.new!(
      at: "2026-11-01T10:00:00Z",
      op: :relate,
      type: :verifies,
      basis: :review,
      by: "t",
      note: "checked",
      ends: [
        %{kind: :test, id: test.id, hash: test.hash},
        %{kind: :spec, id: unit.id, hash: unit.hash}
      ]
    )
  end

  defp cb_function,
    do:
      Scan.code([
        %Item{
          kind: :function,
          name: "fetch/1",
          parent: "MyApp.Impl",
          file: "lib/impl.ex",
          hash: "f",
          lines: {2, 4}
        }
      ])

  defp cb_gaps(scans, entries) do
    status = Status.derive(scans, entries, [], triangle: :fail)
    for g <- status.triangle, do: {g.gap, g.code || g.test}
  end

  describe "a shape on the triangle" do
    @tag verifies: ["triangle-shape-side", "triangle-shapes"]
    test "a shape is never untested, and a unit implemented by shapes alone needs only a test" do
      callback = cb_implements("MyApp.Store.callback:fetch/1", "cb")
      test = cb_test(["MyApp.Other.run/0"])

      # No verifying test: the one gap there is.
      bystander = %{cb_test([]) | id: "T: verifies nothing", declares: []}
      assert cb_gaps(cb_scans() ++ [bystander], [callback]) == [{:no_test, nil}]

      # A verifying test that reaches nothing: no code side to miss or leave untested.
      assert cb_gaps(cb_scans() ++ [test], [callback, cb_verifies(test)]) == []

      # Code with behaviour beside the shape still needs reaching.
      function = cb_implements("MyApp.Impl.fetch/1", "f")

      assert cb_gaps(cb_scans() ++ cb_function() ++ [test], [
               callback,
               function,
               cb_verifies(test)
             ]) ==
               [{:test_misses_code, test.id}, {:code_untested, "MyApp.Impl.fetch/1"}]

      reaching = cb_test(["MyApp.Impl.fetch/1"])

      assert cb_gaps(cb_scans() ++ cb_function() ++ [reaching], [
               callback,
               function,
               cb_verifies(reaching)
             ]) == []
    end
  end

  # ── a callback contract's resolution (§6.9) ───────────────────────────────

  defp cb_broken(root) do
    config = [sources: ["spec.md"], namespace: "MyApp"]
    items = Config.items(config, root)

    config
    |> Config.broken_citations(items, root, nil, Config.scans(config, root))
    |> Enum.filter(&(&1.section == "(contract)"))
  end

  describe "a callback contract" do
    @tag verifies: ["callback-contract-resolution", "contract-citations"]
    test "resolves to its callback item, is broken where the module lists others, and falls back where it lists none",
         %{tmp_dir: root} do
      cb_write(root, "lib/store.ex", @store)

      cb_write(root, "lib/plain.ex", """
      defmodule MyApp.Plain do
        @moduledoc "Declares no callbacks."
        def run, do: :ok
      end
      """)

      cb_write(root, "spec.md", """
      # 1. `MyApp.Store`

      ```elixir contract
      @callback fetch(term) :: {:ok, term} | :error
      @macrocallback build(keyword) :: Macro.t()
      ```

      # 2. `MyApp.Plain`

      ```elixir contract
      @callback run() :: :ok
      ```
      """)

      assert cb_broken(root) == []

      config = [sources: ["spec.md"], namespace: "MyApp"]
      items = ElixirScanner.items(root)

      contracts =
        for c <-
              Surfex.Cite.Contracts.citations(
                Config.scans(config, root),
                items,
                Config.profile!(config, "MyApp", items)
              ),
            into: %{},
            do: {c.span, c.items}

      assert contracts["MyApp.Store.fetch/1"] == ["MyApp.Store.callback:fetch/1"]
      assert contracts["MyApp.Store.build/1"] == ["MyApp.Store.macrocallback:build/1"]
      assert contracts["MyApp.Plain.run/0"] == ["MyApp.Plain"]

      cb_write(root, "spec.md", """
      # 1. `MyApp.Store`

      ```elixir contract
      @callback drop(term) :: :ok
      ```
      """)

      assert [%{span: "MyApp.Store.drop/1", why: why}] = cb_broken(root)
      assert why == "names nothing the code has: no callback `drop/1` in `MyApp.Store`"
    end
  end
end
