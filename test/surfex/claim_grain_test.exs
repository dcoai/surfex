defmodule Surfex.ClaimGrainTest do
  # #256 (C.1): require: spec rules judge claims only and name a contained claim; #285:
  # claim grain is the only reading, so the claim_grain: key is refused, and path
  # headings fold by default where the spec writes ids (§13.2, §11.1).
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

  describe "claim grain is the only reading" do
    @describetag verifies: "claim-grain-refused"

    @tag :tmp_dir
    @tag verifies: ["claim-grain-refused", "status-config"]
    test "a .surfex.exs with claim_grain: is refused, either value; without it, it reads", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, ".surfex.exs")

      for value <- [true, false] do
        File.write!(path, ~s([sources: ["spec.md"], claim_grain: #{value}]))

        error = assert_raise ArgumentError, fn -> Config.read!(path) end
        assert error.message =~ "claim_grain: is no longer a key"
        assert error.message =~ "claim grain is now the only reading"
        assert error.message =~ "mix surfex.migrate --report"
      end

      File.write!(path, ~s([sources: ["spec.md"]]))
      assert Config.read!(path) == [sources: ["spec.md"]]
      assert Config.options!(Config.read!(path)) == [triangle: :report]
      refute Map.has_key?(Status.derive([], []).policy, :claim_grain)
    end
  end

  describe "folding by default" do
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
      refute @path in ids(dir, heading_ids: :section_sign)
      assert "spec.md#Engine.13" in ids(dir, heading_ids: :section_sign)

      # fold_paths: false keeps the path heading a unit.
      assert @path in ids(dir, heading_ids: :section_sign, fold_paths: false)

      # Without heading_ids: there is no id'd heading to fold into.
      assert "spec.md#Index/§Engine.13 Engine/run/2" in ids(dir, [])
    end
  end
end
