defmodule Surfex.CompletenessTest do
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  # Headings over subsections (Doc, Parent) carry no claims; A, its hint, P and Child do.
  @spec_md """
  # Doc {#doc}

  ## A {#a}

  Adding works.

  ```test h
  adding one gives one
  ```

  ## P {#p}

  A policy: no code implements it.

  ## Parent {#parent}

  ### Child {#child}

  Child text.
  """

  defp code(id, line),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "c#{line}",
      location: %{file: "lib/m.ex", lines: {line, line}}
    }

  defp test_scan(id, line),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t#{line}",
      location: %{file: "test/m_test.exs", lines: {line, line}}
    }

  defp scans do
    Markdown.sections(@spec_md, "spec.md") ++
      [
        code("M.a/0", 1),
        code("M.b/0", 2),
        code("M.c/0", 3),
        code("M.d/0", 4),
        code("M.e/0", 5),
        test_scan("T: one", 1),
        test_scan("T: policy", 2),
        test_scan("T: stray", 3),
        %Scan{
          kind: :class,
          id: "helpers",
          hash: "k1",
          location: %{file: ".surfex.exs", lines: nil}
        }
      ]
  end

  defp end_(scans, kind, id) do
    %Scan{hash: hash} = Enum.find(scans, &(&1.kind == kind and &1.id == id))
    %{kind: kind, id: id, hash: hash}
  end

  defp rel(scans, type, {ak, a}, {bk, b}, basis),
    do:
      Entry.new!(
        at: "2026-09-28T10:00:00Z",
        op: :relate,
        type: type,
        basis: basis,
        ends: [end_(scans, ak, a), end_(scans, bk, b)]
      )

  defp status do
    s = scans()

    entries = [
      rel(s, :implements, {:spec, "spec.md#a"}, {:code, "M.a/0"}, :review),
      rel(s, :implements, {:spec, "spec.md#a"}, {:code, "M.d/0"}, :review),
      # Current, but recorded before validation existed.
      rel(s, :implements, {:spec, "spec.md#a"}, {:code, "M.e/0"}, nil),
      rel(s, :verifies, {:test, "T: one"}, {:spec, "spec.md#h"}, :evidence),
      rel(s, :tests, {:test, "T: one"}, {:code, "M.a/0"}, nil),
      rel(s, :verifies, {:test, "T: policy"}, {:spec, "spec.md#p"}, :review),
      rel(s, :excuses, {:class, "helpers"}, {:code, "M.b/0"}, :judgement)
    ]

    Status.derive(s, entries)
  end

  defp missing(report, kind),
    do: for(%{kind: ^kind} = i <- report.incomplete, into: %{}, do: {i.id, i.missing})

  describe "the rules" do
    @describetag verifies: "completeness-rules"

    test "a heading over subsections carries no claims and isn't counted" do
      assert Markdown.empty?(Enum.find(scans(), &(&1.id == "spec.md#doc")))
      refute Markdown.empty?(Enum.find(scans(), &(&1.id == "spec.md#a")))

      report = Completeness.report(status())
      assert report.scores.spec.total == 4
      refute Map.has_key?(missing(report, :spec), "spec.md#doc")
      refute Map.has_key?(missing(report, :spec), "spec.md#parent")
    end

    test "spec units: verified through a hint, code validated; a policy needs a test alone" do
      assert missing(Completeness.report(status()), :spec) == %{
               # Its code M.e/0 is related, but not validated.
               "spec.md#a" => [:unvalidated],
               "spec.md#child" => [:no_relation]
             }
    end

    test "tests: verifying and exercising code, or verifying only code-less units" do
      assert missing(Completeness.report(status()), :test) == %{"T: stray" => [:no_relation]}
    end

    test "code: validated and exercised, or excused" do
      assert missing(Completeness.report(status()), :code) == %{
               "M.c/0" => [:no_relation],
               "M.d/0" => [:untested],
               "M.e/0" => [:unvalidated, :untested]
             }
    end

    test "each incomplete item says where it is" do
      assert %{location: %{file: "lib/m.ex", lines: {3, 3}}} =
               Enum.find(Completeness.report(status()).incomplete, &(&1.id == "M.c/0"))
    end
  end

  describe "the score" do
    @describetag verifies: "completeness-score"

    test "complete over all, per kind and overall, to one decimal; 100 with nothing" do
      scores = Completeness.report(status()).scores
      assert scores.spec == %{complete: 2, total: 4, percent: 50.0}
      assert scores.test == %{complete: 2, total: 3, percent: 66.7}
      assert scores.code == %{complete: 2, total: 5, percent: 40.0}
      assert scores.overall == %{complete: 6, total: 12, percent: 50.0}

      empty = Completeness.report(Status.derive([], []))
      assert empty.scores.overall == %{complete: 0, total: 0, percent: 100.0}

      # Below a floor, or not; no floor, never below.
      report = Completeness.report(status())
      assert Completeness.below?(report, 60)
      refute Completeness.below?(report, 50)
      refute Completeness.below?(report, nil)
    end

    test "text, JSON and a golden with no hashes or times" do
      report = Completeness.report(status())
      text = Completeness.text(report)
      assert text =~ "completeness: 50.0% (6/12)"
      assert text =~ "  spec units: 50.0% (2/4)"
      assert text =~ "  code M.d/0 (lib/m.ex:4-4): untested"

      {json, :ok, _} = report |> Completeness.json() |> :json.decode(:ok, %{null: nil})
      assert json["scores"]["overall"] == %{"complete" => 6, "total" => 12, "percent" => 50.0}

      assert %{"kind" => "code", "id" => "M.e/0", "missing" => ["unvalidated", "untested"]} =
               Enum.find(json["incomplete"], &(&1["id"] == "M.e/0"))

      golden = report |> Completeness.golden("COMPLETENESS.md") |> Surfex.Golden.render()
      assert golden =~ "# COMPLETENESS.md"
      assert golden =~ "**12 items** · complete 6"
      assert golden =~ "`code M.d/0`"
      refute golden =~ ~r/c[0-9]\b|2026-/
    end

    test "completeness: [min: N] is a number from 0 to 100, or no minimum" do
      assert Config.completeness!([]) == nil
      assert Config.completeness!(completeness: [min: 90]) == 90

      for bad <- [[min: 101], [min: "90"], [max: 1], :high] do
        assert_raise ArgumentError, ~r/completeness: must be \[min: N\]/, fn ->
          Config.completeness!(completeness: bad)
        end
      end
    end
  end
end
