defmodule Surfex.SpecShapeTest do
  # #292: a path heading among numbered siblings is almost always a missed id: warned, in
  # the one spec-shape listing the list-shaped keys share.
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown
  alias Surfex.Status
  alias Surfex.Status.Report

  @chapter """
  # 07 Queuing

  Intro.

  ## 1. Why

  One.

  ## 2. Environment

  Two.

  ## 3-raw. Checks for the raw backend

  Raw.

  ## 4. Sysctl

  Four.
  """

  defp shape_units(text, opts),
    do: Markdown.sections(text, "spec/07.md", [heading_ids: :section_number] ++ opts)

  defp shape_warnings(units), do: for(u <- units, w <- u.warnings, do: {u.id, w.line, w.message})

  @tag verifies: ["path-heading-warning", "spec-shape"]
  test "a heading with no id among numbered siblings is warned on the unit it reads as" do
    assert [{"spec/07.md#07", 13, folded}] =
             shape_warnings(shape_units(@chapter, fold_paths: true))

    assert folded ==
             ~s("## 3-raw. Checks for the raw backend" has no id among numbered siblings ) <>
               "(2, 4): a missed id? fold_paths: folds it into spec/07.md#07"

    own = "spec/07.md#07 Queuing/3-raw. Checks for the raw backend"
    assert [{^own, 13, unfolded}] = shape_warnings(shape_units(@chapter, []))
    assert unfolded =~ "(2, 4): a missed id? it is a unit of its own, #{own}"

    # Among siblings no grammar numbered, a path heading is a subsection: nothing is warned.
    plain = String.replace(@chapter, ~r/## \d\. /, "## ")
    assert shape_warnings(shape_units(plain, fold_paths: true)) == []
    assert shape_warnings(Markdown.sections(@chapter, "spec/07.md")) == []

    # One listing, never failing: the text under Spec shape, the JSON in spec_warnings.
    status = Status.derive(shape_units(@chapter, fold_paths: true), [])
    refute Status.failing?(status)

    text = Report.text(status)
    assert text =~ "Spec shape (warnings; none fails):\n  Path headings among numbered siblings"
    assert text =~ "(spec/07.md:13)"

    json = :json.decode(Report.json(status))

    assert [
             %{
               "kind" => "path_heading",
               "file" => "spec/07.md",
               "line" => 13,
               "unit" => "spec/07.md#07",
               "message" => ^folded
             }
           ] = json["spec_warnings"]

    # A list-shaped key (§11.2) is a warning of the same listing, a group of its own.
    table =
      "\n<!-- surfex: table codes key: Code -->\n| Code | Means |\n|---|---|\n| 1, 2 | both |\n"

    both = Status.derive(shape_units(@chapter <> table, fold_paths: true), [])
    refute Status.failing?(both)

    assert Report.text(both) =~
             ~r/Spec shape \(warnings; none fails\):\n  List-shaped keys .*\n    row .*\n  Path headings/

    assert ["path_heading", "list_key"] =
             both
             |> Report.json()
             |> :json.decode()
             |> Map.fetch!("spec_warnings")
             |> Enum.map(& &1["kind"])
  end
end
