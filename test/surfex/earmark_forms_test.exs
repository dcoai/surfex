defmodule Surfex.EarmarkFormsTest do
  @moduledoc """
  The spec's unit forms as ex_doc renders them (§11, #195). A spec published with ex_doc goes
  through its markdown, EarmarkParser, which doesn't render every form surfex reads as a
  forge does. Each form §11 says it renders is scanned by surfex and rendered by ex_doc
  here: no marker text may show, and every heading must stay a heading. The forms §11 says
  break are rendered too, so the spec's warning stays true.
  """
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown

  @moduletag verifies: "earmark-forms"

  # Each form as an author writes it, with the units surfex reads from it. Every text ends
  # in a heading, the one a broken form would swallow.
  @rendered [
    {"an id comment on the line after a heading",
     "# Carts\n<!-- surfex: carts -->\n\nA cart holds items.\n\n# Next\n\nn\n",
     ["spec.md#carts", "spec.md#Next"]},
    {"a test:ID hint",
     "# Carts\n\nA cart.\n\n```test:cart-empty\nan empty cart totals 0\n```\n\n# Next\n",
     ["spec.md#Carts", "spec.md#cart-empty", "spec.md#Next"]},
    {"a test:ID hint closing a block",
     "# Carts\n\n<!-- surfex: total -->\nA total counts items.\n\n```test:total-counts\n2 and 1 total 3\n```\n<!-- /surfex -->\n# Next\n",
     ["spec.md#Carts", "spec.md#total", "spec.md#total-counts", "spec.md#Next"]},
    {"a marked block straight after a heading",
     "# Carts\n<!-- surfex: rule -->\nA closed cart takes nothing.\n<!-- /surfex -->\n# Next\n",
     ["spec.md#Carts", "spec.md#rule", "spec.md#Next"]},
    {"a marked table",
     "# Modes\n<!-- surfex: modes -->\n\n<!-- surfex: table mode-table key: Mode -->\n| Mode | Means |\n|---|---|\n| `:open` | takes items |\n# Next\n",
     ["spec.md#modes", "spec.md#mode-table", "spec.md#mode-table/:open", "spec.md#Next"]},
    {"an id comment on its own line before a paragraph",
     "# Claims\n\nIntro.\n\n<!-- surfex: unreachable -->\n**A retired schema is unreachable.** More.\n\n# Next\n",
     ["spec.md#Claims", "spec.md#unreachable", "spec.md#Next"]},
    {"an id comment on its own line before a list item",
     "# Claims\n\n- plain\n\n<!-- surfex: no-override -->\n- Anonymous requests never honour it.\n\n# Next\n",
     ["spec.md#Claims", "spec.md#no-override", "spec.md#Next"]},
    {"a marked list with written ids",
     "# Claims\n\n<!-- surfex: rules tenancy -->\n1. §T.1 A tenant reads its own rows.\n2. §T.2 Ids are never reused.\n\n# Next\n",
     ["spec.md#Claims", "spec.md#T.1", "spec.md#T.2", "spec.md#Next"]},
    {"a marked contract fence",
     "# Feeds\n\n<!-- surfex: contract module: MyApp.Feed -->\n```elixir\n@spec feed(t) :: t\n```\n\n# Next\n",
     ["spec.md#Feeds", "spec.md#MyApp.Feed.feed/1", "spec.md#Next"]}
  ]

  for {form, text, ids} <- @rendered do
    test "#{form} renders with no marker text and every heading kept" do
      text = unquote(text)
      units = Markdown.sections(text, "spec.md", rule_ids: :section_sign)
      assert Enum.map(units, & &1.id) -- unquote(ids) == []
      assert unquote(ids) -- Enum.map(units, & &1.id) == []

      ast = ExDoc.Markdown.Earmark.to_ast(text, [])
      shown = ast |> earmark_shown() |> Enum.join(" ")
      refute shown =~ "surfex"
      refute shown =~ "<!--"

      assert length(earmark_headings(ast)) == Enum.count(units, &(&1.role == :section))
      assert List.last(earmark_headings(ast)) == "Next"
    end
  end

  @tag verifies: ["earmark-forms", "scan-records"]
  test "the forms said to break do: markers show as heading text, and a heading is lost" do
    for heading <- ["## Totals <!-- surfex: totals -->", "## Totals {#totals}"] do
      ast = ExDoc.Markdown.Earmark.to_ast(heading <> "\n\nt\n", [])
      assert [shown] = earmark_headings(ast)
      assert shown =~ ~r/surfex|\{#/
      assert [%{id: "spec.md#totals"} | _] = Markdown.sections(heading <> "\n\nt\n", "spec.md")
    end

    spaced = "# Carts\n\n```test cart-empty\nan empty cart totals 0\n```\n\n## Next\n"
    assert Enum.any?(Markdown.sections(spaced, "spec.md"), &(&1.id == "spec.md#cart-empty"))
    assert earmark_headings(ExDoc.Markdown.Earmark.to_ast(spaced, [])) == ["Carts"]
  end

  @tag verifies: ["earmark-forms", "claim-forms"]
  test "the claim forms said to break do: a comment in a list item shows, one starting a paragraph swallows a heading" do
    for item <- [
          "- <!-- surfex: no-override --> Never honour it.\n",
          "- <!-- surfex: no-override -->\n  Never honour it.\n"
        ] do
      text = "# Claims\n\n" <> item <> "\n# Next\n"
      assert Enum.any?(Markdown.sections(text, "spec.md"), &(&1.id == "spec.md#no-override"))
      ast = ExDoc.Markdown.Earmark.to_ast(text, [])
      assert ast |> earmark_shown() |> Enum.join(" ") =~ "surfex: no-override"
    end

    inline = "# Claims\n\n<!-- surfex: unreachable --> **Unreachable.** More.\n\n# Next\n"
    assert Enum.any?(Markdown.sections(inline, "spec.md"), &(&1.id == "spec.md#unreachable"))
    assert earmark_headings(ExDoc.Markdown.Earmark.to_ast(inline, [])) == ["Claims"]
  end

  test "an elixir contract info string, holding a space, breaks as test ID does" do
    text = "# Feeds\n\n```elixir contract\n@spec feed(t) :: t\n```\n\n# Next\n"
    subjects = [%{file: "spec.md", heading: ~r/^Feeds$/, items: ["MyApp.Feed"]}]

    assert Enum.any?(
             Markdown.sections(text, "spec.md", subjects: subjects),
             &(&1.id == "spec.md#MyApp.Feed.feed/1")
           )

    assert earmark_headings(ExDoc.Markdown.Earmark.to_ast(text, [])) == ["Feeds"]
  end

  # The class and deferral markers (§11.7), alone after a heading or after its id comment.
  @class_forms [
    "# Arch\n<!-- surfex: class informative: orientation -->\n\nThe map.\n\n# Next\n\nn\n",
    "# Arch\n<!-- surfex: arch -->\n<!-- surfex: class informative -->\n\nThe map.\n\n# Next\n",
    "# Views\n<!-- surfex: deferred #412: past v1 -->\n\nViews.\n\n# Next\n",
    "# Views\n<!-- surfex: views -->\n<!-- surfex: deferred group/project#7 -->\nViews.\n# Next\n"
  ]

  @tag verifies: ["class-markers-render", "spec-classes"]
  test "class and deferral markers render as comments with every heading kept" do
    classes =
      Surfex.Status.Config.spec_classes!([spec_classes: [{"informative", "asserts nothing"}]], [
        "spec.md"
      ])

    for text <- @class_forms do
      units = Markdown.sections(text, "spec.md", spec_classes: classes)
      assert Enum.any?(units, &(Map.get(&1, :class) || Map.get(&1, :deferred)))

      ast = ExDoc.Markdown.Earmark.to_ast(text, [])
      shown = ast |> earmark_shown() |> Enum.join(" ")
      refute shown =~ "surfex"
      refute shown =~ "<!--"

      assert earmark_headings(ast) ==
               Enum.map(Enum.filter(units, &(&1.role == :section)), &heading_of(&1, text))

      assert List.last(earmark_headings(ast)) == "Next"
    end
  end

  defp heading_of(%{location: %{lines: {first, _}}}, text),
    do: text |> String.split("\n") |> Enum.at(first - 1) |> String.trim_leading("# ")

  # The text a reader sees: every string outside an HTML comment, attributes left out.
  defp earmark_shown(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &earmark_shown/1)
  defp earmark_shown(text) when is_binary(text), do: [text]
  defp earmark_shown({:comment, _attrs, _children, _meta}), do: []
  defp earmark_shown({_tag, _attrs, children, _meta}), do: earmark_shown(children)

  defp earmark_headings(nodes) do
    for {tag, _attrs, children, _meta} <- nodes,
        tag in [:h1, :h2, :h3, :h4, :h5, :h6],
        do: children |> earmark_shown() |> Enum.join()
  end
end
