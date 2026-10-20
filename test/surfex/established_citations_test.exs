defmodule Surfex.EstablishedCitationsTest do
  # #321 (plan v2 D.3): a citation says how it was made (§6.10), and once the log holds a
  # validated implements a code span in prose stops proposing one outside a contract;
  # subject headings, citing cells, contracts and a claim's tests still do (§15.4).
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.{Cite, Item, Scan, Suggest}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  @ec_spec """
  # Feed
  <!-- surfex: feed -->

  The feed is built by `App.Feed.build/1`.

  | Function | Meaning |
  |---|---|
  | App.Feed.reset/1 | resets it |

  # App.Cart
  <!-- surfex: cart -->

  A cart holds lines.

  ```test:cart-hint
  adding a line puts it in the cart
  ```
  """

  defp ec_item(name, parent, kind \\ :function),
    do: %Item{kind: kind, name: name, parent: parent, file: "lib/a.ex", hash: "h"}

  defp ec_items,
    do: [
      ec_item("build/1", "App.Feed"),
      ec_item("reset/1", "App.Feed"),
      ec_item("App.Cart", nil, :module),
      ec_item("add/2", "App.Cart"),
      ec_item("done/0", "App.Other")
    ]

  defp ec_code(id, role),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "h",
      role: role,
      location: %{file: "lib/a.ex", lines: {1, 1}}
    }

  defp ec_world(root) do
    File.write!(Path.join(root, "spec.md"), @ec_spec)

    Markdown.records(root, ["spec.md"]) ++
      Enum.map(
        ~w(App.Feed.build/1 App.Feed.reset/1 App.Cart.add/2 App.Other.done/0),
        &ec_code(&1, :function)
      ) ++
      [
        ec_code("App.Cart", :module),
        %Scan{
          kind: :test,
          id: "T: adds",
          hash: "t",
          location: %{file: "test/a_test.exs", lines: {1, 1}},
          declares: [{:verifies, "cart-hint"}],
          calls: ["App.Cart.add/2"]
        }
      ]
  end

  defp ec_profile,
    do:
      Config.profile!(
        [
          sources: ["spec.md"],
          subjects: [%{file: "spec.md", heading: ~r/^App\.Cart$/, items: ["App.Cart"]}],
          table_columns: ["Function"]
        ],
        "App"
      )

  # A validated implements of another pair: what makes the log established.
  defp ec_validated(scans, basis \\ :review) do
    hint = Enum.find(scans, &(&1.id == "spec.md#cart-hint"))

    Entry.new!(
      at: "2026-10-20T10:00:00Z",
      op: :relate,
      type: :implements,
      basis: basis,
      note: "reviewed",
      ends: [
        %{kind: :code, id: "App.Other.done/0", hash: "h"},
        %{kind: :spec, id: hint.id, hash: hint.hash}
      ]
    )
  end

  defp ec_pairs(candidates), do: candidates |> Enum.map(&{&1.spec.id, &1.code.id}) |> Enum.sort()

  @tag verifies: ["citation-kind", "citation-kinds"]
  test "a citation says whether it is a span, a subject heading or a citing cell", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "spec.md"), @ec_spec)
    kinds = for c <- Cite.citations(ec_items(), ec_profile(), root), do: {c.span, c.kind}

    assert {"App.Feed.build/1", :span} in kinds
    assert {"App.Feed.reset/1", :cell} in kinds
    assert {"App.Cart", :subject} in kinds
  end

  @tag verifies: ["established-log", "established-citations"]
  test "an empty log keeps the bootstrap: every resolved citation proposes", %{tmp_dir: root} do
    scans = ec_world(root)
    refute Suggest.established?([])

    assert ec_pairs(Suggest.candidates(ec_profile(), ec_items(), scans, [], root)) == [
             {"spec.md#cart", "App.Cart"},
             {"spec.md#feed", "App.Feed.build/1"},
             {"spec.md#feed", "App.Feed.reset/1"}
           ]

    # The claim's tests propose too, and nothing is withheld.
    s = Suggest.all(ec_profile(), ec_items(), scans, [], root)
    assert {"spec.md#cart-hint", "App.Cart.add/2"} in ec_pairs(s.implements)
    assert s.withheld == []
  end

  @tag verifies: ["established-log", "established-citations"]
  test "an established log: a prose span proposes nothing; subjects, cells, contracts and claims still do",
       %{tmp_dir: root} do
    scans = ec_world(root)
    log = [ec_validated(scans)]
    assert Suggest.established?(log)

    assert ec_pairs(Suggest.candidates(ec_profile(), ec_items(), scans, log, root)) == [
             {"spec.md#cart", "App.Cart"},
             {"spec.md#feed", "App.Feed.reset/1"}
           ]

    s = Suggest.all(ec_profile(), ec_items(), scans, log, root)

    assert ec_pairs(s.implements) == [
             {"spec.md#cart", "App.Cart"},
             {"spec.md#cart-hint", "App.Cart.add/2"},
             {"spec.md#feed", "App.Feed.reset/1"}
           ]

    assert s.withheld == [
             %{spec: "spec.md#feed", span: "App.Feed.build/1", cited_at: {"spec.md", 4}}
           ]

    # A span inside a contract unit states the code, so it still proposes: the unit's
    # role decides, not the text.
    contract =
      Enum.map(scans, &if(&1.id == "spec.md#feed", do: %{&1 | role: :contract}, else: &1))

    assert {"spec.md#feed", "App.Feed.build/1"} in ec_pairs(
             Suggest.candidates(ec_profile(), ec_items(), contract, log, root)
           )
  end

  @tag verifies: ["established-log", "established-citations"]
  test "a proposed implements doesn't establish the log, and retiring the last validated one ends it",
       %{tmp_dir: root} do
    scans = ec_world(root)
    refute Suggest.established?([ec_validated(scans, :proposed)])

    validated = ec_validated(scans)
    [_, hint] = validated.ends

    retired =
      Entry.new!(
        at: "2026-10-20T11:00:00Z",
        op: :retire,
        type: :implements,
        parents: [validated.id],
        note: "not this code",
        ends: [%{kind: :code, id: "App.Other.done/0", hash: "h"}, hint]
      )

    log = [validated, retired]
    refute Suggest.established?(log)

    assert {"spec.md#feed", "App.Feed.build/1"} in ec_pairs(
             Suggest.candidates(ec_profile(), ec_items(), scans, log, root)
           )
  end

  @tag verifies: ["claim-implements-refused", "claim-implements"]
  test "a .surfex.exs with claim_implements: is refused, either value, with the upgrade sentence",
       %{tmp_dir: root} do
    path = Path.join(root, ".surfex.exs")

    for value <- [true, false] do
      File.write!(path, ~s([sources: ["spec.md"], claim_implements: #{value}]))
      error = assert_raise ArgumentError, fn -> Config.read!(path) end
      assert error.message =~ "claim_implements: is no longer a key"
      assert error.message =~ "always proposes implements from what a claim's tests call"
      assert error.message =~ "the CHANGELOG's upgrade step"
      refute error.message =~ "unknown keys"
    end
  end
end
