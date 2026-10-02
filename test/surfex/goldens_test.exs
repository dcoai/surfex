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
      :status,
      {"API.md", Surfex.GoldensTest.Api, routes: [{"/carts", "CartController.index"}]}
    ],
    namespace: "MyApp",
    sources: ["spec.md"]
  ]
  """

  setup %{tmp_dir: root} do
    File.cp_r!(@project, root)
    File.write!(Path.join(root, "spec.md"), "# Carts\n`MyApp.Cart` holds lines.\n")
    File.write!(Path.join(root, ".surfex.exs"), @config)
    Surfex.Log.init(root)
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

  defp relate(root) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Relate.run(["spec.md#Carts", "MyApp.Cart", "--type", "implements"])
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  describe "mix surfex.goldens" do
    @describetag verifies: "goldens-task"

    @tag verifies: "purpose"
    test "--write writes every golden, and a check then passes", %{root: root} do
      task(root, ["--write"])
      assert File.read!(Path.join(root, "RELATIONS.md")) =~ "| `code MyApp.Cart` |"
      assert File.read!(Path.join(root, "API.md")) =~ "| `/carts` | `CartController.index` |"

      task(root)
      assert_received {:mix_shell, :info, ["checked 2 golden(s): all current, nothing failing"]}
    end

    test "one drifted golden is named, and only it", %{root: root} do
      task(root, ["--write"])
      config(root, "CartController.index", "CartController.list")

      message = fails(root)
      assert message =~ "API.md: out of date."
      assert message =~ "Changed:\n  /carts\n"
      refute message =~ "RELATIONS.md"
    end

    # #84: regenerating is how a drift is resolved, so --write never fails for one.
    test "--write after a drift regenerates every golden and succeeds; a check then passes",
         %{root: root} do
      task(root, ["--write"])
      config(root, "CartController.index", "CartController.list")
      relate(root)
      assert fails(root) =~ "API.md: out of date."

      task(root, ["--write"])
      assert_received {:mix_shell, :info, ["wrote 2 golden(s): all current, nothing failing"]}
      assert File.read!(Path.join(root, "API.md")) =~ "CartController.list"
      assert File.read!(Path.join(root, "RELATIONS.md")) =~ "| `code MyApp.Cart` |"

      task(root)
      assert_received {:mix_shell, :info, ["checked 2 golden(s): all current, nothing failing"]}
    end

    test "--config reads another definition", %{root: root} do
      File.rename!(Path.join(root, ".surfex.exs"), Path.join(root, "other.exs"))
      task(root, ["--config", "other.exs", "--write"])
      assert File.exists?(Path.join(root, "API.md"))
    end

    test "every drifted golden is named in one run", %{root: root} do
      task(root, ["--write"])
      config(root, "CartController.index", "CartController.list")
      relate(root)

      message = fails(root)
      assert message =~ "API.md: out of date."
      assert message =~ "RELATIONS.md: out of date."
    end

    test "a module that is not a Surface is named", %{root: root} do
      config(root, "Surfex.GoldensTest.Api, routes:", "String, routes:")

      assert_raise ArgumentError, ~r/String does not implement Surfex.Surface/, fn ->
        task(root, ["--write"])
      end
    end

    test "the built-in scanner reads source it could not compile", %{root: root} do
      # Valid syntax, but no compiler would accept it.
      File.write!(Path.join(root, "lib/broken.ex"), """
      defmodule MyApp.Broken do
        def call, do: undefined_variable + Nowhere.fun()
      end
      """)

      File.write!(Path.join(root, ".surfex.exs"), ~s([namespace: "MyApp", sources: ["spec.md"]]))
      task(root, ["--write"])
      assert File.read!(Path.join(root, "RELATIONS.md")) =~ "| `code MyApp.Broken.call/0` |"
    end

    @tag verifies: "traces"
    test "a config written for the removed trace says so", %{root: root} do
      config(root, "sources: [\"spec.md\"]", "sources: [\"spec.md\"], output: \"SPEC_TRACE.md\"")

      assert_raise ArgumentError,
                   ~r/\[:output\] belonged to the v0.2 trace, removed in 0.4.0/,
                   fn ->
                     task(root)
                   end
    end
  end

  describe "the :status golden" do
    @describetag verifies: "goldens-task"

    setup %{root: root} do
      File.write!(Path.join(root, ".surfex.exs"), ~s([goldens: [:status], sources: ["spec.md"]]))
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
      relate(root)
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

  describe "project goldens" do
    @describetag verifies: ["project-golden", "goldens-entries"]

    test "a Surface is a spec/1 callback, rendered and gated by run/6", %{tmp_dir: root} do
      assert Surfex.Surface.behaviour_info(:callbacks) == [spec: 1]

      entry = {"API.md", Surfex.GoldensTest.Api, routes: [{"/carts", "CartController.index"}]}
      assert Goldens.run([entry], [], root, [], "mix surfex.goldens", true) == []
      assert Goldens.run([entry], [], root, [], "mix surfex.goldens", false) == []
      assert File.read!(Path.join(root, "API.md")) =~ "| `/carts` |"
    end
  end

  describe "entries!/1" do
    @describetag verifies: "goldens-entries"

    test "defaults to the relation status alone" do
      assert Goldens.entries!(sources: ["spec.md"]) == [:status]
    end

    @tag verifies: "traces"
    test "names a malformed entry, and the removed :trace with its reason" do
      assert_raise ArgumentError, ~r/goldens entry "API.md" is not :status/, fn ->
        Goldens.entries!(goldens: ["API.md"])
      end

      assert_raise ArgumentError, ~r/:trace was removed in 0.4.0/, fn ->
        Goldens.entries!(goldens: [:trace])
      end

      assert_raise ArgumentError, ~r/non-empty list/, fn -> Goldens.entries!(goldens: []) end
    end

    test "two entries writing one file is an error" do
      assert_raise ArgumentError, ~r/two goldens write \["RELATIONS.md"\]/, fn ->
        Goldens.entries!(goldens: [:status, {"RELATIONS.md", Mod, []}])
      end
    end
  end

  # #74: the completeness report as a committed record.
  describe "the :completeness golden" do
    @describetag verifies: "goldens-entries"

    test "entries!/1 takes it, and run/6 writes COMPLETENESS.md, then checks it", %{
      tmp_dir: root
    } do
      assert Goldens.entries!(goldens: [:status, :completeness]) == [:status, :completeness]

      assert Goldens.entries!(goldens: [{:completeness, "docs/C.md"}]) == [
               {:completeness, "docs/C.md"}
             ]

      config = [sources: ["spec.md"], namespace: "MyApp"]
      assert Goldens.run([:completeness], config, root, [namespace: "MyApp"], "mix g", true) == []

      assert Goldens.run([:completeness], config, root, [namespace: "MyApp"], "mix g", false) ==
               []

      golden = File.read!(Path.join(root, "COMPLETENESS.md"))
      assert golden =~ "# COMPLETENESS.md"
      assert golden =~ "`code MyApp.Cart`"
    end
  end

  describe "needs_compile?/2" do
    @describetag verifies: "goldens-entries"

    test "only project code needs a compile" do
      refute Goldens.needs_compile?([:status], [])
      refute Goldens.needs_compile?([:status], scanner: :elixir)
      assert Goldens.needs_compile?([:status], scanner: MyScanner)
      assert Goldens.needs_compile?([:status, {"A.md", Mod, []}], [])
    end
  end
end
