defmodule Surfex.ClaimFormsTest do
  @moduledoc """
  Claims smaller than a section, each a unit its author names (§11.1, #205): rules in a
  list, paragraphs. No id comes from where a claim stands.
  """
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown

  defp claim_units(text, opts \\ []), do: Markdown.sections(text, "spec.md", opts)

  defp claim_ids(text, opts \\ []),
    do: for(u <- claim_units(text, opts), u.role == :rule, do: u.id)

  defp claim_versions(text, opts),
    do: Map.new(claim_units(text, opts), &{&1.id, &1.hash})

  @claim_list """
  # Tenancy

  Tenants are kept apart.

  <!-- surfex: rules tenancy -->
  1. §Tenancy.1 A tenant reads only its own rows.
  2. §Tenancy.2 A tenant's id is fixed at creation,
     and never reused.
     - not even after deletion

  3. <!-- surfex: tenancy-audit --> Every cross-tenant read is logged.

  After the list.
  """

  describe "rules" do
    @describetag verifies: ["rule-items"]

    test "a marked list's items are rules, by their written ids or id comments" do
      units = claim_units(@claim_list, rule_ids: :section_sign)

      assert for(u <- units, u.role == :rule, do: {u.id, u.within, u.location.lines}) == [
               {"spec.md#Tenancy.1", "spec.md#Tenancy", {6, 6}},
               {"spec.md#Tenancy.2", "spec.md#Tenancy", {7, 9}},
               {"spec.md#tenancy-audit", "spec.md#Tenancy", {11, 11}}
             ]
    end

    test "a project's own rule_ids: regex reads its ids, a list of grammars the first that matches" do
      text = "# P\n\n<!-- surfex: rules principles -->\n- P3 one\n- R-4 two\n"
      grammars = [~r/^(?<id>P\d+)/, ~r/^(?<id>R-\d+)/]
      assert claim_ids(text, rule_ids: grammars) == ["spec.md#P3", "spec.md#R-4"]
    end

    test "an item with an id comment is a rule in any list, and its siblings aren't" do
      text = "# A\n\n- plain\n- <!-- surfex: no-override --> Never honour it.\n  More.\n- plain\n"
      units = claim_units(text)
      assert [%{id: "spec.md#no-override", location: %{lines: {4, 5}}}] = rules_of(units)
    end

    test "an id comment on its own line names the list item after it" do
      text = "# A\n\n- one\n\n<!-- surfex: two -->\n- two\n- three\n"
      assert [%{id: "spec.md#two", location: %{lines: {6, 6}}}] = rules_of(claim_units(text))
    end

    test "a hint inside a rule sits in the rule" do
      text = "# A\n\n- <!-- surfex: r --> A rule.\n\n  ```test:r-holds\n  it holds\n  ```\n"
      assert %{within: "spec.md#r"} = Enum.find(claim_units(text), &(&1.id == "spec.md#r-holds"))
    end

    test "a rule's version is its text and nested lines, without its marker or id comment" do
      base = claim_versions(@claim_list, rule_ids: :section_sign)

      changed = fn from, to ->
        edited = claim_versions(String.replace(@claim_list, from, to), rule_ids: :section_sign)
        for {id, hash} <- base, edited[id] != hash, do: id
      end

      assert changed.("never reused", "never recycled") == ["spec.md#Tenancy.2"]
      assert changed.("not even after", "not once after") == ["spec.md#Tenancy.2"]
      assert changed.("Every cross-tenant", "Each cross-tenant") == ["spec.md#tenancy-audit"]
      # Renumbering, or a bullet for a number, is no change.
      assert changed.("2. §Tenancy.2", "7. §Tenancy.2") == []
      # The section's own text is its own.
      assert changed.("kept apart", "held apart") == ["spec.md#Tenancy"]
    end

    @claim_errors [
      {"an item with no id", "# A\n\n<!-- surfex: rules r -->\n- §A.1 one\n- two\n",
       "spec.md:5: an item of rules r has no id"},
      {"a marker with no list", "# A\n\n<!-- surfex: rules r -->\n\ntext\n",
       "spec.md:3: rules r has no list after its marker"},
      {"a repeated rule id", "# A\n\n<!-- surfex: rules r -->\n- §A.1 one\n- §A.1 two\n",
       "spec.md:5: spec.md#A.1 is already the id of line 4"},
      {"a rule id repeating a heading's", "# A {#x}\n\n- <!-- surfex: x --> one\n",
       "spec.md:3: spec.md#x is already the id of line 1"},
      {"a rule inside a rule", "# A\n\n- <!-- surfex: a --> one\n  - <!-- surfex: b --> two\n",
       "spec.md:4: rule a (line 3) can't hold another rule"},
      {"an item with two ids", "# A\n\n<!-- surfex: a -->\n- <!-- surfex: b --> one\n",
       "spec.md:4: the list item has two ids"},
      {"a malformed id", "# A\n\n- <!-- surfex: a/b --> one\n", "spec.md:3: rule id \"a/b\""}
    ]

    for {name, text, message} <- @claim_errors do
      test "raises on #{name}" do
        error =
          assert_raise ArgumentError, fn ->
            claim_units(unquote(text), rule_ids: :section_sign)
          end

        assert error.message =~ unquote(message)
      end
    end
  end

  describe "paragraphs" do
    @describetag verifies: ["rule-paragraphs"]

    @claim_paragraphs """
    # Retirement

    A retired schema's objects are kept.

    <!-- surfex: retired-unreachable -->
    **A retired schema's objects are unreachable by construction.** Nothing
    resolves to them.

    **Bold alone is emphasis.** It is never a claim.

    <!-- surfex: retired-kept --> A retired schema is kept for audit.

    Closing text.
    """

    test "an id comment on its own line before a paragraph, or starting it, names it" do
      units = claim_units(@claim_paragraphs)

      assert for(u <- rules_of(units), do: {u.id, u.location.lines}) == [
               {"spec.md#retired-unreachable", {6, 7}},
               {"spec.md#retired-kept", {11, 11}}
             ]
    end

    test "bold is never a claim: without an id comment it is the section's text" do
      text = "# A\n\n**A bold claim.** More.\n\n- **Bold item.** More.\n"
      assert claim_ids(text) == []

      edited = String.replace(@claim_paragraphs, "never a claim", "only emphasis")
      before = claim_versions(@claim_paragraphs, [])
      after_edit = claim_versions(edited, [])
      assert for({id, h} <- before, after_edit[id] != h, do: id) == ["spec.md#Retirement"]
    end

    test "a paragraph's version is its own text; the section's leaves it out" do
      before = claim_versions(@claim_paragraphs, [])
      edited = String.replace(@claim_paragraphs, "Nothing\nresolves", "Nothing\never resolves")
      after_edit = claim_versions(edited, [])

      assert for({id, h} <- before, after_edit[id] != h, do: id) == [
               "spec.md#retired-unreachable"
             ]
    end

    test "a comment closed by <!-- /surfex --> is still a block, and one naming nothing is the block error" do
      block = "# A\n\n<!-- surfex: b -->\nA rule.\n<!-- /surfex -->\n"

      assert [%{id: "spec.md#b", role: :block}] =
               Enum.filter(claim_units(block), &(&1.role != :section))

      for {text, message} <- [
            {"# A\n\n<!-- surfex: a -->\n\ntext\n", "spec.md:3: block a is never closed"},
            {"# A\n\n<!-- surfex: a -->\n```\nx\n```\n", "spec.md:3: block a is never closed"}
          ] do
        error = assert_raise ArgumentError, fn -> claim_units(text) end
        assert error.message =~ message
      end
    end
  end

  # Inserting a unit at the top of every form leaves every other unit's id and version as it
  # was: nothing is numbered by where it stands.
  describe "no positional id" do
    @describetag verifies: ["no-positional-ids"]

    @claim_forms """
    # Forms

    TOP-PARAGRAPH

    <!-- surfex: para-a -->
    The first named paragraph.

    <!-- surfex: rules listed -->
    TOP-RULE
    1. §L.1 The first listed rule.
    2. §L.2 The second listed rule.

    TOP-ITEM
    - <!-- surfex: item-a --> The first named item.
    - plain
    """

    test "inserting a claim at the top of every form changes no other unit" do
      opts = [rule_ids: :section_sign]
      plain = fn text -> String.replace(text, ~r/TOP-[A-Z]+\n/, "") end
      before = claim_units(plain.(@claim_forms), opts)

      inserted =
        @claim_forms
        |> String.replace("TOP-PARAGRAPH\n", "<!-- surfex: para-new -->\nA new paragraph.\n")
        |> String.replace("TOP-RULE\n", "1. §L.0 A new first rule.\n")
        |> String.replace("TOP-ITEM\n", "- <!-- surfex: item-new --> A new first item.\n")

      after_insert = claim_units(inserted, opts)
      by_id = Map.new(after_insert, &{&1.id, &1.hash})

      assert for(u <- before, by_id[u.id] != u.hash, do: u.id) == []

      assert Enum.map(after_insert, & &1.id) -- Enum.map(before, & &1.id) == [
               "spec.md#para-new",
               "spec.md#L.0",
               "spec.md#item-new"
             ]
    end
  end

  describe "rules counted" do
    @describetag verifies: ["rule-items"]

    test "status counts rules by role, and the reports show them once a spec names one" do
      named = claim_units("# A\n\ntext\n\n<!-- surfex: one -->\nA claim.\n")
      plain = claim_units("# A\n\ntext\n")

      assert %{rule: 1, section: 1} = Surfex.Status.units(Surfex.Status.derive(named, []))
      assert Surfex.Status.Report.text(Surfex.Status.derive(named, [])) =~ " · rules 1\n"
      refute Surfex.Status.Report.text(Surfex.Status.derive(plain, [])) =~ "rules"
    end
  end

  describe "rule_ids: in .surfex.exs" do
    @describetag verifies: ["rule-items"]

    @tag :tmp_dir
    test "the config's rule_ids: reads a marked list's ids, and require: takes the rule role", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "spec.md"), "# A\n\n<!-- surfex: rules r -->\n- §A.1 one\n")
      config = [sources: ["spec.md"], rule_ids: :section_sign, require: [rule: [:verifies]]]

      ids = for s <- Surfex.Status.Config.scans(config, dir), s.role == :rule, do: s.id
      assert ids == ["spec.md#A.1"]
      assert Surfex.Status.Config.require!(config) == [rule: [:verifies]]

      assert_raise ArgumentError, ~r/rule_ids: .*needs a named capture/, fn ->
        Surfex.Status.Config.scans(Keyword.put(config, :rule_ids, ~r/^P\d+/), dir)
      end
    end
  end

  defp rules_of(units),
    do: Enum.filter(units, &(&1.role == :rule))
end
