defmodule Surfex.FoldedRangesTest do
  # #292: a folded unit is located at its own lines and its folded headings', never across
  # the sibling units between them.
  use ExUnit.Case, async: true

  alias Surfex.{Item, Scan, Status, Suggest}
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @moduletag :tmp_dir

  # Lines: the chapter 1-3, §1 5-7, §2 9-11, the path heading 13-15 (it cites a function),
  # §4 17-19.
  @chapter """
  # 07 Queuing

  Intro.

  ## 1. Why

  One.

  ## 2. Environment

  Two.

  ## 3-raw. Checks for the raw backend

  `Wren.check/1` reads the raw backend.

  ## 4. Sysctl

  Four.
  """

  @ranged_opts [heading_ids: :section_number, fold_paths: true]

  defp ranged_unit(units, id), do: Enum.find(units, &(&1.id == id))

  @tag verifies: ["folded-ranges", "folded-ranges-section"]
  test "a folded unit is located at its own ranges, not one span over its siblings",
       %{tmp_dir: root} do
    units = Markdown.sections(@chapter, "spec/07.md", @ranged_opts)
    chapter = ranged_unit(units, "spec/07.md#07")

    assert chapter.location.lines == {1, 3}
    assert chapter.location.ranges == [{1, 3}, {13, 15}]
    assert Scan.ranges(chapter.location) == [{1, 3}, {13, 15}]
    assert Scan.place(chapter.location) == "spec/07.md:1-3, 13-15"

    # A unit in one range has no ranges, its lines as before.
    one = ranged_unit(units, "spec/07.md#1")
    assert one.location == %{file: "spec/07.md", lines: {5, 7}}

    # A heading folding straight after its owner extends one range.
    straight = "# 07 Queuing\n\nIntro.\n\n## Notes\n\nN.\n"
    [owner] = Markdown.sections(straight, "spec/07.md", @ranged_opts)
    assert owner.location == %{file: "spec/07.md", lines: {1, 7}}

    # Reports name both ranges; the JSON adds them beside lines.
    status = Status.derive(units, [])
    assert Report.text(status) =~ "spec spec/07.md#07 (spec/07.md:1-3, 13-15)"

    json = :json.decode(Report.json(status))
    new = Enum.find(json["new"], &(&1["id"] == "spec/07.md#07"))

    assert new["location"] == %{
             "file" => "spec/07.md",
             "lines" => [1, 3],
             "ranges" => [[1, 3], [13, 15]]
           }

    # A citation in the folded heading's lines is the chapter's, not §2's or nobody's.
    File.mkdir_p!(Path.join(root, "spec"))
    File.write!(Path.join(root, "spec/07.md"), @chapter)

    items = [
      %Item{
        kind: :function,
        name: "check/1",
        parent: "Wren",
        file: "lib/wren.ex",
        hash: "00000001"
      }
    ]

    scans = Markdown.records(root, ["spec/07.md"], [], @ranged_opts) ++ Scan.code(items)
    profile = Config.profile!([sources: ["spec/07.md"]], "Wren")

    assert [
             %{
               spec: %Scan{id: "spec/07.md#07"},
               code: %Scan{id: "Wren.check/1"},
               cited_at: {"spec/07.md", 15}
             }
           ] =
             Suggest.candidates(profile, items, scans, [], root)

    # A change draft names both ranges and quotes each, not the sibling units between.
    [draft] = Surfex.Change.drafts(Status.derive(scans, []), root, ["spec/07.md#07"])
    [quoted] = draft.units
    assert quoted.location == "spec/07.md:1-3, 13-15"

    assert quoted.text ==
             "# 07 Queuing\n\nIntro.\n\n## 3-raw. Checks for the raw backend\n\n" <>
               "`Wren.check/1` reads the raw backend."
  end
end
