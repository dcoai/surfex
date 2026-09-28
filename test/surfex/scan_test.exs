defmodule Surfex.ScanTest do
  use ExUnit.Case, async: true

  alias Surfex.{Item, Scan, SourceScan}
  alias Surfex.Scan.Markdown

  @spec_md """
  Intro text before any heading.

  # Carts

  A cart holds items.

  ## Adding items

  `add` puts an item in.

  ```sh
  # not a heading
  ```

  ## Totals

  Counts them.

  # Carts

  A second top-level section with the same heading.
  """

  defp by_id(text), do: text |> Markdown.sections("spec.md") |> Map.new(&{&1.id, &1})

  describe "markdown sections" do
    test "one record per section, identified by file and heading path" do
      assert text_ids(@spec_md) == [
               "spec.md#(preamble)",
               "spec.md#Carts",
               "spec.md#Carts/Adding items",
               "spec.md#Carts/Totals",
               "spec.md#Carts~2"
             ]
    end

    test "a heading inside a fence is body, not a section" do
      refute Enum.any?(text_ids(@spec_md), &String.contains?(&1, "not a heading"))
    end

    test "locations run from the heading to the last non-blank line" do
      sections = by_id(@spec_md)
      assert sections["spec.md#Carts"].location == %{file: "spec.md", lines: {3, 5}}
      assert sections["spec.md#Carts/Adding items"].location.lines == {7, 13}
      assert sections["spec.md#(preamble)"].location.lines == {1, 1}
    end

    test "the hash is over the body: not the heading, not subsections, not whitespace" do
      base = by_id(@spec_md)

      renamed = by_id(String.replace(@spec_md, "## Totals", "## Sums"))
      assert renamed["spec.md#Carts/Sums"].hash == base["spec.md#Carts/Totals"].hash

      sub_edit = by_id(String.replace(@spec_md, "Counts them.", "Counts them all."))
      assert sub_edit["spec.md#Carts"].hash == base["spec.md#Carts"].hash
      refute sub_edit["spec.md#Carts/Totals"].hash == base["spec.md#Carts/Totals"].hash

      reflowed =
        by_id(String.replace(@spec_md, "A cart holds items.", "A cart\n   holds   items.\n\n"))

      assert reflowed["spec.md#Carts"].hash == base["spec.md#Carts"].hash
    end

    test "a blank preamble is not a section" do
      refute "spec.md#(preamble)" in text_ids("\n\n# Only\n\ntext\n")
    end

    test "records/2 reads globs under a root, with paths relative to it" do
      root = Path.expand("../fixtures/reference_trace/sources", __DIR__)
      ids = root |> Markdown.records(["spec/*.md"]) |> Enum.map(& &1.id)
      assert "spec/02-wire.md#02 — Wire format/2. Packet types" in ids
      assert Enum.all?(ids, &String.starts_with?(&1, "spec/"))
    end

    defp text_ids(text), do: text |> Markdown.sections("spec.md") |> Enum.map(& &1.id)
  end

  describe "code records" do
    test "carry the item's key, version and location" do
      item = %Item{
        kind: :function,
        name: "add/2",
        parent: "M",
        file: "lib/m.ex",
        hash: "h",
        lines: {3, 5}
      }

      assert Scan.code([item]) == [
               %Scan{
                 kind: :code,
                 id: "M.add/2",
                 hash: "h",
                 location: %{file: "lib/m.ex", lines: {3, 5}}
               }
             ]
    end

    test "the Elixir scanner's items span their clauses" do
      items = Surfex.Scanner.Elixir.items(Path.expand("../fixtures/elixir_project", __DIR__))
      by_key = Map.new(items, &{Item.key(&1), &1})
      assert by_key["MyApp.Cart.add/2"].lines == {5, 7}
      assert by_key["MyApp.Cart"].lines == {1, 28}
    end

    test "line_range/1 spans a node, and is nil without metadata" do
      assert SourceScan.line_range(:atom) == nil
      {:ok, ast} = Code.string_to_quoted("def f do\n  1\nend", token_metadata: true)
      assert SourceScan.line_range(ast) == {1, 3}
    end
  end
end
