defmodule Surfex.ContractCitationTest do
  # #311 (for #287): a fence is read by CommonMark's rule, so prose is never read as code,
  # and a contract's own function is a citation, broken when the code has none (§6.8, §6.9).
  use ExUnit.Case, async: true

  alias Surfex.{Cite, Item, Profile}
  alias Surfex.Status.Config

  @moduletag :tmp_dir

  defp cc_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  # As `Config.read/3` gives them as its `citations:`, through the function §6.9 names.
  defp cc_broken(root, config) do
    items = Config.items(config, root)
    Config.broken_citations(config, items, root, nil, Config.scans(config, root))
  end

  @code """
  defmodule MyApp.Feed do
    @moduledoc "The feed."
    @doc "Feeds."
    def feed(feed, bytes), do: {feed, bytes}
    @doc "Sends a key."
    def send_key(feed, key, opts), do: {feed, key, opts}
  end
  """

  describe "fences by CommonMark's rule" do
    @tag verifies: ["fences-by-commonmark", "citation-fences", "citation-sections"]
    test "a contract fence's closer is no opener: the prose after it is prose, the next fence code",
         %{tmp_dir: root} do
      cc_write(root, "spec.md", """
      # Feed
      ```elixir contract
      @spec feed(t, binary) :: t
      ```
      prose MyApp.Feed here
      ```elixir
      MyApp.Feed.feed(f, "x")
      MyApp.Feed.feed(f, "y")
      ```
      ~~~ text with spaces
      MyApp.Feed
      ~~~
      """)

      items = [
        %Item{kind: :module, name: "MyApp.Feed", file: "lib/f.ex", hash: "1"},
        %Item{
          kind: :function,
          name: "feed/2",
          parent: "MyApp.Feed",
          file: "lib/f.ex",
          hash: "2",
          aliases: ["MyApp.Feed.feed"]
        }
      ]

      profile =
        Profile.new!(Surfex.Scanner.Elixir.profile_defaults("MyApp") ++ [sources: ["spec.md"]])

      cites = Cite.citations(items, profile, root)

      # The prose between the fences is not a code block, and a bare name in it is no span.
      refute Enum.any?(cites, &(&1.line == 5))
      # The plain fence's tokens are read, once per fence, at the line they first appear on;
      # a tilde fence with spaces in its info string is a fence too.
      assert [%{section: "(code block)", line: 7, status: :resolved}] =
               Enum.filter(cites, &(&1.span == "MyApp.Feed.feed"))

      assert [%{section: "(code block)", line: 11}] =
               Enum.filter(cites, &(&1.span == "MyApp.Feed"))
    end
  end

  describe "a contract's function is a citation" do
    @tag verifies: ["contract-citation", "contract-citations"]
    test "naming nothing is broken at its line, saying whether the module, the function or the arity is missing",
         %{tmp_dir: root} do
      cc_write(root, "lib/feed.ex", @code)

      cc_write(root, "spec.md", """
      # 1. `MyApp.Feed`

      ```elixir contract
      @spec feed(t, binary) :: t
      @spec send_key(t, key) :: t
      @spec send_mouse(t, event) :: t
      @spec MyApp.Gone.run(t) :: t
      ```
      """)

      broken = cc_broken(root, sources: ["spec.md"], namespace: "MyApp")

      assert [
               %{span: "MyApp.Feed.send_key/2", line: 5, section: "(contract)", why: arity},
               %{span: "MyApp.Feed.send_mouse/2", line: 6, why: function},
               %{span: "MyApp.Gone.run/1", line: 7, why: module}
             ] = broken

      assert arity == "names nothing the code has: `MyApp.Feed.send_key` exists at /3, not /2"
      assert function == "names nothing the code has: no `send_mouse` in `MyApp.Feed`"
      assert module == "names nothing the code has: no module `MyApp.Gone`"
      assert Enum.all?(broken, &(&1.status == :unresolved))
    end

    @tag verifies: ["contract-citation", "contract-citations"]
    test "a documented absence or a known external carries it, as any citation", %{tmp_dir: root} do
      cc_write(root, "lib/feed.ex", @code)

      cc_write(root, "spec.md", """
      # 1. `MyApp.Feed`

      ```elixir contract
      @spec send_mouse(t, event) :: t
      @spec MyApp.Gone.run(t) :: t
      ```
      """)

      assert [] =
               cc_broken(root,
                 sources: ["spec.md"],
                 namespace: "MyApp",
                 documented_absences: %{{"MyApp.Feed.send_mouse/2", "spec.md"} => "not yet"},
                 known_external: %{"MyApp.Gone" => "another project's"}
               )
    end

    @tag verifies: ["contract-citation", "contract-citations", "citation-statuses"]
    test "a contract deferred by its section is deferred, not broken; a callback is checked to its module",
         %{tmp_dir: root} do
      cc_write(root, "lib/feed.ex", @code)

      cc_write(root, "spec.md", """
      # 1. `MyApp.Feed`

      ```elixir contract
      @callback handle(t) :: t
      ```

      ## 1.1 Later
      <!-- surfex: deferred #12: past v1 -->

      ```elixir contract
      @spec MyApp.Feed.later(t) :: t
      ```

      # 2. `MyApp.Missing`

      ```elixir contract
      @callback handle(t) :: t
      ```
      """)

      # The heading's own span is broken as any citation is; the contract says why.
      assert [%{span: "MyApp.Missing.handle/1", why: why}] =
               root
               |> cc_broken(sources: ["spec.md"], namespace: "MyApp")
               |> Enum.filter(&(&1.section == "(contract)"))

      assert why == "names nothing the code has: no module `MyApp.Missing`"
    end
  end
end
