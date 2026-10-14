defmodule Surfex.ClaimGrainTest do
  # #256 (C.1): require: spec rules judge claims only and name a contained claim; the
  # transitional claim_grain: switch and the folding default it gates (§13.2, §11.1).
  use ExUnit.Case, async: true

  alias Surfex.{Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Report}

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

  ### Ruled
  <!-- surfex: ruled -->

  <!-- surfex: rules ruled-list -->
  - <!-- surfex: r1 --> the first rule
  - <!-- surfex: r2 --> the second rule

  ### Limits
  <!-- surfex: limits -->

  <!-- surfex: table limit-table -->
  | Key | Value |
  |---|---|
  | a | 1 |
  | b | 2 |
  """

  defp test_scan(id, declares),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp derive(require) do
    spec = Markdown.sections(@spec_text, "spec.md")

    scans =
      spec ++
        [
          test_scan("T: own", ["own"]),
          test_scan("T: inner", ["inner"]),
          test_scan("T: r1", ["r1"]),
          test_scan("T: a", ["limit-table/a"])
        ]

    by_id = Map.new(scans, &{&1.id, &1})

    entries =
      for %Scan{kind: :test, declares: declares} = t <- scans,
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

    Status.derive(scans, entries, require)
  end

  defp unmet(status), do: Map.new(status.unmet, &{&1.scan.id, &1.why})

  describe "require: spec rules judge claims" do
    @describetag verifies: "contained-unmet"

    @tag verifies: ["contained-unmet", "status-config"]
    test "section: [:verifies] skips containers and names a contained section" do
      status = derive(section: [:verifies])

      # The chapter, ruled and limits sections are containers: not judged. The own
      # section is met; the contained one is unmet, saying why.
      assert unmet(status) == %{"spec.md#contained" => :contained}

      assert Report.text(status) =~
               "spec spec.md#contained needs one of: verifies (spec.md:6-13): contained: " <>
                 "a unit inside it is verified, its own text isn't"

      assert [%{"id" => "spec.md#contained", "why" => "contained"}] =
               JSON.decode!(Report.json(status))["unmet"]

      assert Surfex.Golden.render(Report.golden(status)) =~
               "| `spec spec.md#contained` | `verifies` (contained) |"
    end

    @tag verifies: ["contained-unmet", "status-config"]
    test "spec: [:verifies] judges every claim, rules and rows too, and no container" do
      status = derive(spec: [:verifies])

      assert unmet(status) == %{
               "spec.md#contained" => :contained,
               "spec.md#r2" => nil,
               "spec.md#limit-table/b" => nil
             }

      # A rule that isn't a verifies rule says no why: containment is no answer to it.
      assert unmet(derive(section: [:implements]))["spec.md#contained"] == nil
    end
  end

  describe "the claim_grain: switch" do
    @describetag verifies: "status-config-read"

    @tag verifies: ["status-config-read", "status-config"]
    test "claim_grain: is a boolean, false by default, passed to derive only when set" do
      refute Config.claim_grain?([])
      assert Config.claim_grain?(claim_grain: true)
      refute Config.claim_grain?(claim_grain: false)

      assert_raise ArgumentError, ~r/claim_grain: must be true or false, got :yes/, fn ->
        Config.claim_grain?(claim_grain: :yes)
      end

      assert Config.options!([]) == [triangle: :report]
      assert Config.options!(claim_grain: true) == [triangle: :report, claim_grain: true]

      assert Status.derive([], []).policy.claim_grain == false
      assert Status.derive([], [], [], claim_grain: true).policy.claim_grain == true

      assert_raise ArgumentError, ~r/claim_grain: must be true or false/, fn ->
        Status.derive([], [], [], claim_grain: :yes)
      end
    end
  end

  describe "folding by default under claim_grain:" do
    @describetag verifies: "fold-default"

    @folding """
    # Index

    ## §Engine.13 Engine

    The engine runs.

    ### run/2

    Runs a job.
    """

    defp ids(dir, config) do
      File.write!(Path.join(dir, "spec.md"), @folding)
      config = [sources: ["spec.md"]] ++ config
      for s <- Config.scans(config, dir), s.kind == :spec, do: s.id
    end

    @path "spec.md#Index/§Engine.13 Engine/run/2"

    @tag :tmp_dir
    @tag verifies: ["fold-default", "claim-forms"]
    test "a path heading under an id'd heading folds where the spec writes ids", %{tmp_dir: dir} do
      refute @path in ids(dir, claim_grain: true, heading_ids: :section_sign)
      assert "spec.md#Engine.13" in ids(dir, claim_grain: true, heading_ids: :section_sign)

      # fold_paths: false keeps the path heading a unit.
      assert @path in ids(dir, claim_grain: true, heading_ids: :section_sign, fold_paths: false)

      # Without heading_ids: there is no id'd heading to fold into.
      assert "spec.md#Index/§Engine.13 Engine/run/2" in ids(dir, claim_grain: true)

      # Without claim_grain: nothing folds unless fold_paths: true says so.
      assert @path in ids(dir, heading_ids: :section_sign)
      refute @path in ids(dir, heading_ids: :section_sign, fold_paths: true)
    end
  end
end
