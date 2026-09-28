defmodule Surfex.TraceTest do
  # The task tests change the working directory, which is global.
  use ExUnit.Case, async: false

  alias Surfex.{Item, Trace}

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)

  @spec_md """
  # Carts
  `MyApp.Cart` holds lines (`MyApp.Cart.Line`, built by `MyApp.Cart.Line.new/1`).

  ## Adding
  `MyApp.Cart.add` rejects a closed cart; so does `MyApp.Cart.after_hidden/1`.

  ## Totals
  `MyApp.Cart.total/0` and `MyApp.Cart.size/1`.

  # Server
  `MyApp.Server` serves.
  """

  @config """
  [
    namespace: "MyApp",
    sources: ["spec.md"],
    purpose: "Every public item of the fixture, and the spec that covers it.",
    require_citation: ~r/^(Adding|Totals)$/,
    groups: [module: "Modules", function: "Functions"],
    not_catalogued: [{"private functions", "not surface"}],
    prose: [
      "Rows are items; `Cited by` is sections, a class, or GAP.",
      {:not_catalogued, "Not catalogued"},
      {:classes, "Classes"}
    ],
    classes: [
      {"guards", "macros the spec describes by behaviour"},
      {"fixtures", "present to exercise the scanner"},
      {"process plumbing", "GenServer callbacks and entry points"}
    ],
    rules: [
      %{class: "guards", kinds: [:macro]},
      %{class: "fixtures", kinds: [:module, :function], name: ~r/^(MyApp\\.Hidden\\.Visible|shown\\/0)$/},
      %{class: "process plumbing", kinds: [:function], name: ~r/^(handle_call|start_link)\\//}
    ]
  ]
  """

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), @spec_md)
    File.write!(Path.join(root, ".surfex.exs"), @config)
    %{root: root}
  end

  defp task(root, args \\ []) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Trace.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp fails(root, args \\ []) do
    error = assert_raise Mix.Error, fn -> task(root, args) end
    error.message
  end

  defp edit(root, path, from, to) do
    file = Path.join(root, path)
    text = File.read!(file)
    assert text =~ from
    File.write!(file, String.replace(text, from, to))
  end

  describe "mix surfex.trace" do
    test "--write, then a check, passes", %{root: root} do
      task(root, ["--write"])
      golden = File.read!(Path.join(root, "SPEC_TRACE.md"))
      assert golden =~ "**16 items** · cited 10 · expected-silent 6 · GAPS 0 · citations 8"
      assert golden =~ "| `MyApp.Cart.is_cart/1` | `:macro` |"
      assert golden =~ "`— guards`"
      assert golden =~ "## Modules"
      # A kind the groups do not list still gets its table.
      assert golden =~ "## macro"

      task(root)
      assert_received {:mix_shell, :info, ["checked 1 golden(s): all current, nothing failing"]}
    end

    test "a missing golden is named", %{root: root} do
      assert fails(root) =~ "SPEC_TRACE.md does not exist"
    end

    test "editing a cited function fails with the sections to revisit", %{root: root} do
      task(root, ["--write"])
      edit(root, "lib/my_app/cart.ex", "def total, do: helper(0)", "def total, do: helper(1)")

      message = fails(root)
      assert message =~ "Changed (the sections listed cite them — revisit each)"
      assert message =~ "MyApp.Cart.total/0 → spec — Totals"
      # A body edit is the function's change, not its module's (#33).
      refute message =~ "MyApp.Cart →"
    end

    test "renaming a cited function reports the broken citation and the gap together", %{
      root: root
    } do
      task(root, ["--write"])
      edit(root, "lib/my_app/cart.ex", "def total, do:", "def grand_total, do:")

      message = fails(root)
      assert message =~ "Added (nothing in the spec covers them yet):\n  MyApp.Cart.grand_total/0"
      assert message =~ "Gone (the spec may still describe them):\n  MyApp.Cart.total/0"
      assert message =~ "GAP: `MyApp.Cart.grand_total/0`"
      assert message =~ "unresolved: `MyApp.Cart.total/0` at spec.md:8, Totals"
    end

    test "--write still writes the golden when there are failures, then fails", %{root: root} do
      edit(root, "spec.md", "`MyApp.Server` serves.", "The server serves.")
      assert fails(root, ["--write"]) =~ "GAP: `MyApp.Server`"
      assert File.read!(Path.join(root, "SPEC_TRACE.md")) =~ "| `MyApp.Server` | `:module` |"
    end

    test "a required section that cites nothing fails", %{root: root} do
      edit(root, "spec.md", "`MyApp.Cart.total/0` and `MyApp.Cart.size/1`.", "Nothing yet.")
      assert fails(root, ["--write"]) =~ "uncited: spec.md, Totals is a required section"
    end

    test "--config reads another file", %{root: root} do
      File.rename!(Path.join(root, ".surfex.exs"), Path.join(root, "trace.exs"))
      task(root, ["--write", "--config", "trace.exs"])
      assert File.exists?(Path.join(root, "SPEC_TRACE.md"))
    end
  end

  describe "inputs that would make a golden meaningless" do
    defp trace(root, extra),
      do: Trace.load!(Path.join(root, ".surfex.exs")) |> then(&Trace.new!(config(&1, extra)))

    defp config(_trace, extra), do: Keyword.merge(elem(Code.eval_string(@config), 0), extra)

    defp analyse(root, extra) do
      t = trace(root, extra)
      Trace.analyse(t, Trace.items(t, root), root)
    end

    test "no sources", %{root: root} do
      assert_raise ArgumentError, ~r/no spec sources match/, fn ->
        analyse(root, sources: ["nope/*.md"])
      end
    end

    test "no items", %{root: root} do
      assert_raise ArgumentError, ~r/the scanner found no items/, fn ->
        analyse(root, scanner_opts: [paths: ["nothing/*.ex"]])
      end
    end

    test "a require_citation that matches no heading", %{root: root} do
      assert_raise ArgumentError, ~r/matches no heading/, fn ->
        analyse(root, require_citation: ~r/^REQ-/)
      end
    end

    test "a scanner that does not implement the behaviour", %{root: root} do
      t = trace(root, scanner: String, shape: ~r/^MyApp/)

      assert_raise ArgumentError, ~r/String does not implement Surfex.Scanner/, fn ->
        Trace.items(t, root)
      end
    end
  end

  describe "configuration" do
    @base [namespace: "MyApp", sources: ["spec.md"]]

    test "an unknown key is named" do
      assert_raise ArgumentError, ~r/unknown profile keys: \[:outptu\]/, fn ->
        Trace.new!(@base ++ [outptu: "x.md"])
      end
    end

    test "a wrong trace value is named" do
      assert_raise ArgumentError, ~r/:hardness is invalid/, fn ->
        Trace.new!(@base ++ [hardness: :soft])
      end

      assert_raise ArgumentError, ~r/:columns is invalid/, fn ->
        Trace.new!(@base ++ [columns: ["Item", "Colour"]])
      end

      assert_raise ArgumentError, ~r/:prose is invalid/, fn ->
        Trace.new!(@base ++ [prose: [{:nonsense, "x"}]])
      end
    end

    test "the Elixir scanner needs a namespace" do
      assert_raise ArgumentError, ~r/:namespace is required/, fn ->
        Trace.new!(sources: ["spec.md"])
      end
    end

    test "Elixir defaults fill the profile, and the project's keys win" do
      t = Trace.new!(@base)
      assert Regex.match?(t.profile.shape, "MyApp.Cart.add/2")

      t = Trace.new!(@base ++ [shape: ~r/^custom$/])
      assert Regex.source(t.profile.shape) == "^custom$"
    end

    test "load!/2 needs a keyword list", %{tmp_dir: root} do
      path = Path.join(root, "bad.exs")
      File.write!(path, "%{sources: []}")
      assert_raise ArgumentError, ~r/must evaluate to a keyword list/, fn -> Trace.load!(path) end
    end
  end

  describe "render/2" do
    test "is invariant under item order and carries no dates or VCS data", %{root: root} do
      t = Trace.load!(Path.join(root, ".surfex.exs"))
      items = Trace.items(t, root)
      render = &Trace.render(t, Trace.analyse(t, &1, root))

      assert render.(Enum.reverse(items)) == render.(items)
      assert render.(Enum.shuffle(items)) == render.(items)

      golden = render.(items)
      refute golden =~ ~r/\d{4}-\d{2}-\d{2}/
      refute golden =~ ~r/\b[0-9a-f]{40}\b/
    end

    test "columns can be narrowed", %{root: root} do
      t = Trace.load!(Path.join(root, ".surfex.exs"))
      t = %{t | columns: ["Item", "Cited by"]}
      golden = Trace.render(t, Trace.analyse(t, Trace.items(t, root), root))
      assert golden =~ "| Item | Cited by |\n"
      assert golden =~ "| `MyApp.Cart` | `spec — Carts` |"
    end
  end

  # #15: a key two items share must not let one item's verdict stand in for the other's.
  test "a GAP survives a key it shares with an excused item", %{tmp_dir: root} do
    File.write!(Path.join(root, "spec.md"), "# S\n`twin` names two things.\n")

    t =
      Trace.new!(
        scanner: AnyScanner,
        sources: ["spec.md"],
        shape: ~r/^twin$/,
        classes: [{"internal", "the code's own factoring"}],
        rules: [%{class: "internal", kinds: [:const]}]
      )

    items = [
      %Item{kind: :function, name: "twin", file: "a.c", hash: "00000001"},
      %Item{kind: :const, name: "twin", file: "a.h", hash: "00000002"}
    ]

    analysis = Trace.analyse(t, items, root)

    assert "GAP: `twin` (`:function`) is neither cited by the spec nor excused by a class" in Trace.failures(
             t,
             analysis
           )

    golden = Trace.render(t, analysis)
    assert golden =~ "| `twin` | `:function` | `—` | `00000001` | `:GAP` |"
    assert golden =~ "| `twin` | `:const` | `—` | `00000002` | `— internal` |"
    assert golden =~ "GAPS 1"
  end

  describe "drift/2" do
    test "identical is nil; a prose-only change says so" do
      assert Trace.drift("same", "same") == nil
      assert Trace.drift("# A\nold prose", "# A\nnew prose") =~ "No row changed"
    end

    test "reads rows by column name, whatever the column order" do
      old = "| Version | Item | Cited by |\n|---|---|---|\n| `aaaa` | `x` | `s — 1` |\n"
      new = "| Version | Item | Cited by |\n|---|---|---|\n| `bbbb` | `x` | `s — 1` |\n"
      assert Trace.drift(old, new) =~ "x → s — 1"
    end
  end

  test "items/2 dispatches to the built-in scanner", %{root: root} do
    t = Trace.load!(Path.join(root, ".surfex.exs"))
    assert "MyApp.Cart.add/2" in Enum.map(Trace.items(t, root), &Item.key/1)
  end
end
