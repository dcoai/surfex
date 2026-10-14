defmodule Surfex.EarningTest do
  # #256 (C.1): code earns its implements through the verified claim whose tests exercise
  # it, never through a section's own tag downward nor a claim's upward (§13.5).
  use ExUnit.Case, async: true

  alias Surfex.{Migrate, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown

  @spec_text """
  ## Feature
  <!-- surfex: feature -->

  Prose of the feature that no test claims.

  ```test:feature-hint
  the claim inside it
  ```

  ## Empty
  <!-- surfex: empty -->

  ## Tagged
  <!-- surfex: tagged -->

  Prose its own tag verifies.

  <!-- surfex: inner-rule -->
  A rule inside it that nothing verifies.
  """

  @at "2026-10-14T10:00:00Z"

  # M.c/1 and M.c/2 are one function with a default argument: one definition.
  defp code(id, lines, calls \\ [], file \\ "lib/m.ex"),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "h#{elem(lines, 0)}",
      role: :function,
      calls: calls,
      location: %{file: file, lines: lines}
    }

  defp code,
    do: [
      code("M.c/1", {1, 3}),
      code("M.c/2", {1, 3}),
      code("M.dispatch/0", {5, 6}, ["M.c/1"]),
      code("M.r/0", {8, 9}),
      code("M.other/0", {1, 2}, [], "lib/o.ex")
    ]

  defp test_scan(id, verifies, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "#{id}-h",
      calls: calls,
      declares: Enum.map(verifies, &{:verifies, "spec.md##{&1}"}),
      location: %{file: "test/m_test.exs", lines: {1, 2}}
    }

  defp check_scan(id, verifies, inputs),
    do: %Scan{
      kind: :check,
      id: id,
      hash: "#{id}-h",
      declares: Enum.map(verifies, &{:verifies, "spec.md##{&1}"}),
      check: %{run: ["true"], declaration: "#{id}-h", inputs: inputs},
      location: %{file: ".surfex.exs", lines: nil}
    }

  defp entry(type, a, b, extra \\ []),
    do:
      Entry.new!(
        [
          at: @at,
          op: :relate,
          type: type,
          basis: :review,
          by: "t",
          note: "checked",
          ends: [%{kind: a.kind, id: a.id, hash: a.hash}, %{kind: b.kind, id: b.id, hash: b.hash}]
        ] ++ extra
      )

  # The scans with `extra` verifiers, each verifies relation recorded at the current
  # versions, and `implements` from each code id to a unit (`{code, unit, extra}`).
  defp derive(extra, implements \\ []) do
    scans = Markdown.sections(@spec_text, "spec.md") ++ code() ++ extra
    by_id = Map.new(scans, &{&1.id, &1})

    verifies =
      for %Scan{kind: kind, declares: declares} = from <- extra,
          kind in [:test, :check],
          {:verifies, ref} <- declares,
          do: entry(:verifies, from, Map.fetch!(by_id, ref))

    related =
      for {c, unit, opts} <- implements,
          do: entry(:implements, Map.fetch!(by_id, c), Map.fetch!(by_id, "spec.md##{unit}"), opts)

    {scans, verifies ++ related, Status.derive(scans, verifies ++ related)}
  end

  defp implements(code, unit), do: {:implements, {:code, code}, {:spec, "spec.md##{unit}"}}

  describe "earning through the claims inside a unit" do
    @describetag verifies: "earned-through-claims"

    test "code a verified claim's test reaches earns; code it doesn't reach doesn't" do
      {_, _, status} = derive([test_scan("T", ["feature-hint"], ["M.c/1"])])

      assert Status.verdict(status, "spec.md#feature") == :contained
      assert Status.earning(status, implements("M.c/1", "feature")) == :earned
      assert Status.earned?(status, implements("M.c/1", "feature"))

      assert Status.earning(status, implements("M.other/0", "feature")) ==
               {:unearned, :not_exercised}

      refute Status.earned?(status, implements("M.other/0", "feature"))
    end

    test "code reached through a function that calls it earns" do
      {_, _, status} = derive([test_scan("T", ["feature-hint"], ["M.dispatch/0"])])
      assert Status.earning(status, implements("M.c/1", "feature")) == :earned
    end

    test "another arity of the same definition earns with it" do
      {_, _, status} = derive([test_scan("T", ["feature-hint"], ["M.c/1"])])
      assert Status.earning(status, implements("M.c/2", "feature")) == :earned
    end

    test "a verifying check earns the code in the files it inspects" do
      {_, _, status} = derive([check_scan("gate", ["feature-hint"], %{"lib/m.ex" => "v1"})])

      assert Status.earning(status, implements("M.c/1", "feature")) == :earned

      assert Status.earning(status, implements("M.other/0", "feature")) ==
               {:unearned, :not_exercised}
    end

    test "a current review through a named path earns what no call reaches" do
      {_, _, status} =
        derive([test_scan("T", ["feature-hint"], ["M.other/0"])], [
          {"M.c/1", "feature", [through: "route GET /feature"]}
        ])

      assert Status.earning(status, implements("M.c/1", "feature")) == :earned

      # The relation status itself is accepted too.
      relation = Enum.find(status.relations, &(&1.relation == implements("M.c/1", "feature")))
      assert Status.earned?(status, relation)
    end

    test "a container with no claims earns nothing; no evidence at all is unverified" do
      {_, _, status} = derive([test_scan("T", ["feature-hint"], ["M.c/1"])])

      assert Status.verdict(status, "spec.md#empty") == :through_claims
      assert Status.earning(status, implements("M.c/1", "empty")) == {:unearned, :nothing_inside}

      {_, _, none} = derive([])
      assert Status.earning(none, implements("M.c/1", "feature")) == {:unearned, :unverified}
    end
  end

  @tag verifies: "no-upward-credit"
  test "a section's own tag earns its own code, never the code of a claim inside it" do
    {_, _, status} = derive([test_scan("T", ["tagged"], ["M.r/0"])])

    assert Status.verdict(status, "spec.md#tagged") == :verified
    assert Status.verdict(status, "spec.md#inner-rule") == :unverified
    assert Status.earning(status, implements("M.r/0", "tagged")) == :earned
    assert Status.earning(status, implements("M.r/0", "inner-rule")) == {:unearned, :unverified}
  end

  @tag verifies: "earning-agrees"
  test "earning and the migration's candidates agree on one fixture" do
    {scans, entries, status} =
      derive([test_scan("T", ["feature-hint"], ["M.c/1"])], [
        {"M.c/1", "feature", []},
        {"M.other/0", "feature", []}
      ])

    proposals = Migrate.proposals(scans, entries, ["spec.md#feature"])
    assert length(proposals) == 2

    verified_inside =
      for k <- status.earning.inside["spec.md#feature"],
          Status.verdict(status, k) == :verified,
          do: k

    for %{codes: codes, claims: claims, outcome: outcome} <- proposals,
        code <- codes do
      earned = Status.earned?(status, implements(code, "feature"))
      assert earned == (outcome != :none), "#{code}: earned #{earned}, outcome #{outcome}"

      if earned,
        do: assert(Enum.all?(claims, &(&1.claim in verified_inside)))
    end
  end
end
