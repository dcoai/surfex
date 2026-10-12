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
    @describetag verifies: ["scan-records-pure"]

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
    @describetag verifies: ["scan-records-pure"]

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
    @tag verifies: ["scan-records-pure"]
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

    # #137: a shape (a type) stays one in its code record, which is what confirm and
    # status read.
    @tag verifies: ["scan-records-pure"]
    test "a shape's code record is a shape" do
      type = %Item{kind: :type, name: "t:M.t/0", file: "lib/m.ex", hash: "y", shape: true}
      fun = %Item{kind: :function, name: "t/0", parent: "M", file: "lib/m.ex", hash: "f"}

      assert [%Scan{id: "M.t/0", shape: false}, %Scan{id: "t:M.t/0", role: :type, shape: true}] =
               Scan.code([type, fun])
    end

    # #60: two items sharing a key are two relation ends.
    @tag verifies: ["scan-records-pure"]
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
      # Each is its own definition: they differ in file and version.
      refute Scan.definition(Enum.at(scans, 1)) == Scan.definition(Enum.at(scans, 2))

      # A function's default arities are one definition: same file, lines and version.
      arities =
        for n <- ["f/1", "f/2"],
            do: %Item{
              kind: :function,
              name: n,
              parent: "M",
              file: "m.ex",
              hash: "9",
              lines: {2, 4}
            }

      [f1, f2] = Scan.code(arities)
      assert Scan.definition(f1) == Scan.definition(f2)
      assert Scan.definition(f1) == {:code, "m.ex", {2, 4}, "9"}
    end

    @tag verifies: ["scan-records-pure"]
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

    @tag verifies: ["elixir-scanner-items"]
    test "the Elixir scanner's items span their clauses" do
      items = Surfex.Scanner.Elixir.items(Path.expand("../fixtures/elixir_project", __DIR__))
      by_key = Map.new(items, &{Item.key(&1), &1})
      assert by_key["MyApp.Cart.add/2"].lines == {5, 7}
      assert by_key["MyApp.Cart"].lines == {1, 28}
    end

    @tag verifies: ["public-definitions"]
    test "line_range/1 spans a node, and is nil without metadata" do
      assert SourceScan.line_range(:atom) == nil
      {:ok, ast} = Code.string_to_quoted("def f do\n  1\nend", token_metadata: true)
      assert SourceScan.line_range(ast) == {1, 3}
    end
  end

  # #37: anchors, marked blocks and test hints.
  describe "spec units" do
    @describetag verifies: ["scan-records-pure"]

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
      {"a bad id", "# A {#a/b}\n", "spec.md:1: anchor id \"a/b\" must be"},
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

  # #179 (B.0): a heading's id is the one its author wrote, never where it stands.
  describe "written heading ids" do
    @describetag verifies: ["heading-ids"]

    defp written_ids(text, opts \\ []),
      do: text |> Markdown.sections("spec.md", opts) |> Enum.map(& &1.id)

    test "an id comment at the end of a heading names the section, and isn't in its text" do
      text =
        "# Carts\n\n## Adding items <!-- surfex: cart-add -->\n\nAdd one.\n\n### Notes\n\nn\n"

      assert written_ids(text) == [
               "spec.md#Carts",
               "spec.md#cart-add",
               "spec.md#Carts/Adding items/Notes"
             ]

      [_, section, _] = Markdown.sections(text, "spec.md")
      assert section.named

      renamed = String.replace(text, "Adding items", "Adding lines")
      [_, again, _] = Markdown.sections(renamed, "spec.md")
      assert {again.id, again.hash} == {section.id, section.hash}
    end

    test "heading_ids: reads § ids, section numbers, or the project's regex; others keep their path" do
      signs = "## §Api.3.2 — Limits\n\ns\n\n## §Doc.4: Rules\n\nr\n\n## Notes\n\nn\n"

      assert written_ids(signs, heading_ids: :section_sign) ==
               ["spec.md#Api.3.2", "spec.md#Doc.4", "spec.md#Notes"]

      numbers = "## 1. Carts\n\nh\n\n### 1.1 Properties\n\np\n\n## Conventions\n\nc\n"

      assert written_ids(numbers, heading_ids: :section_number) ==
               ["spec.md#1", "spec.md#1.1", "spec.md#Conventions"]

      own = "## [R-7] Retries\n\nr\n"
      assert written_ids(own, heading_ids: ~r/^\[(?<id>R-\d+)\]/) == ["spec.md#R-7"]

      # Without the setting, the same headings are paths, exactly as before.
      assert written_ids(numbers) == [
               "spec.md#1. Carts",
               "spec.md#1. Carts/1.1 Properties",
               "spec.md#Conventions"
             ]
    end

    test "a written id is never numbered: a repeat is an error naming both lines" do
      assert_raise ArgumentError, ~r/spec.md:5: spec.md#1 is already the id of line 1/, fn ->
        written_ids("## 1. A\n\na\n\n## 1. B\n\nb\n", heading_ids: :section_number)
      end

      # A path still is, for compatibility.
      assert written_ids("## A\n\na\n\n## A\n\nb\n") == ["spec.md#A", "spec.md#A~2"]
    end

    test "a heading grammar must be one of the presets or a regex with an id capture" do
      assert_raise ArgumentError, ~r/needs a named capture/, fn ->
        written_ids("# A\n", heading_ids: ~r/^(\d+)/)
      end

      assert_raise ArgumentError, ~r/must be :section_sign/, fn ->
        written_ids("# A\n", heading_ids: :roman)
      end

      # The presets are regexes with the capture; no setting is no grammar.
      for preset <- [:section_sign, :section_number],
          do: assert("id" in Regex.names(Markdown.heading_grammar(preset)))

      assert Markdown.heading_grammar(nil) == nil
      assert_raise ArgumentError, fn -> Markdown.heading_grammar("§") end
    end

    test "a bare reference finds a written id, and a § id with its sign; never a path" do
      scans =
        Markdown.sections("## §Api.3.2 — Limits\n\ns\n\n## Notes\n\nn\n", "spec.md",
          heading_ids: :section_sign
        )

      assert {:ok, %{id: "spec.md#Api.3.2"}} = Surfex.Scan.resolve(scans, "Api.3.2")
      assert {:ok, %{id: "spec.md#Api.3.2"}} = Surfex.Scan.resolve(scans, "§Api.3.2")
      assert {:error, :unknown} = Surfex.Scan.resolve(scans, "Notes")
    end

    @tag :tmp_dir
    test ".surfex.exs's heading_ids: reaches the scanner", %{tmp_dir: root} do
      File.write!(Path.join(root, "spec.md"), "## §Core.00.1 — Scope\n\nw\n")

      dotfile = Path.join(root, ".surfex.exs")
      File.write!(dotfile, ~s|[sources: ["spec.md"], heading_ids: :section_sign]|)
      config = Surfex.Status.Config.read!(dotfile)

      ids = for %{kind: :spec, id: id} <- Surfex.Status.Config.scans(config, root), do: id

      assert ids == ["spec.md#Core.00.1"]

      # The same units the scanner gives with the setting passed straight to it.
      direct = Markdown.records(root, ["spec.md"], [], heading_ids: :section_sign)
      assert ids == Enum.map(direct, & &1.id)
    end
  end

  # #179 (B.0): a marked table's rows are units, keyed by what the row says.
  describe "marked tables" do
    @describetag verifies: ["table-rows"]

    @modes """
    # Selection

    Prose before.

    <!-- surfex: table modes -->

    | Mode | Started by | Extent |
    |---|---|---|
    | `:normal` | drag | anchor to focus |
    | **`:word`** | double-click | word boundaries |

    Prose after.
    """

    defp table_units(text), do: Markdown.sections(text, "spec.md")
    defp table_unit(text, id), do: Enum.find(table_units(text), &(&1.id == "spec.md#" <> id))

    test "the table and each row are units, keyed by the first column without code or emphasis" do
      assert [
               %{id: "spec.md#Selection", role: :section},
               %{id: "spec.md#modes", role: :table, within: "spec.md#Selection"},
               %{id: "spec.md#modes/:normal", role: :row, within: "spec.md#modes"},
               %{id: "spec.md#modes/:word", role: :row, within: "spec.md#modes"}
             ] = table_units(@modes)

      assert table_unit(@modes, "modes/:word").location.lines == {10, 10}

      # Unmarked, the same table is body, as before.
      assert [%{id: "spec.md#Selection"}] =
               table_units(String.replace(@modes, "<!-- surfex: table modes -->\n", ""))
    end

    test "key: names the key column; a key may hold spaces, and a code span may hold a pipe" do
      text = """
      # S

      <!-- surfex: table ops key: Started by -->
      | Mode | Started by |
      |:---|---:|
      | a | double click |
      | b | `x|y` |
      """

      ids = for %{role: :row, id: id} <- table_units(text), do: id
      assert ids == ["spec.md#ops/double click", "spec.md#ops/x|y"]
    end

    test "editing a row changes only that row's version, not the table's or the section's" do
      before = Map.new(table_units(@modes), &{&1.id, &1.hash})
      edited = String.replace(@modes, "anchor to focus", "anchor to the focus")
      after_edit = Map.new(table_units(edited), &{&1.id, &1.hash})

      changed = for {id, hash} <- after_edit, before[id] != hash, do: id
      assert changed == ["spec.md#modes/:normal"]

      # The prose around the table is still the section's.
      reworded = String.replace(@modes, "Prose after.", "Other prose.")
      refute table_unit(reworded, "Selection").hash == before["spec.md#Selection"]
    end

    test "a table may sit in a block, and ends at the first line that isn't a table line" do
      text = """
      # S

      <!-- surfex: rule -->
      <!-- surfex: table t -->
      | K | V |
      |---|---|
      | a | 1 |
      Still the rule.
      <!-- /surfex -->
      """

      assert %{within: "spec.md#rule"} = table_unit(text, "t")
      assert %{within: "spec.md#t"} = table_unit(text, "t/a")
      rule = table_unit(text, "rule")

      refute rule.hash ==
               table_unit(String.replace(text, "Still the rule.", "Changed."), "rule").hash
    end

    @table_errors [
      {"a marker with no table", "# S\n\n<!-- surfex: table t -->\n\nprose\n",
       "spec.md:3: table t has no table after its marker"},
      {"a marker at the end", "# S\n<!-- surfex: table t -->\n",
       "spec.md:2: table t has no table after its marker"},
      {"no separator row", "# S\n<!-- surfex: table t -->\n| K |\n| a |\n",
       "spec.md:4: table t has no separator row under its header"},
      {"an unknown key column", "# S\n<!-- surfex: table t key: Nope -->\n| K |\n|---|\n| a |\n",
       "spec.md:2: table t has no column \"Nope\""},
      {"an empty key", "# S\n<!-- surfex: table t -->\n| K | V |\n|---|---|\n|  | 1 |\n",
       "spec.md:5: a row of table t has an empty key"},
      {"a repeated key", "# S\n<!-- surfex: table t -->\n| K |\n|---|\n| a |\n| `a` |\n",
       "spec.md:6: spec.md#t/a is already the id of line 5"}
    ]

    for {name, text, message} <- @table_errors do
      test "raises on #{name}" do
        error = assert_raise ArgumentError, fn -> table_units(unquote(text)) end
        assert error.message =~ unquote(message)
      end
    end
  end
end
