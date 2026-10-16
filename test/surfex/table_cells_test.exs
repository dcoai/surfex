defmodule Surfex.TableCellsTest do
  # #286: one GFM table-cell reader (`Surfex.Golden.Span`) for marked tables, the gate,
  # citations and the golden tests, and a marked table's KEY read as a reader sees it
  # (§11.15). The oracle is the GFM spec's own table and code-span examples, so a reader
  # and writer sharing one misreading can't agree with each other and pass.
  use ExUnit.Case, async: true

  alias Surfex.Golden
  alias Surfex.Golden.Span
  alias Surfex.Scan.Markdown

  # The row ids of a marked table holding `rows` (each a row's line) under header `| K | V |`.
  defp keys(rows, marker \\ "<!-- surfex: table t -->", header \\ "| K | V |") do
    text = "# S\n\n#{marker}\n#{header}\n|---|---|\n" <> Enum.join(rows, "\n") <> "\n"
    for %{role: :row, id: "s.md#t/" <> key} <- Markdown.sections(text, "s.md"), do: key
  end

  defp key(cell), do: hd(keys(["| #{cell} | x |"]))

  describe "GFM's table and code-span examples" do
    @describetag verifies: ["table-cell-reading", "table-cells-section"]

    test "rows split on every unescaped pipe, in a code span too, with or without outer pipes" do
      # GFM tables, examples 198-200.
      assert Span.cells("| foo | bar |") == ["foo", "bar"]
      assert Span.cells("bar | baz") == ["bar", "baz"]
      assert Span.cells(":-: | -----------:") == [":-:", "-----------:"]
      assert Span.cells("| f\\|oo  |") == ["f|oo"]
      assert Span.cells("| b `\\|` az |") == ["b `|` az"]
      assert Span.cells("| b **\\|** im |") == ["b **|** im"]

      # A code span gives no protection: the pipe splits.
      assert Span.cells("| `a|b` | c |") == ["`a", "b`", "c"]
      assert Span.cells("| a |  | c |") == ["a", "", "c"]
      assert Span.cells("|") == []

      # A marked table reads its rows the same way: the span's pipe ends the key cell.
      assert keys(["| `a|b` | c |", "| f\\|oo | x |"]) == ["`a", "f|oo"]
    end

    test "a code span closes at the next run of exactly its length, with no escapes inside" do
      # CommonMark code spans, examples 328-349.
      assert Span.inline("`foo`") == [{:code, "foo"}]
      assert Span.inline("`` foo ` bar ``") == [{:code, "foo ` bar"}]
      assert Span.inline("` `` `") == [{:code, "``"}]
      assert Span.inline("`  ``  `") == [{:code, " `` "}]
      assert Span.inline("` a`") == [{:code, " a"}]
      assert Span.inline("` `") == [{:code, " "}]
      assert Span.inline("`  `") == [{:code, "  "}]
      assert Span.inline("`foo\\`bar`") == [{:code, "foo\\"}, {:text, "bar`"}]
      assert Span.inline("``foo`bar``") == [{:code, "foo`bar"}]
      assert Span.inline("` foo `` bar `") == [{:code, "foo `` bar"}]
      assert Span.inline("*foo`*`") == [{:text, "*foo"}, {:code, "*"}]
      assert Span.inline("```foo``") == [{:text, "```foo``"}]
      assert Span.inline("`foo") == [{:text, "`foo"}]
      assert Span.inline("`foo``bar``") == [{:text, "`foo"}, {:code, "bar"}]
      # An escaped backtick outside a span opens nothing.
      assert Span.inline("\\`not code`") == [{:text, "\\`not code`"}]

      # And a marked table's key is the text those spans give.
      assert key("`` foo ` bar ``") == "foo ` bar"
      assert key("`foo``bar``") == "`foobar"
    end

    test "a row with ESC \\ in a span and a double-backtick span holding a backtick key as written" do
      rows = [
        "| `ESC \\` | ST | R | String terminator |",
        "| `` CSI Ps ` `` | HPA | R | Alias of CHA |"
      ]

      assert keys(rows, "<!-- surfex: table t -->", "| Seq | Name | Dir | Note |") ==
               ["ESC \\", "CSI Ps `"]

      assert Span.cells(hd(rows)) == ["`ESC \\`", "ST", "R", "String terminator"]
    end

    test "a pipe in a key's code span is written \\| and reads back as a pipe" do
      assert key("`x\\|y`") == "x|y"
      assert key("a \\| b") == "a | b"
    end

    test "every cell the golden writer writes is read back as its text, by Span and by a table" do
      alphabet = ["a", " ", "`", "|", "\\", "*", "_"]

      texts =
        Enum.flat_map(1..4, fn len ->
          Enum.reduce(1..len, [""], fn _, acc -> for t <- acc, c <- alphabet, do: t <> c end)
        end)

      rows =
        for text <- texts do
          [line] =
            %{
              name: "T.md",
              purpose: "p",
              task: "t",
              gate: "g",
              hardness: :hard,
              columns: ["Item", "Other"],
              rows: [%{"Item" => {:code, text}, "Other" => "x"}]
            }
            |> Golden.render()
            |> String.split("\n", trim: true)
            |> Enum.take(-1)

          assert [item, "x"] = Span.cells(line), inspect(text)
          assert Span.inline(item) == [{:code, text}], inspect(text)
          {text, line}
        end

      # As a marked table's key: the span's text with whitespace collapsed, one row per key
      # (texts differing only in spacing would be one id twice), a blank one aside.
      keyed =
        for {text, line} <- rows, String.trim(text) != "" do
          {text |> String.split() |> Enum.join(" "), line}
        end
        |> Enum.uniq_by(&elem(&1, 0))

      ids = keys(Enum.map(keyed, &elem(&1, 1)), "<!-- surfex: table t -->", "| Item | Other |")
      assert ids == Enum.map(keyed, &elem(&1, 0))
    end
  end

  describe "a key as a reader sees it" do
    @describetag verifies: ["table-key-text", "table-cells-section"]

    test "emphasis CommonMark reads as emphasis is dropped, inside the cell as around it" do
      assert key("Generated test *files*") == "Generated test files"
      assert key("**Mode**") == "Mode"
      assert key("*a **b** c*") == "a b c"
      assert key("foo*bar*") == "foobar"
      assert key("5*6*78") == "5678"
      assert key("_foo bar_") == "foo bar"
      assert key("foo-_(bar)_") == "foo-(bar)"
      assert key("*foo**bar**baz*") == "foobarbaz"
      assert key("__foo, __bar__, baz__") == "foo, bar, baz"
      assert key("*(*foo*)*") == "(foo)"
      assert key("**`:word`**") == ":word"
    end

    test "the rule of 3 and nearest-first pairing leave the unpaired delimiters" do
      assert key("*foo**bar*") == "foo**bar"
      assert key("**foo*") == "*foo"
      assert key("*foo**") == "foo*"
      assert key("foo***bar***baz") == "foobarbaz"
      assert key("foo******bar*********baz") == "foobar***baz"
    end

    test "an intraword _, an unpaired or spaced * and a code span's marks stay" do
      assert key("snake_case_name") == "snake_case_name"
      assert key("foo_bar_") == "foo_bar_"
      assert key("5_6_78") == "5_6_78"
      assert key("a * foo bar*") == "a * foo bar*"
      assert key("a*\"foo\"*") == "a*\"foo\"*"
      assert key("`*ptr`") == "*ptr"
      assert key("`_x_`") == "_x_"
      assert key("`a`  `b`") == "a b"
    end

    test "backslash escapes outside code spans are undone, and stay literal for emphasis" do
      assert key("\\*lit\\*") == "*lit*"
      assert key("a\\_b\\_") == "a_b_"
      assert key("`a\\*`") == "a\\*"
    end

    test "a key: header matches its header cell by the same reading" do
      text = """
      # S

      <!-- surfex: table t key: Mode -->
      | Name | *Mode* |
      |---|---|
      | a | `:normal` |
      """

      assert [%{id: "s.md#t/:normal"}] =
               for(%{role: :row} = u <- Markdown.sections(text, "s.md"), do: u)
    end
  end
end
