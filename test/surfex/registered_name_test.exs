defmodule Surfex.RegisteredNameTest do
  # #299: a citation of a process name the source registers resolves as a registered
  # name, under its own status (spec §6.7).
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Profile}
  alias Surfex.Status.Config

  @moduletag :tmp_dir

  defp registered_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp registered_status(cites, span) do
    for %{span: ^span, status: status} <- cites, do: status
  end

  describe "Cite.citations/4 :registered" do
    @tag verifies: [
           "registered-name",
           "citation-not-code",
           "citation-status-kinds",
           "citation-statuses"
         ]
    test "exactly the name is a registered name; a function on it and a module beside it aren't",
         %{tmp_dir: root} do
      registered_write(root, "spec.md", """
      # Sessions
      `MyApp.Sessions` holds them. `MyApp.Sessions.count/0` counts them.
      `MyApp.Cart` is a module. `MyApp.Crat` is a typo.
      """)

      items = [%Item{kind: :module, name: "MyApp.Cart", file: "lib/c.ex", hash: "1"}]

      profile =
        Profile.new!(Surfex.Scanner.Elixir.profile_defaults("MyApp") ++ [sources: ["spec.md"]])

      cites = Cite.citations(items, profile, root, registered: ["MyApp.Sessions", "MyApp.Cart"])

      assert registered_status(cites, "MyApp.Sessions") == [:registered_name]
      assert [%{items: []}] = Enum.filter(cites, &(&1.span == "MyApp.Sessions"))
      assert registered_status(cites, "MyApp.Sessions.count/0") == [:unresolved]
      # A module of that name wins: the citation is of the code.
      assert registered_status(cites, "MyApp.Cart") == [:resolved]
      assert registered_status(cites, "MyApp.Crat") == [:unresolved]

      # Without the option nothing is registered.
      assert registered_status(Cite.citations(items, profile, root), "MyApp.Sessions") == [
               :unresolved
             ]
    end
  end

  describe "broken_citations/4 reads the registered names from source" do
    @tag verifies: ["registered-name", "citation-not-code"]
    test "a literal name: alias isn't broken; global, via, variables and defined modules are read as such",
         %{tmp_dir: root} do
      registered_write(root, "lib/app.ex", """
      defmodule MyApp.Application do
        @moduledoc "The application."
        def start(_type, _args) do
          children = [
            {DynamicSupervisor, strategy: :one_for_one, name: MyApp.Sessions},
            {Registry, keys: :unique, name: MyApp.Registry},
            {Agent, fn -> 0 end, name: {:global, MyApp.Global}},
            {Agent, fn -> 0 end, name: {:via, Registry, {MyApp.Registry, MyApp.Via}}}
          ]

          name = MyApp.Variable
          GenServer.start_link(MyApp.Worker, [], name: name)
          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Hidden)
        end
      end
      """)

      # A module of a registered name that makes no item (`@moduledoc false`) is still a
      # module: its citation stays a citation of code that names nothing.
      registered_write(root, "lib/hidden.ex", """
      defmodule MyApp do
        @moduledoc "The root."
        defmodule Hidden do
          @moduledoc false
        end
      end
      """)

      registered_write(root, "spec.md", """
      # Processes
      `MyApp.Sessions` and `MyApp.Registry` are registered. `MyApp.Sessions.count/0` isn't a
      function. `MyApp.Global`, `MyApp.Via` and `MyApp.Variable` are not literal names.
      `MyApp.Hidden` is a module.
      """)

      config = [sources: ["spec.md"], namespace: "MyApp"]
      items = Config.items(config, root)
      broken = Config.broken_citations(config, items, root, nil)

      assert broken |> Enum.map(& &1.span) |> Enum.sort() == [
               "MyApp.Global",
               "MyApp.Hidden",
               "MyApp.Sessions.count/0",
               "MyApp.Variable",
               "MyApp.Via"
             ]
    end

    @tag verifies: ["registered-name"]
    test "without the Elixir scanner nothing is registered", %{tmp_dir: root} do
      registered_write(
        root,
        "lib/app.ex",
        "defmodule A do\n  def s, do: x(name: Wren.Sessions)\nend\n"
      )

      registered_write(root, "spec.md", "# W\n`Wren.Sessions`\n")

      config = [
        sources: ["spec.md"],
        scanner: Surfex.RegisteredNameTest.NoScanner,
        shape: ~r/^Wren/
      ]

      assert [%{span: "Wren.Sessions", status: :unresolved}] =
               Config.broken_citations(config, [], root, nil)
    end
  end

  defmodule NoScanner do
    @moduledoc false
    @behaviour Surfex.Scanner
    @impl true
    def items(_root, _opts), do: []
  end
end
