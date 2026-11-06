defmodule Surfex.ClaimPredicateTest do
  # #289, #372: migrate and suggest read "a claim" by role, and the verdicts by own text, so a
  # project whose claims are id'd subsections couldn't move its code to them.
  use ExUnit.Case, async: true
  @moduletag verifies: "migrate-claim-is-verdicts"

  alias Surfex.{Migrate, Scan, Status}
  alias Surfex.Log.Entry
  alias Surfex.Scan.Markdown
  alias Surfex.Status.{Config, Verdict}

  @meta [by: "tester", at: "2026-11-06T10:00:00Z", note: "moves"]

  @text """
  # Objects
  <!-- surfex: objects -->

  ## Getting
  <!-- surfex: getting -->

  Getting an object returns its bytes.

  ## Heading only
  <!-- surfex: heading-only -->

  ### Inner
  <!-- surfex: inner -->

  Inner text.

  ## History
  <!-- surfex: history -->
  <!-- surfex: class informative -->

  How this came about.

  ## Later
  <!-- surfex: later -->
  <!-- surfex: deferred #12 -->

  Not built yet.

  ## Mixed
  <!-- surfex: mixed -->

  Own text.

  <!-- surfex: table limits -->
  | Key | Value |
  |---|---|
  | a | 1 |

  ```test:mixed-hint
  a hint
  ```

  <!-- surfex: a-block -->
  A block.
  <!-- /surfex -->

  - <!-- surfex: a-rule --> a rule
  """

  @classes [{"informative", "asserts nothing"}]

  defp spec do
    Markdown.sections(@text, "spec.md",
      spec_classes: Config.spec_classes!([spec_classes: @classes], ["spec.md"])
    )
  end

  defp unit(scans, id), do: Enum.find(scans, &(&1.id == "spec.md##{id}"))

  defp code(id),
    do: %Scan{
      kind: :code,
      id: id,
      hash: "c-#{id}",
      role: :function,
      location: %{file: "lib/m.ex", lines: {1, 2}}
    }

  defp test_scan(id, declares, calls),
    do: %Scan{
      kind: :test,
      id: id,
      hash: "t-#{id}",
      declares: Enum.map(declares, &{:verifies, "spec.md##{&1}"}),
      calls: calls,
      location: %{file: "test/a_test.exs", lines: {1, 2}}
    }

  defp implements(spec_scan, code_scan) do
    Entry.new!(
      at: "2026-11-06T09:00:00Z",
      op: :relate,
      type: :implements,
      basis: :review,
      note: "checked",
      ends: [
        %{kind: :code, id: code_scan.id, hash: code_scan.hash},
        %{kind: :spec, id: spec_scan.id, hash: spec_scan.hash}
      ]
    )
  end

  test "claim?/1 is what the verdicts read: own text, no class, no deferral" do
    scans = spec()
    yes = ~w(getting inner mixed mixed-hint a-block a-rule limits/a)
    no = ~w(objects heading-only history later limits)

    for id <- yes, do: assert(Verdict.claim?(unit(scans, id)), "#{id} is a claim")
    for id <- no, do: refute(Verdict.claim?(unit(scans, id)), "#{id} is no claim")

    # Every unit claim?/1 calls a claim gets a claim's verdict, and no other does.
    status = Status.derive(scans, [], [])
    containers_or_outside = [:through_claims, :excused, :deferred]

    for s <- scans do
      assert Verdict.claim?(s) == Status.verdict(status, s.id) not in containers_or_outside,
             "#{s.id}: #{Status.verdict(status, s.id)}"
    end
  end

  test "an id'd subsection is a claim inside: proposed, and a target for --code --to" do
    scans = spec()
    get = code("M.get/1")
    t = test_scan("T: inner", ["inner"], ["M.get/1"])
    world = [t, get | scans]
    section = unit(scans, "objects")
    entries = [implements(section, get)]

    assert [%{outcome: :single, codes: ["M.get/1"], claims: [%{claim: "spec.md#inner"}]}] =
             Migrate.proposals(world, entries, [section.id])

    assert %{sections: [%{kind: :units}]} = Migrate.report(world, entries, [section.id])

    assert {:ok, [%{type: :implements}]} =
             Migrate.choose(world, entries, section.id, "M.get/1", ["spec.md#inner"], @meta)
  end

  test "suggest proposes to a leaf section, and not to one holding claims", %{} do
    text =
      Enum.join(
        [
          "# Leaf",
          "<!-- surfex: leaf -->",
          "",
          "Leaf text.",
          "",
          "# Holding",
          "<!-- surfex: holding -->",
          "",
          "Holding text.",
          "",
          "```test:held",
          "held",
          "```",
          "",
          "# Parent",
          "<!-- surfex: parent -->",
          "",
          "Parent text.",
          "",
          "## Child",
          "<!-- surfex: child -->",
          "",
          "Child text.",
          ""
        ],
        "\n"
      )

    root = Path.join(System.tmp_dir!(), "claim-predicate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "spec.md"), text)
    on_exit(fn -> File.rm_rf!(root) end)

    scans =
      Markdown.records(root, ["spec.md"]) ++
        [code("M.leaf/0"), code("M.held/0"), code("M.child/0")] ++
        [
          test_scan("T: leaf", ["leaf"], ["M.leaf/0"]),
          test_scan("T: held", ["held", "holding"], ["M.held/0"]),
          test_scan("T: child", ["child", "parent"], ["M.child/0"])
        ]

    profile = Config.profile!([sources: ["spec.md"]], "M")
    suggested = Surfex.Suggest.all(profile, [], scans, [], root)
    pairs = for c <- suggested.implements, do: {c.spec.id, c.code.id}

    assert {"spec.md#leaf", "M.leaf/0"} in pairs
    assert {"spec.md#held", "M.held/0"} in pairs
    assert {"spec.md#child", "M.child/0"} in pairs
    refute Enum.any?(pairs, fn {spec, _} -> spec in ["spec.md#holding", "spec.md#parent"] end)
  end

  test "a target that isn't a claim inside is refused, naming why" do
    scans = spec()
    get = code("M.get/1")
    world = [get | scans]
    section = unit(scans, "objects")
    entries = [implements(section, get)]

    choose = fn target ->
      Migrate.choose(world, entries, section.id, "M.get/1", ["spec.md##{target}"], @meta)
    end

    assert {:error, "spec.md#history: classed informative, so no claim inside" <> _} =
             choose.("history")

    assert {:error, "spec.md#later: deferred, so no claim inside" <> _} = choose.("later")

    assert {:error, "spec.md#heading-only: a container, so no claim inside" <> _} =
             choose.("heading-only")

    mixed = unit(scans, "mixed")
    other = [implements(mixed, get)]

    assert {:error, "spec.md#inner: not inside spec.md#mixed" <> _} =
             Migrate.choose(world, other, mixed.id, "M.get/1", ["spec.md#inner"], @meta)
  end
end
