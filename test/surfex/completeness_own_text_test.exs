defmodule Surfex.CompletenessOwnTextTest do
  # #256 (C.1): under claim_grain: true a claim is complete only with its own evidence, and
  # a contained one names where the evidence is (§20.1).
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown

  @spec_text """
  ## Own
  <!-- surfex: own -->

  Own prose, verified by a tag of its own.

  ## Contained
  <!-- surfex: contained -->

  Prose of its own that no test claims.

  ```test:inner
  a hint inside it, verified
  ```

  ## Chapter
  <!-- surfex: chapter -->

  ### Limits
  <!-- surfex: limits -->

  <!-- surfex: table limit-table -->
  | Key | Value |
  |---|---|
  | a | 1 |
  """

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  # Every verifies relation reviewed, so validated (§18).
  defp report(tests, opts) do
    scans = Markdown.sections(@spec_text, "spec.md") ++ tests
    by_id = Map.new(scans, &{&1.id, &1})

    entries =
      for %Scan{kind: :test, declares: declares} = t <- tests,
          {:verifies, ref} <- declares,
          to = Map.fetch!(by_id, ref),
          do:
            Entry.new!(
              at: "2026-10-14T10:00:00Z",
              op: :relate,
              type: :verifies,
              basis: :review,
              by: "t",
              note: "checked",
              ends: [
                %{kind: :test, id: t.id, hash: t.hash},
                %{kind: :spec, id: to.id, hash: to.hash}
              ]
            )

    # Each unit refines what it sits in, as the source states.
    refines =
      for %Scan{kind: :spec, within: w} = u <- scans,
          w != nil,
          to = Map.fetch!(by_id, w),
          do:
            Entry.new!(
              at: "2026-10-14T10:00:00Z",
              op: :relate,
              type: :refines,
              by: "t",
              ends: [
                %{kind: :spec, id: u.id, hash: u.hash},
                %{kind: :spec, id: to.id, hash: to.hash}
              ]
            )

    status = Status.derive(scans, entries ++ refines, [], opts)
    {status, Completeness.report(status)}
  end

  defp tests(extra \\ []),
    do:
      [
        test_scan("T: own", ["own"]),
        test_scan("T: inner", ["inner"]),
        test_scan("T: a", ["limit-table/a"])
      ] ++ extra

  defp spec_missing(report),
    do: for(%{kind: :spec, id: id, missing: m} <- report.incomplete, into: %{}, do: {id, m})

  @tag verifies: "completeness-own-text"
  test "under claim_grain: a claim is complete only with its own evidence" do
    {_status, report} = report(tests(), claim_grain: true)

    assert spec_missing(report) == %{
             "spec.md#contained" => [{:contained, ["spec.md#inner"]}]
           }

    # Counted: own, contained, inner and the row. Not the containers: the chapter, the
    # section holding only a table, and the table itself.
    assert report.scores.spec == %{complete: 3, total: 4, percent: 75.0}

    assert Completeness.text(report) =~
             "spec spec.md#contained (spec.md:6-13): contained (spec.md#inner)"

    assert [%{"id" => "spec.md#contained", "missing" => ["contained (spec.md#inner)"]}] =
             JSON.decode!(Completeness.json(report))["incomplete"]
             |> Enum.filter(&(&1["kind"] == "spec"))

    assert Surfex.Golden.render(Completeness.golden(report, "COMPLETENESS.md")) =~
             "| `spec spec.md#contained` | contained (spec.md#inner) |"

    # Tagged by a validated test of its own, it is complete.
    {_status, tagged} =
      report(tests([test_scan("T: contained", ["contained"])]), claim_grain: true)

    assert spec_missing(tagged) == %{}
    assert tagged.scores.spec.percent == 100.0
  end

  @tag verifies: "claim-grain-switch"
  test "without claim_grain: completeness reads as before, and the verdicts are still given" do
    {status, report} = report(tests(), [])

    # Complete through the hint inside it, and the marked table counted (through its row).
    assert spec_missing(report) == %{}
    assert report.scores.spec == %{complete: 5, total: 5, percent: 100.0}

    assert Status.verdict(status, "spec.md#contained") == :contained
    assert [%{unit: "spec.md#contained"}] = status.contained

    {grained, _} = report(tests(), claim_grain: true)
    assert grained.policy.claim_grain and not status.policy.claim_grain
  end
end
