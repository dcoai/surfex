defmodule Surfex.ExternalGoldenTest do
  # #322: known_external: takes its vocabulary from a committed golden that already lists
  # it, so the names are versioned with the golden rather than copied into .surfex.exs.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag verifies: "golden-vocabulary"

  alias Surfex.{Cite, Profile}
  alias Surfex.Status.Config

  @golden """
  # REFERENCE.md

  ## Structures

  | Item | Kind |
  |---|---|
  | `hdr_ack` | `:struct` |
  | `hdr_data` | `:struct` |

  ```
  | Item |
  |---|
  | `hdr_fenced` |
  ```

  ## Functions

  | Kind | Item |
  |---|---|
  | `:function` | hdr_send |
  | `:function` | |
  """

  @spec_text """
  # 1. Wire
  `hdr_ack` and `hdr_send` are the reference's. `hdr_typo` names nothing.
  `hdr_daemon` is the userspace daemon. `hdr_fenced` sits in a fence.
  """

  defp ext_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp ext_project(root, known_external) do
    ext_write(root, "REFERENCE.md", @golden)
    ext_write(root, "spec.md", @spec_text)

    ext_write(
      root,
      ".surfex.exs",
      inspect(sources: ["spec.md"], shape: ~r/^hdr_/, known_external: known_external)
    )

    Path.join(root, ".surfex.exs")
  end

  defp ext_cites(root) do
    config = Config.read!(Path.join(root, ".surfex.exs"))
    profile = Config.profile!(config, "App")
    root |> then(&Cite.citations([], profile, &1)) |> Map.new(&{&1.span, &1})
  end

  describe "Surfex.Profile.external_from_golden/3" do
    @tag verifies: ["golden-vocabulary", "external-golden"]
    test "every table with the column gives its cells' names, reasons naming the path", %{
      tmp_dir: root
    } do
      ext_write(root, "REFERENCE.md", @golden)

      assert Profile.external_from_golden("REFERENCE.md", "Item", root: root) ==
               {:ok,
                %{
                  "hdr_ack" => "listed in REFERENCE.md",
                  "hdr_data" => "listed in REFERENCE.md",
                  "hdr_send" => "listed in REFERENCE.md"
                }}
    end

    test "a missing file, an unknown column and an empty column are errors, never raised", %{
      tmp_dir: root
    } do
      ext_write(root, "EMPTY.md", "| Item | Kind |\n|---|---|\n|  | x |\n")
      ext_write(root, "REFERENCE.md", @golden)

      assert {:error, "GONE.md can't be read: " <> _} =
               Profile.external_from_golden("GONE.md", "Item", root: root)

      assert Profile.external_from_golden("REFERENCE.md", "Symbol", root: root) ==
               {:error, ~s(REFERENCE.md has no table with a column "Symbol")}

      assert Profile.external_from_golden("EMPTY.md", "Item", root: root) ==
               {:error, ~s(EMPTY.md's column "Item" names nothing)}
    end
  end

  describe "known_external: with a golden" do
    test "a listed name is external with the golden's path as its reason; an unlisted one is broken",
         %{tmp_dir: root} do
      ext_project(root, [{:golden, "REFERENCE.md", column: "Item"}])
      cites = ext_cites(root)

      assert %{status: :external, why: "listed in REFERENCE.md"} = cites["hdr_ack"]
      assert %{status: :external, why: "listed in REFERENCE.md"} = cites["hdr_send"]
      assert %{status: :unresolved} = cites["hdr_typo"]
      assert %{status: :unresolved} = cites["hdr_daemon"]
      # A table inside a fenced code block is no table of the golden.
      assert %{status: :unresolved} = cites["hdr_fenced"]
    end

    test "a name the golden stops listing is broken again", %{tmp_dir: root} do
      ext_project(root, [{:golden, "REFERENCE.md", column: "Item"}])
      assert %{status: :external} = ext_cites(root)["hdr_ack"]

      ext_write(root, "REFERENCE.md", String.replace(@golden, "| `hdr_ack` | `:struct` |\n", ""))
      assert %{status: :unresolved} = ext_cites(root)["hdr_ack"]
    end

    test "the map form works as before, and the two forms combine, the first listing giving the reason",
         %{tmp_dir: root} do
      ext_project(root, %{"hdr_daemon" => "userspace"})
      assert %{status: :external, why: "userspace"} = ext_cites(root)["hdr_daemon"]
      assert %{status: :unresolved} = ext_cites(root)["hdr_ack"]

      ext_project(root, [
        %{"hdr_daemon" => "userspace", "hdr_ack" => "the wire's"},
        {:golden, "REFERENCE.md", column: "Item"}
      ])

      cites = ext_cites(root)
      assert %{status: :external, why: "userspace"} = cites["hdr_daemon"]
      assert %{status: :external, why: "the wire's"} = cites["hdr_ack"]
      assert %{status: :external, why: "listed in REFERENCE.md"} = cites["hdr_send"]
    end

    test "a contract naming a golden's module is external, with the golden's path as its reason",
         %{tmp_dir: root} do
      ext_write(root, "REFERENCE.md", "| Item |\n|---|\n| `Peer.Api` |\n")
      ext_write(root, "lib/feed.ex", "defmodule MyApp.Feed do\n  def feed(f), do: f\nend\n")

      ext_write(
        root,
        "spec.md",
        "# 1. Peer\n\n```elixir contract\n@spec Peer.Api.run(t) :: t\n```\n"
      )

      ext_write(
        root,
        ".surfex.exs",
        inspect(
          sources: ["spec.md"],
          namespace: "MyApp",
          known_external: [{:golden, "REFERENCE.md", column: "Item"}]
        )
      )

      config = Config.read!(Path.join(root, ".surfex.exs"))
      items = Config.items(config, root)
      profile = Config.profile!(config, nil, items)

      assert [%{span: "Peer.Api.run/1", status: :external, why: "listed in REFERENCE.md"}] =
               Cite.Contracts.citations(Config.scans(config, root), items, profile)
    end

    @tag verifies: ["golden-vocabulary", "external-golden", "config-keys"]
    test "a missing file, an unknown column and an empty column are refused together", %{
      tmp_dir: root
    } do
      ext_write(root, "EMPTY.md", "| Item |\n|---|\n| |\n")

      path =
        ext_project(root, [
          {:golden, "GONE.md", column: "Item"},
          {:golden, "REFERENCE.md", column: "Symbol"},
          {:golden, "EMPTY.md", column: "Item"}
        ])

      error = assert_raise ArgumentError, fn -> Config.read!(path) end
      [head | lines] = String.split(error.message, "\n")
      assert head == "#{path}: 3 refusals:"

      assert [
               ~s(  known_external: {:golden, "GONE.md", [column: "Item"]}: GONE.md can't be read: ) <>
                 _,
               ~s(  known_external: {:golden, "REFERENCE.md", [column: "Symbol"]}: REFERENCE.md has no table with a column "Symbol"),
               ~s(  known_external: {:golden, "EMPTY.md", [column: "Item"]}: EMPTY.md's column "Item" names nothing)
             ] = lines
    end

    test "a malformed entry is refused naming it, and a config built in code can't read a golden",
         %{tmp_dir: root} do
      path = ext_project(root, [{:golden, "REFERENCE.md", "Item"}])
      error = assert_raise ArgumentError, fn -> Config.read!(path) end
      assert error.message =~ ~s(known_external: an entry must be a map of name => reason)
      assert error.message =~ ~s(got {:golden, "REFERENCE.md", "Item"})

      config = [sources: ["spec.md"], known_external: [{:golden, "REFERENCE.md", column: "Item"}]]

      assert_raise ArgumentError, ~r/read from its file by Surfex.Status.Config.read!\/1/, fn ->
        Config.profile!(config, "App")
      end
    end
  end
end
