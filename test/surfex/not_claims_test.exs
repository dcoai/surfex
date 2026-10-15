defmodule Surfex.NotClaimsTest do
  # #273: lines a project declares are not claims (`not_claims:`) are left out of a unit's
  # own text for verification and completeness, never out of its version (spec §13.12).
  use ExUnit.Case, async: true
  @moduletag verifies: "not-claims"

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

  @provenance ~r/^Legacy reference: /

  @spec_text """
  # Spec

  ## Submit
  <!-- surfex: submit -->

  Legacy reference: L-E§4.2

  ```test:submit-saves
  submitting an entry saves the job
  ```

  ## Other
  <!-- surfex: other -->

  Prose with no provenance at all.
  """

  @at "2026-10-15T10:00:00Z"

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  # Each test's verifies, reviewed, and each unit refining what it sits in.
  defp entries(scans) do
    by_id = Map.new(scans, &{&1.id, &1})

    verifies =
      for %Scan{kind: :test, declares: declares} = t <- scans,
          {:verifies, ref} <- declares,
          to = Map.fetch!(by_id, ref),
          do: entry(:verifies, :review, {:test, t}, to)

    refines =
      for %Scan{kind: :spec, within: w} = u <- scans,
          w != nil,
          do: entry(:refines, :judgement, {:spec, u}, Map.fetch!(by_id, w))

    verifies ++ refines
  end

  defp entry(type, basis, {kind, from}, to),
    do:
      Entry.new!(
        at: @at,
        op: :relate,
        type: type,
        basis: basis,
        by: "t",
        note: "checked",
        ends: [
          %{kind: kind, id: from.id, hash: from.hash},
          %{kind: :spec, id: to.id, hash: to.hash}
        ]
      )

  defp derive(text, patterns) do
    scans =
      Markdown.sections(text, "spec.md", not_claims: patterns) ++
        [test_scan("T: saves", ["submit-saves"]), test_scan("T: other", ["other"])]

    options = if patterns == [], do: [], else: [not_claims: Enum.map(patterns, &inspect/1)]
    Status.derive(scans, entries(scans), [], options)
  end

  defp unit(status, id), do: Map.fetch!(status.scans, {:spec, "spec.md##{id}"})

  @tag verifies: ["not-claims", "not-claims-container"]
  test "a section whose own text is only a matched line is a container" do
    plain = derive(@spec_text, [])
    declared = derive(@spec_text, [@provenance])

    # Without the pattern the provenance line is own text, green only through its hint.
    assert Status.verdict(plain, "spec.md#submit") == :contained
    assert [%{unit: "spec.md#submit"}] = plain.contained

    # With it the section states nothing of its own: its hint answers for it.
    assert Status.verdict(declared, "spec.md#submit") == :through_claims
    assert declared.contained == []
    assert %{unit: "spec.md#submit", claims: 1, verified: 1} in declared.containers
    assert Status.verdict(declared, "spec.md#other") == :verified

    scan = unit(declared, "submit")
    assert scan.not_claims == %{lines: %{inspect(@provenance) => 1}, own_text: false}
    assert Markdown.claimless?(scan)
    refute Markdown.empty?(scan)
    assert unit(plain, "submit").not_claims == nil

    # Versions cover every line, matched or not.
    for id <- ["submit", "submit-saves", "other"],
        do: assert(unit(plain, id).hash == unit(declared, id).hash)

    # An edit to the matched line still changes the version.
    edited = String.replace(@spec_text, "L-E§4.2", "L-E§4.3")
    refute unit(derive(edited, [@provenance]), "submit").hash == scan.hash
  end

  @tag verifies: ["not-claims", "not-claims-added-sentence", "own-text-score"]
  test "a sentence no pattern matches makes the section a claim again" do
    added =
      String.replace(
        @spec_text,
        "Legacy reference: L-E§4.2\n",
        "Legacy reference: L-E§4.2\n\nA submitted entry is locked.\n"
      )

    status = derive(added, [@provenance])
    assert Status.verdict(status, "spec.md#submit") == :contained

    assert unit(status, "submit").not_claims ==
             %{lines: %{inspect(@provenance) => 1}, own_text: true}

    refute Markdown.claimless?(unit(status, "submit"))

    # Completeness counts it again, missing its own evidence.
    report = Completeness.report(status)

    assert %{missing: [{:contained, ["spec.md#submit-saves"]}]} =
             Enum.find(report.incomplete, &(&1.id == "spec.md#submit"))

    # With only the matched line it isn't counted.
    report = Completeness.report(derive(@spec_text, [@provenance]))
    refute Enum.any?(report.incomplete, &(&1.id == "spec.md#submit"))
    assert report.scores.spec.total == 2
  end

  @tag verifies: ["not-claims", "not-claims-reported"]
  test "each pattern's matched lines are listed, a pattern matching nothing with 0" do
    unused = ~r/^Nowhere: /
    status = derive(@spec_text, [@provenance, unused])

    assert status.not_claims == [
             %{pattern: inspect(@provenance), lines: 1, units: 1},
             %{pattern: inspect(unused), lines: 0, units: 0}
           ]

    refute Status.failing?(status)

    text = Report.text(status)
    assert text =~ "Not claims (own-text lines a not_claims: pattern leaves out)"
    assert text =~ "~r/^Legacy reference: /: 1 line in 1 unit"
    assert text =~ "~r/^Nowhere: /: 0 lines in 0 units"

    assert [%{"pattern" => "~r/^Legacy reference: /", "lines" => 1, "units" => 1} | _] =
             JSON.decode!(Report.json(status))["not_claims"]

    golden = Surfex.Golden.render(Report.golden(status))
    assert golden =~ "## not claims"
    assert golden =~ "| `~r/^Legacy reference: /` | 1 line in 1 unit |"

    # Only where not_claims: is set.
    plain = derive(@spec_text, [])
    assert plain.not_claims == []
    refute Report.text(plain) =~ "Not claims ("
    assert JSON.decode!(Report.json(plain))["not_claims"] == []
    refute Surfex.Golden.render(Report.golden(plain)) =~ "## not claims"
  end

  @tag :tmp_dir
  @tag verifies: ["not-claims", "not-claims-reported"]
  test "the config key reaches the scan and the status, and a malformed one is refused",
       %{tmp_dir: root} do
    assert_raise ArgumentError, ~r/not_claims: must be a list of regexes/, fn ->
      Config.not_claims!(not_claims: ["^Legacy"])
    end

    assert_raise ArgumentError, ~r/not_claims: must be a list of regexes/, fn ->
      Config.not_claims!(not_claims: @provenance)
    end

    assert_raise ArgumentError, ~r/not_claims: must be a list of regexes/, fn ->
      Markdown.sections(@spec_text, "spec.md", not_claims: [:nope])
    end

    assert Config.not_claims!([]) == []

    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "lib/shop.ex"),
      "defmodule Shop do\n  @moduledoc \"Shop.\"\nend\n"
    )

    File.write!(Path.join(root, "spec.md"), @spec_text)
    config = [sources: ["spec.md"], not_claims: [@provenance]]
    File.write!(Path.join(root, ".surfex.exs"), inspect(config))
    config = Config.read!(Path.join(root, ".surfex.exs"))

    submit = Enum.find(Config.scans(config, root), &(&1.id == "spec.md#submit"))
    assert submit.not_claims == %{lines: %{inspect(@provenance) => 1}, own_text: false}

    status = Config.status(config, root, "Shop", [])
    assert [%{pattern: "~r/^Legacy reference: /", lines: 1, units: 1}] = status.not_claims
    assert Status.verdict(status, "spec.md#submit") == :through_claims
  end
end
