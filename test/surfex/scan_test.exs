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

    @tag verifies: "section-versions"
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
      root = Path.expand("../fixtures/reference/sources", __DIR__)
      ids = root |> Markdown.records(["spec/*.md"]) |> Enum.map(& &1.id)
      assert "spec/02-wire.md#02 — Wire format/2. Packet types" in ids
      assert Enum.all?(ids, &String.starts_with?(&1, "spec/"))
    end

    defp text_ids(text), do: text |> Markdown.sections("spec.md") |> Enum.map(& &1.id)
  end

  # #39: fences follow CommonMark. Each case is a body under `# A`; `# H` must stay in it
  # when it is inside a fence, and becomes a section of its own when it isn't.
  describe "code fences" do
    @inside [
      {"a longer fence quoting a shorter one", "````\n```\n# H\n```\n````"},
      {"a tilde fence", "~~~\n# H\n~~~"},
      {"a tilde fence quoting backticks", "~~~\n```\n# H\n~~~"},
      {"a backtick fence quoting tildes", "```\n~~~\n# H\n```"},
      {"a fence indented three spaces", "   ```\n# H\n   ```"},
      {"a fence with an info string", "```elixir\n# H\n```"},
      {"a closing line followed by text does not close", "```\n``` not a close\n# H\n```"},
      {"a shorter line does not close", "`````\n````\n# H\n`````"},
      {"an unclosed fence runs to the end", "```\n# H"}
    ]

    for {name, body} <- @inside do
      @tag verifies: "fence-rule"
      test "inside: #{name}" do
        text = "# A\n\n" <> unquote(body) <> "\n"
        assert text_ids(text) == ["spec.md#A"]
        # The fenced `# H` is body text, so it counts in A's version.
        refute hash_of(text) == hash_of(String.replace(text, "# H", "# I"))
      end
    end

    @outside [
      {"an indented block is not a fence", "    ```\n# H"},
      {"a backtick in the info string is not a fence", "``` a`b\n# H"},
      {"a closed fence ends", "````\nx\n````\n# H"},
      {"a longer line closes", "```\nx\n`````\n# H"}
    ]

    for {name, body} <- @outside do
      @tag verifies: "fence-rule"
      test "outside: #{name}" do
        assert text_ids("# A\n\n" <> unquote(body) <> "\n") == ["spec.md#A", "spec.md#H"]
      end
    end

    defp hash_of(text), do: hd(Markdown.sections(text, "spec.md")).hash
  end

  describe "code records" do
    test "carry the item's key, version, location, kind and parent" do
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
                 location: %{file: "lib/m.ex", lines: {3, 5}},
                 role: :function,
                 within: "M"
               }
             ]
    end

    # #60: two items sharing a key are two relation ends.
    test "items sharing a key get ids that carry their kind; a unique key keeps its own" do
      items = [
        %Item{kind: :function, name: "twin", file: "a.c", hash: "1"},
        %Item{kind: :const, name: "twin", file: "a.h", hash: "2"},
        %Item{kind: :function, name: "alone", file: "a.c", hash: "3"}
      ]

      scans = Scan.code(items)
      assert Enum.map(scans, & &1.id) == ["alone", "twin (const)", "twin (function)"]
      assert %Scan{id: "twin (const)"} = Scan.for_item(scans, Enum.at(items, 1))
      assert %Scan{id: "alone"} = Scan.for_item(scans, Enum.at(items, 2))
    end

    test "status refuses two records with one kind and id, naming where they are" do
      twin = %Scan{kind: :code, id: "twin", hash: "1", location: %{file: "a.c", lines: {1, 2}}}

      assert_raise ArgumentError,
                   ~r/two code records have the id "twin" \(a.c:\{1, 2\}, b.c/,
                   fn ->
                     Surfex.Status.derive(
                       [twin, %{twin | location: %{file: "b.c", lines: {3, 4}}}],
                       []
                     )
                   end
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

  # #37: anchors, marked blocks and test hints.
  describe "spec units" do
    @units """
    # Carts {#carts}

    A cart holds items.

    ## Adding items {#cart-add}

    Adding puts an item in.

    <!-- surfex: cart-add-closed -->
    A closed cart rejects a new line with `{:error, :closed}`.

    ```test cart-add-closed-test
    given a closed cart
    when a line is added
    then {:error, :closed}
    ```
    <!-- /surfex -->

    ```test cart-add-qty
    add with no quantity adds one
    ```

    ```test
    an ordinary code block
    ```

    ### Notes

    Aside.
    """

    defp units(text \\ @units), do: Markdown.sections(text, "spec.md")
    defp unit(text \\ @units, id), do: Enum.find(units(text), &(&1.id == "spec.md#" <> id))

    test "each unit is a record with its role and what it sits in, in order" do
      assert Enum.map(units(), &{&1.id, &1.role, &1.within}) == [
               {"spec.md#carts", :section, nil},
               {"spec.md#cart-add", :section, nil},
               {"spec.md#cart-add-closed", :block, "spec.md#cart-add"},
               {"spec.md#cart-add-closed-test", :test_hint, "spec.md#cart-add-closed"},
               {"spec.md#cart-add-qty", :test_hint, "spec.md#cart-add"},
               {"spec.md#Carts/Adding items/Notes", :section, nil}
             ]
    end

    test "locations: a block from marker to marker, a hint from fence to fence" do
      assert unit("cart-add-closed").location.lines == {9, 17}
      assert unit("cart-add-closed-test").location.lines == {12, 16}
      assert unit("cart-add-qty").location.lines == {19, 21}
      assert unit("cart-add").location.lines == {5, 25}
    end

    test "an anchor names the section whatever its heading says, and isn't hashed" do
      renamed =
        String.replace(@units, "## Adding items {#cart-add}", "## Adding lines {#cart-add}")

      assert unit(renamed, "cart-add").hash == unit("cart-add").hash
      # Its subsections keep heading paths, which follow the heading text.
      assert unit(renamed, "Carts/Adding lines/Notes")
    end

    @tag verifies: "unit-versions"
    test "editing a block or a hint changes only its own version" do
      base = Map.new(units(), &{&1.id, &1.hash})

      changed = fn from, to ->
        edited = Map.new(units(String.replace(@units, from, to)), &{&1.id, &1.hash})
        for {id, hash} <- base, edited[id] != hash, do: id
      end

      assert changed.("rejects a new line", "refuses a new line") == ["spec.md#cart-add-closed"]

      assert changed.("when a line is added", "when a line is put") == [
               "spec.md#cart-add-closed-test"
             ]

      assert changed.("adds one", "adds 1") == ["spec.md#cart-add-qty"]
      assert changed.("Adding puts an item in.", "Adding puts it in.") == ["spec.md#cart-add"]
      # A plain `test` fence is the section's own text.
      assert changed.("an ordinary code block", "a code block") == ["spec.md#cart-add"]
    end

    test "markers and hints inside a fence are text" do
      quoted =
        "# S\n\n````markdown\n<!-- surfex: x -->\n```test y\nz\n```\n<!-- /surfex -->\n````\n"

      assert Enum.map(units(quoted), & &1.id) == ["spec.md#S"]
    end

    test "a spec using none of them scans exactly as before" do
      plain = "# A\n\ntext\n\n## B\n\nmore\n"
      assert Enum.all?(units(plain), &(&1.role == :section and &1.within == nil))
      assert Enum.map(units(plain), & &1.id) == ["spec.md#A", "spec.md#A/B"]
    end

    test "a preamble holding only a block is kept, so the block has somewhere to sit" do
      assert [%{id: "spec.md#(preamble)"}, %{id: "spec.md#r", within: "spec.md#(preamble)"} | _] =
               units("<!-- surfex: r -->\nA rule.\n<!-- /surfex -->\n\n# A\n\ntext\n")
    end

    @errors [
      {"an unclosed block", "# A\n<!-- surfex: a -->\ntext\n",
       "spec.md:2: block a is never closed"},
      {"a block spanning a heading", "# A\n<!-- surfex: a -->\n# B\n<!-- /surfex -->\n",
       "spec.md:3: block a (line 2) spans a heading"},
      {"a nested block", "# A\n<!-- surfex: a -->\n<!-- surfex: b -->\n",
       "spec.md:3: block b opens inside block a (line 2)"},
      {"a close with no block", "# A\n<!-- /surfex -->\n",
       "spec.md:2: <!-- /surfex --> closes no block"},
      {"an unclosed hint", "# A\n```test h\nx\n", "spec.md:2: test hint h is never closed"},
      {"a bad id", "# A {#Not_Ok}\n", "spec.md:1: anchor id \"Not_Ok\" must be"},
      {"a duplicate id", "# A {#x}\n\n```test x\ny\n```\n",
       "spec.md:3: spec.md#x is already the id of line 1"},
      {"an anchor colliding with a heading path", "# x\n\n# B {#x}\n",
       "spec.md:3: spec.md#x is already the id of line 1"}
    ]

    for {name, text, message} <- @errors do
      test "raises on #{name}" do
        error = assert_raise ArgumentError, fn -> units(unquote(text)) end
        assert error.message =~ unquote(message)
      end
    end
  end
end
