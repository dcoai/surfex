defmodule Surfex.GoldensTest.Api do
  @moduledoc false
  # A project golden, as a project would write one.
  @behaviour Surfex.Surface

  @impl true
  def spec(opts) do
    %{
      name: "API.md",
      purpose: "Every endpoint.",
      task: "surfex.goldens",
      gate: "api-drift",
      hardness: :hard,
      columns: ["Endpoint", "Handler"],
      rows:
        for(
          {path, handler} <- Keyword.fetch!(opts, :routes),
          do: %{"Endpoint" => {:code, path}, "Handler" => {:code, handler}}
        )
    }
  end
end

defmodule Surfex.GoldensTest do
  # The task tests change the working directory, which is global.
  use ExUnit.Case, async: false

  alias Surfex.Goldens

  @moduletag :tmp_dir
  @project Path.expand("../fixtures/elixir_project", __DIR__)

  @config """
  [
    goldens: [
      :trace,
      {"API.md", Surfex.GoldensTest.Api, routes: [{"/carts", "CartController.index"}]}
    ],
    namespace: "MyApp",
    sources: ["spec.md"],
    classes: [{"fixture", "everything here is a fixture"}],
    rules: [%{class: "fixture", kinds: [:module, :function, :macro]}]
  ]
  """

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n`MyApp.Cart` holds lines.\n")
    File.write!(Path.join(root, ".surfex.exs"), @config)
    %{root: root}
  end

  defp task(root, args \\ []) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Goldens.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp fails(root, args \\ []) do
    error = assert_raise Mix.Error, fn -> task(root, args) end
    error.message
  end

  defp config(root, from, to) do
    file = Path.join(root, ".surfex.exs")
    File.write!(file, String.replace(File.read!(file), from, to))
  end

  describe "mix surfex.goldens" do
    test "--write writes every golden, and a check then passes", %{root: root} do
      task(root, ["--write"])
      assert File.read!(Path.join(root, "SPEC_TRACE.md")) =~ "| `MyApp.Cart` |"
      assert File.read!(Path.join(root, "API.md")) =~ "| `/carts` | `CartController.index` |"

      task(root)
      assert_received {:mix_shell, :info, ["checked 2 golden(s): all current, nothing failing"]}
    end

    test "one drifted golden is named, and only it", %{root: root} do
      task(root, ["--write"])
      config(root, "CartController.index", "CartController.list")

      message = fails(root)
      assert message =~ "API.md: out of date."
      # A golden with no Cited by column says nothing about a spec.
      assert message =~ "Changed:\n  /carts\n"
      refute message =~ "revisit"
      refute message =~ "SPEC_TRACE.md"
    end

    test "every drifted golden is named in one run", %{root: root} do
      task(root, ["--write"])
      config(root, "CartController.index", "CartController.list")

      File.write!(
        Path.join(root, "spec.md"),
        "# Carts\n`MyApp.Cart` holds lines. Also `MyApp.Cart.total/0`.\n"
      )

      message = fails(root)
      assert message =~ "API.md: out of date."
      assert message =~ "SPEC_TRACE.md: out of date."
    end

    test "a module that is not a Surface is named", %{root: root} do
      config(root, "Surfex.GoldensTest.Api, routes:", "String, routes:")

      assert_raise ArgumentError, ~r/String does not implement Surfex.Surface/, fn ->
        task(root, ["--write"])
      end
    end

    test "the built-in trace reads source it could not compile", %{root: root} do
      # Valid syntax, but no compiler would accept it.
      File.write!(Path.join(root, "lib/broken.ex"), """
      defmodule MyApp.Broken do
        def call, do: undefined_variable + Nowhere.fun()
      end
      """)

      File.write!(Path.join(root, ".surfex.exs"), trace_only_config())
      task(root, ["--write"])
      assert File.read!(Path.join(root, "SPEC_TRACE.md")) =~ "| `MyApp.Broken.call/0` |"
    end
  end

  defp trace_only_config do
    """
    [
      namespace: "MyApp",
      sources: ["spec.md"],
      classes: [{"fixture", "everything here is a fixture"}],
      rules: [%{class: "fixture", kinds: [:module, :function, :macro]}]
    ]
    """
  end

  describe "the :status golden" do
    setup %{root: root} do
      File.write!(Path.join(root, ".surfex.exs"), ~s([goldens: [:status], sources: ["spec.md"]]))
      Surfex.Log.init(root)
      :ok
    end

    test "writes RELATIONS.md, and a check then passes", %{root: root} do
      task(root, ["--write"])
      golden = File.read!(Path.join(root, "RELATIONS.md"))
      assert golden =~ "# RELATIONS.md"
      assert golden =~ "**0 relations** · current 0"
      assert golden =~ "## new\n\n| Item |\n|---|\n| `code MyApp.Cart` |"
      refute golden =~ ~r/\d{4}-\d{2}-\d{2}/

      task(root)
      assert_received {:mix_shell, :info, ["checked 1 golden(s): all current, nothing failing"]}
    end

    test "a relation's change of state is a drift", %{root: root} do
      task(root, ["--write"])

      File.cd!(root, fn ->
        Mix.shell(Mix.Shell.Process)
        Mix.Tasks.Surfex.Relate.run(["spec.md#Carts", "MyApp.Cart", "--type", "implements"])
      end)

      Mix.shell(Mix.Shell.IO)
      assert fails(root) =~ "RELATIONS.md: out of date."
    end

    test "{:status, output} writes where it is told", %{root: root} do
      File.write!(
        Path.join(root, ".surfex.exs"),
        ~s([goldens: [{:status, "docs/REL.md"}], sources: ["spec.md"]])
      )

      File.mkdir_p!(Path.join(root, "docs"))
      task(root, ["--write"])
      assert File.exists?(Path.join(root, "docs/REL.md"))
    end
  end

  describe "entries!/1" do
    test "defaults to the trace alone" do
      assert Goldens.entries!(sources: ["spec.md"]) == [:trace]
    end

    test "names a malformed entry" do
      assert_raise ArgumentError, ~r/goldens entry "API.md" is not :trace, :status/, fn ->
        Goldens.entries!(goldens: ["API.md"])
      end

      assert_raise ArgumentError, ~r/non-empty list/, fn -> Goldens.entries!(goldens: []) end
    end

    test "two entries writing one file is an error" do
      assert_raise ArgumentError, ~r/two goldens write \["SPEC_TRACE.md"\]/, fn ->
        Goldens.entries!(goldens: [:trace, {"SPEC_TRACE.md", Mod, []}])
      end
    end
  end

  describe "needs_compile?/2" do
    test "only project code needs a compile" do
      refute Goldens.needs_compile?([:trace], [])
      refute Goldens.needs_compile?([:trace], scanner: :elixir)
      assert Goldens.needs_compile?([:trace], scanner: MyScanner)
      assert Goldens.needs_compile?([:trace, {"A.md", Mod, []}], [])
    end
  end
end
