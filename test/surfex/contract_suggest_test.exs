defmodule Surfex.ContractSuggestTest do
  # #314 (for #287): a contract's key names its function, so suggest pairs the contract
  # with the code item of that key, with or without claims: (§15.3).
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Item, Record, Scan, Suggest}
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  @meta [by: "tester", at: "2026-10-16T10:00:00Z"]

  @spec_md """
  # 1. `App.Feed`

  The feed's functions; `App.Other.reset/1` is another's.

  ```elixir contract
  @spec feed(t, binary) :: t
  @spec reset(t) :: t
  @callback handle(t) :: t
  ```
  """

  defp cs_code(id),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "h",
      role: :function,
      location: %{file: "lib/feed.ex", lines: {1, 1}}
    }

  defp cs_world(root, code) do
    File.write!(Path.join(root, "spec.md"), @spec_md)
    Markdown.records(root, ["spec.md"]) ++ Enum.map(code, &cs_code/1)
  end

  defp cs_suggest(root, scans, entries) do
    profile = Config.profile!([sources: ["spec.md"]], "App")

    other = %Item{
      kind: :function,
      name: "reset/1",
      parent: "App.Other",
      file: "lib/o.ex",
      hash: "h"
    }

    Suggest.all(profile, [other], scans, entries, root)
  end

  defp cs_pairs(s), do: Enum.map(s.implements, &{&1.spec.id, &1.code.id, &1.cited_at})

  @tag verifies: ["contract-own-function", "contract-suggestions"]
  test "a contract and the code of its key are proposed, cited at the contract", %{
    tmp_dir: root
  } do
    scans = cs_world(root, ["App.Feed.feed/2", "App.Feed.callback:handle/1", "App.Other.reset/1"])

    # Listed before the citation-derived candidate, though its section sorts first; reset/1
    # has no code of its own key, and another module's reset is not it.
    expected = [
      {"spec.md#App.Feed.callback:handle/1", "App.Feed.callback:handle/1", {"spec.md", 8}},
      {"spec.md#App.Feed.feed/2", "App.Feed.feed/2", {"spec.md", 6}},
      {"spec.md#1. `App.Feed`", "App.Other.reset/1", {"spec.md", 3}}
    ]

    assert cs_pairs(cs_suggest(root, scans, [])) == expected
  end

  @tag verifies: ["contract-own-function", "contract-suggestions"]
  test "a pair related in any state, retired included, is not proposed again", %{tmp_dir: root} do
    scans = cs_world(root, ["App.Feed.feed/2"])

    {:ok, related} =
      Record.relate(
        scans,
        [],
        "spec:spec.md#App.Feed.feed/2",
        "code:App.Feed.feed/2",
        :implements,
        @meta
      )

    assert cs_suggest(root, scans, related).implements == []

    {:ok, retired} =
      Record.retire(
        scans,
        related,
        "spec:spec.md#App.Feed.feed/2",
        "code:App.Feed.feed/2",
        :implements,
        Keyword.put(@meta, :note, "not this one")
      )

    assert cs_suggest(root, scans, related ++ retired).implements == []

    # No code of its key: nothing.
    assert cs_suggest(root, cs_world(root, []), []).implements == []
  end
end
