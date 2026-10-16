defmodule Surfex.TableStarTest do
  # #286: a table-driven test declares every row of a marked table with `TABLE/*`, as a
  # check could, whatever form declares it and with or without `unit_refs:` (§11.16).
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.Status
  alias Surfex.Status.Config

  @spec_md """
  # 04 Expressions

  ## ICMP types

  <!-- surfex: table icmp -->
  | Type | Code |
  |---|---|
  | echo-reply | 0 |
  | unreachable | 3 |
  | echo-request | 8 |

  ## Other

  Prose.
  """

  defp project(root, tags, spec \\ @spec_md) do
    files = %{
      "spec/04-expressions.md" => spec,
      "test/icmp_test.exs" => """
      defmodule IcmpTest do
        use ExUnit.Case
        #{tags}
        test "every type encodes" do
          assert true
        end
      end
      """
    }

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end

    root
  end

  defp config(extra \\ []), do: [sources: ["spec/*.md"], tests: ["test/*_test.exs"]] ++ extra

  defp declared(root, config) do
    [test] = for %{kind: :test} = t <- Config.scans(config, root), do: t
    test.declares
  end

  defp rows(ids), do: for(id <- ids, do: {:verifies, "spec/04-expressions.md#icmp/" <> id})

  describe "TABLE/* in a test's declaration" do
    @describetag verifies: ["table-star-declarations", "table-star-section"]

    test "a verifies tag of TABLE/* declares each row, none broken", %{tmp_dir: root} do
      project(root, ~s(@tag verifies: ["spec/04-expressions.md#icmp/*"]))

      assert declared(root, config()) == rows(~w(echo-reply echo-request unreachable))

      status = Config.status(config(), root, "Icmp", [])
      assert status.broken == []

      # Declared but not yet recorded: listed as such (§13.1), not credited.
      assert length(status.unrecorded) == 3
      assert Status.failing?(status)
    end

    test "a row added to the table is declared with no edit to the test", %{tmp_dir: root} do
      project(root, ~s(@tag verifies: ["spec/04-expressions.md#icmp/*"]))
      [before] = for %{kind: :test} = t <- Config.scans(config(), root), do: t.hash

      added =
        String.replace(@spec_md, "| echo-request | 8 |", "| echo-request | 8 |\n| redirect | 5 |")

      File.write!(Path.join(root, "spec/04-expressions.md"), added)

      assert declared(root, config()) == rows(~w(echo-reply echo-request redirect unreachable))
      # The test's version is its own: the table grew, the test didn't change.
      assert [^before] = for(%{kind: :test} = t <- Config.scans(config(), root), do: t.hash)
    end

    test "a declares: form and a unit_refs: form of the table expand too", %{tmp_dir: root} do
      project(root, ~s(@tag validates: ["§04.icmp/*"]))

      config =
        config(
          declares: [verifies: [{:tag, :validates}]],
          unit_refs: [~r/^§(?<chapter>\d\d)\.(?<id>[\w.-]+)$/]
        )

      assert declared(root, config) == rows(~w(echo-reply echo-request unreachable))
    end

    test "/* on something that is no marked table stays broken", %{tmp_dir: root} do
      project(root, ~s(@tag verifies: ["spec/04-expressions.md#Other/*"]))

      assert declared(root, config()) == [{:verifies, "spec/04-expressions.md#Other/*"}]

      assert [%{ref: "spec/04-expressions.md#Other/*"}] =
               Config.status(config(), root, "Icmp", []).broken
    end
  end
end
