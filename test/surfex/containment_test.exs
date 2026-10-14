defmodule Surfex.ContainmentTest do
  # #256 (C.1): a unit's own text is verified only by its own evidence; a unit with no text
  # of its own answers through its claims (§13.4).
  use ExUnit.Case, async: true

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Report

  @spec_text """
  # Spec

  ## Own
  <!-- surfex: own -->

  Own prose, verified by a tag of its own.

  ## Contained
  <!-- surfex: contained -->

  Prose of its own that no test claims.

  ```test:inner
  a hint inside it, verified
  ```

  ## Bare
  <!-- surfex: bare -->

  Prose and nothing.

  ## Chapter
  <!-- surfex: chapter -->

  ### One
  <!-- surfex: one -->

  A verified subsection.

  ### Two
  <!-- surfex: two -->

  An unverified subsection.

  ## Ruled
  <!-- surfex: ruled -->

  <!-- surfex: rules ruled-list -->
  - <!-- surfex: r1 --> the first rule
  - <!-- surfex: r2 --> the second rule

  ## Limits
  <!-- surfex: limits -->

  <!-- surfex: table limit-table -->
  | Key | Value |
  |---|---|
  | a | 1 |
  | b | 2 |
  """

  @at "2026-10-14T10:00:00Z"

  defp spec, do: Markdown.sections(@spec_text, "spec.md")
  defp unit(scans, id), do: Enum.find(scans, &(&1.id == "spec.md##{id}"))

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp check_scan(id, declares),
    do: %Scan{
      kind: :check,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      check: %{run: ["true"], declaration: "#{id}-h", inputs: %{}},
      location: %{file: ".surfex.exs", lines: nil}
    }

  # A verifies entry from each verifier to each unit it declares, at their current versions.
  defp verifies(scans) do
    by_id = Map.new(scans, &{&1.id, &1})

    for %Scan{kind: kind, declares: declares} = from <- scans,
        kind in [:test, :check],
        {:verifies, ref} <- declares,
        to = Map.fetch!(by_id, ref) do
      Entry.new!(
        at: @at,
        op: :relate,
        type: :verifies,
        basis: :review,
        by: "t",
        note: "checked",
        ends: [
          %{kind: kind, id: from.id, hash: from.hash},
          %{kind: :spec, id: to.id, hash: to.hash}
        ]
      )
    end
  end

  defp derive(scans), do: Status.derive(scans, verifies(scans))

  defp fixture do
    rows = for r <- spec(), r.role == :row, do: String.replace_prefix(r.id, "spec.md#", "")

    spec() ++
      [
        test_scan("T: own", ["own"]),
        test_scan("T: inner", ["inner"]),
        test_scan("T: one", ["one"]),
        test_scan("T: r1", ["r1"]),
        check_scan("limits", rows)
      ]
  end

  @tag verifies: "containment-verdicts"
  test "each unit gets one verdict, from the evidence aimed at its own text" do
    status = derive(fixture())
    v = &Status.verdict(status, "spec.md##{&1}")

    assert v.("own") == :verified
    assert v.("contained") == :contained
    assert v.("inner") == :verified
    assert v.("bare") == :unverified
    assert v.("chapter") == :through_claims
    assert v.("one") == :verified and v.("two") == :unverified
    # The body is only a marked rules list: no text of its own.
    assert v.("ruled") == :through_claims
    assert v.("r1") == :verified and v.("r2") == :unverified
    # A marked table's version is its header: its rows are its claims.
    assert v.("limit-table") == :through_claims
    assert v.("limit-table/a") == :verified and v.("limit-table/b") == :verified
    assert v.("limits") == :through_claims
    assert Status.verdict(status, "spec.md#nothing") == nil

    # The contained claim names the verified claim inside it, and where it is.
    assert [%{unit: "spec.md#contained", inside: ["spec.md#inner"], location: %{file: "spec.md"}}] =
             status.contained

    by_unit = Map.new(status.containers, &{&1.unit, {&1.verified, &1.claims}})
    assert by_unit["spec.md#chapter"] == {1, 2}
    assert by_unit["spec.md#ruled"] == {1, 2}
    assert by_unit["spec.md#limit-table"] == {2, 2}

    # Information, never a failure.
    refute Status.failing?(status)
  end

  @tag verifies: "containment-verdicts"
  test "the verdicts read as text, JSON and the golden" do
    status = derive(fixture())

    text = Report.text(status)
    assert text =~ "claims: 10 · verified 6 · contained 1 · unverified 3 · containers 5"
    assert text =~ "Contained (a claim verified only through a claim inside it"
    assert text =~ "spec spec.md#contained (spec.md:"
    assert text =~ "verified inside: spec.md#inner"

    json = JSON.decode!(Report.json(status))
    assert json["verdicts"]["spec.md#contained"] == "contained"
    assert json["verdicts"]["spec.md#chapter"] == "through_claims"
    assert [%{"unit" => "spec.md#contained", "inside" => ["spec.md#inner"]}] = json["contained"]

    assert %{"claims" => 2, "verified" => 1} =
             Enum.find(json["containers"], &(&1["unit"] == "spec.md#chapter"))

    golden = Surfex.Golden.render(Report.golden(status))
    assert golden =~ "**10 claims** · verified 6 · contained 1 · unverified 3 · containers 5"
    assert golden =~ "## contained"
    assert golden =~ "| `spec spec.md#contained` | `spec.md#inner` |"
  end

  @tag verifies: "verifies-on-container"
  test "a verifies aimed at a container is listed, verifies nothing and doesn't fail" do
    scans = spec() ++ [test_scan("T: chapter", ["chapter"])]
    status = derive(scans)

    assert [
             %{
               test: "T: chapter",
               unit: "spec.md#chapter",
               inside: ["spec.md#one", "spec.md#two"]
             }
           ] = status.on_container

    assert Status.verdict(status, "spec.md#one") == :unverified
    assert Status.verdict(status, "spec.md#two") == :unverified
    refute Status.failing?(status)

    assert Report.text(status) =~
             "test T: chapter → spec spec.md#chapter: its claims are spec.md#one, spec.md#two"

    assert [%{"test" => "T: chapter", "unit" => "spec.md#chapter"}] =
             JSON.decode!(Report.json(status))["on_container"]

    assert Surfex.Golden.render(Report.golden(status)) =~ "## on container"
  end

  @tag verifies: "container-units"
  test "naming a section's last prose paragraph turns it from a claim into a container" do
    before = """
    ## S
    <!-- surfex: s -->

    <!-- surfex: r1 -->
    The first claim.

    The last prose.

    ## Other
    <!-- surfex: other -->

    Other text.
    """

    named = String.replace(before, "The last prose.", "<!-- surfex: r2 -->\nThe last prose.")

    [a, b] = for text <- [before, named], do: Markdown.sections(text, "spec.md")
    hash = fn scans, id -> unit(scans, id) && unit(scans, id).hash end

    # The section's version changes (its own text is gone), the new rule's appears, and no
    # other unit's changes.
    refute hash.(a, "s") == hash.(b, "s")
    assert hash.(a, "r2") == nil and hash.(b, "r2") != nil
    assert hash.(a, "r1") == hash.(b, "r1")
    assert hash.(a, "other") == hash.(b, "other")

    assert Status.verdict(Status.derive(a, []), "spec.md#s") == :unverified
    assert Status.verdict(Status.derive(b, []), "spec.md#s") == :through_claims
  end
end
