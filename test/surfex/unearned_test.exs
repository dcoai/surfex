defmodule Surfex.UnearnedTest do
  # #247 (B.3 part 2): under claim_grain: true an implements counts for require: code:
  # only when it earns, through a verified unit or a verified claim inside it whose test
  # exercises the code (§13.9, §20.3).
  use ExUnit.Case, async: true

  alias Surfex.{Completeness, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.Report

  @spec_text """
  ## Feature
  <!-- surfex: feature -->

  Prose of the feature that no test claims.

  ```test:feature-hint
  the claim inside it
  ```

  ## Other
  <!-- surfex: other -->

  Prose nothing verifies.
  """

  @at "2026-10-14T10:00:00Z"
  @require [code: [:implements]]

  defp code(id, lines),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "h-#{id}",
      role: :function,
      calls: [],
      location: %{file: "lib/m.ex", lines: lines}
    }

  defp test_scan(id, verifies, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      calls: calls,
      declares: Enum.map(verifies, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/m_test.exs", lines: {1, 2}}
    }

  defp entry(type, a, b),
    do:
      Entry.new!(
        at: @at,
        op: :relate,
        type: type,
        basis: :review,
        by: "t",
        note: "checked",
        ends: [%{kind: a.kind, id: a.id, hash: a.hash}, %{kind: b.kind, id: b.id, hash: b.hash}]
      )

  # The scans with the tests in `tests`, each test's verifies relations recorded
  # at the current versions, and an implements per `{code, unit}`.
  defp derive(tests, implements, require, opts) do
    scans =
      Markdown.sections(@spec_text, "spec.md") ++
        [code("M.a/0", {1, 2}), code("M.b/0", {3, 4})] ++ tests

    by_id = Map.new(scans, &{&1.id, &1})

    # What a test exercises is read from its calls (§13.1): no tests relation is needed.
    evidence =
      for %Scan{kind: :test, declares: declares} = t <- tests,
          {:verifies, ref} <- declares,
          do: entry(:verifies, t, by_id[ref])

    related =
      for {c, unit} <- implements,
          do: entry(:implements, by_id[c], by_id["spec.md##{unit}"])

    Status.derive(scans, evidence ++ related, require, opts)
  end

  defp grained(tests, implements, require \\ @require),
    do: derive(tests, implements, require, claim_grain: true)

  describe "require: code: counts only earning implements" do
    @describetag verifies: "unearned-fails"

    @tag verifies: ["unearned-fails", "unearned"]
    test "code related only to an unverified hint is unearned, unmet and failing" do
      status = grained([], [{"M.a/0", "feature-hint"}])

      assert status.unearned == [
               %{code: "M.a/0", unit: "spec.md#feature-hint", why: :unverified}
             ]

      assert [%{scan: %Scan{id: "M.a/0"}, why: :unearned}] =
               Enum.filter(status.unmet, &(&1.scan.id == "M.a/0"))

      assert status.policy.unearned == :fail
      assert Status.failing?(status)
    end

    test "verifying the hint clears it" do
      status = grained([test_scan("T", ["feature-hint"], ["M.a/0"])], [{"M.a/0", "feature-hint"}])

      assert status.unearned == []
      assert Enum.filter(status.unmet, &(&1.scan.kind == :code and &1.scan.id == "M.a/0")) == []
    end

    test "a contained section earns through a verified hint whose test reaches the code" do
      status =
        grained(
          [test_scan("T", ["feature-hint"], ["M.a/0"])],
          [{"M.a/0", "feature"}, {"M.b/0", "feature"}]
        )

      assert Status.verdict(status, "spec.md#feature") == :contained

      # M.a/0 earns through the hint's test; M.b/0 isn't exercised by it.
      assert status.unearned == [
               %{code: "M.b/0", unit: "spec.md#feature", why: :not_exercised}
             ]

      assert Status.failing?(status)
    end

    @tag verifies: ["unearned-fails", "unearned"]
    test "a spare unearned relation fails even when another relation meets the code" do
      status =
        grained(
          [test_scan("T", ["feature-hint"], ["M.a/0", "M.b/0"])],
          [{"M.a/0", "feature-hint"}, {"M.b/0", "feature-hint"}, {"M.a/0", "other"}]
        )

      # M.a/0's hint relation earns, so its rule is met; its relation to a section nothing
      # verifies is spare, and fails.
      assert status.unearned == [%{code: "M.a/0", unit: "spec.md#other", why: :unverified}]
      refute Enum.any?(status.unmet, &(&1.scan.kind == :code))
      assert Status.failing?(status)
    end

    @tag verifies: ["unearned-fails", "unearned"]
    test "without the rule the list is reported and doesn't fail" do
      status = grained([], [{"M.a/0", "feature-hint"}], [])

      assert [%{code: "M.a/0", why: :unverified}] = status.unearned
      assert status.policy.unearned == :report
      refute Status.failing?(status)
    end

    @tag verifies: ["unearned-fails", "unearned"]
    test "without claim_grain: nothing is unearned and the implements meets the rule" do
      status = derive([], [{"M.a/0", "feature-hint"}], @require, [])

      assert status.unearned == []
      assert status.policy.unearned == :report
      refute Enum.any?(status.unmet, &(&1.scan.id == "M.a/0"))
    end
  end

  @tag verifies: ["unearned-report", "unearned"]
  test "the text, JSON and golden report unearned relations under claim_grain only" do
    status = grained([], [{"M.a/0", "feature-hint"}])
    text = Report.text(status)

    assert text =~ "  unearned: 1 implements (failing: require: code:)\n"
    assert text =~ "Unearned ("
    assert text =~ "implements  code M.a/0 → spec spec.md#feature-hint: unverified:"
    assert text =~ "code M.a/0 needs one of: implements"
    assert text =~ "unearned: none of its implements earns"

    assert [%{"code" => "M.a/0", "unit" => "spec.md#feature-hint", "why" => "unverified"}] =
             JSON.decode!(Report.json(status))["unearned"]

    golden = status |> Report.golden("RELATIONS.md") |> Surfex.Golden.render()
    assert golden =~ "unearned"
    assert golden =~ "`code M.a/0`"

    plain = derive([], [{"M.a/0", "feature-hint"}], @require, [])
    refute Report.text(plain) =~ "unearned"
    refute Report.text(plain) =~ "Unearned"
    assert JSON.decode!(Report.json(plain))["unearned"] == []
    refute plain |> Report.golden("RELATIONS.md") |> Surfex.Golden.render() =~ "unearned"
  end

  @tag verifies: ["completeness-earned-code", "earned-code-score"]
  test "completeness describes code only by an earning implements under claim_grain" do
    missing = fn status ->
      status
      |> Completeness.report()
      |> Map.fetch!(:incomplete)
      |> Enum.find_value([], &(&1.kind == :code and &1.id == "M.a/0" and &1.missing))
    end

    assert :unearned in missing.(grained([], [{"M.a/0", "feature-hint"}]))

    earned =
      grained([test_scan("T", ["feature-hint"], ["M.a/0"])], [{"M.a/0", "feature-hint"}], [])

    refute :unearned in missing.(earned)

    refute :unearned in missing.(derive([], [{"M.a/0", "feature-hint"}], [], []))
  end
end
