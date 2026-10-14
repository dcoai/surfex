defmodule Surfex.SpecClassesTest do
  # #264 (C.2 part 1): spec_classes:, the class and deferral markers, patterns and aliases
  # as the markdown scanner reads them (§11.7).
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  @informative "explains or points; asserts nothing a test could fail on"

  defp classes(list, files \\ ["spec.md", "spec/13-decisions.md", "spec/02-arch.md"]),
    do: Config.spec_classes!([spec_classes: list], files)

  defp units(text, file \\ "spec.md", classes \\ [{"informative", @informative}], opts \\ []),
    do: Markdown.sections(text, file, [spec_classes: classes(classes)] ++ opts)

  defp unit(units, id), do: Enum.find(units, &(&1.id == id)) || flunk("no unit #{id}")
  defp class(scan), do: Map.get(scan, :class)
  defp deferred(scan), do: Map.get(scan, :deferred)

  defp without_markers(text),
    do: text |> String.split("\n") |> Enum.reject(&(&1 =~ "surfex: class")) |> Enum.join("\n")

  @tag verifies: "class-markers"
  test "a class marker classes its section with both reasons and leaves its version alone" do
    text = """
    Preamble text.
    <!-- surfex: class informative -->

    # Architecture
    <!-- surfex: arch -->
    <!-- surfex: class informative: the map is orientation -->

    The module map.

    ## Rules

    A rule.
    """

    scanned = units(text)
    arch = unit(scanned, "spec.md#arch")

    assert class(arch) == %{
             name: "informative",
             reason: @informative,
             note: "the map is orientation",
             by: :marker
           }

    assert class(unit(scanned, "spec.md#(preamble)")).note == nil
    assert class(unit(scanned, "spec.md#Architecture/Rules")) == nil

    plain = units(without_markers(text))
    for s <- scanned, do: assert(s.hash == unit(plain, s.id).hash)
  end

  @tag verifies: "deferred-marker"
  test "a deferral marker defers its section or block with reference and reason" do
    text = """
    # Views
    <!-- surfex: views -->
    <!-- surfex: deferred #412: past v1 -->

    The planner works on views.

    <!-- surfex: cache -->
    <!-- surfex: deferred dco-tek/other#7 -->
    Views are cached.
    <!-- /surfex -->
    """

    scanned = units(text)
    assert deferred(unit(scanned, "spec.md#views")) == %{ref: "#412", reason: "past v1"}
    assert deferred(unit(scanned, "spec.md#cache")) == %{ref: "dco-tek/other#7", reason: nil}
    assert class(unit(scanned, "spec.md#views")) == nil

    plain =
      text
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ "surfex: deferred"))
      |> Enum.join("\n")
      |> units()

    for s <- scanned, do: assert(s.hash == unit(plain, s.id).hash)
  end

  @tag verifies: "class-patterns"
  test "files: and headings: class by pattern; a marker beats one; the first match wins" do
    list = [
      {"decision", "a decision record", files: ["spec/1*-*.md"]},
      {"process", "how the project works", headings: ~r/^Process\b/},
      {"arch-process", "both", files: ["spec/02-*.md"], headings: ~r/^Process\b/},
      {"informative", @informative}
    ]

    text = """
    # D1. Use markdown

    Because.

    # Process notes

    How.

    # Plain
    <!-- surfex: class informative -->

    Text.
    """

    decisions = Markdown.sections(text, "spec/13-decisions.md", spec_classes: classes(list))
    assert class(unit(decisions, "spec/13-decisions.md#D1. Use markdown")).name == "decision"
    assert class(unit(decisions, "spec/13-decisions.md#D1. Use markdown")).by == :pattern
    # The first pattern that matches wins: decision is declared before process.
    assert class(unit(decisions, "spec/13-decisions.md#Process notes")).name == "decision"
    assert class(unit(decisions, "spec/13-decisions.md#Plain")).by == :marker

    arch = Markdown.sections(text, "spec/02-arch.md", spec_classes: classes(list))
    assert class(unit(arch, "spec/02-arch.md#D1. Use markdown")) == nil
    assert class(unit(arch, "spec/02-arch.md#Process notes")).name == "process"

    reordered = [Enum.at(list, 2) | List.delete_at(list, 2)]
    arch = Markdown.sections(text, "spec/02-arch.md", spec_classes: classes(reordered))
    assert class(unit(arch, "spec/02-arch.md#Process notes")).name == "arch-process"
    assert class(unit(arch, "spec/02-arch.md#Plain")).name == "informative"
  end

  @tag :tmp_dir
  @tag verifies: "class-patterns"
  test "a project's scans read its spec_classes: patterns, globs against its spec files", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "spec"))
    File.write!(Path.join(dir, "spec/13-decisions.md"), "# D1. Markdown\n\nBecause.\n")
    File.write!(Path.join(dir, "spec/01-goals.md"), "# Goals\n\nWhat.\n")

    config = [
      sources: ["spec/*.md"],
      spec_classes: [{"decision", "a decision record", files: ["spec/13-*.md"]}]
    ]

    classed =
      for s <- Config.scans(config, dir), s.kind == :spec, into: %{}, do: {s.id, class(s)}

    assert classed["spec/13-decisions.md#D1. Markdown"].name == "decision"
    assert classed["spec/01-goals.md#Goals"] == nil

    missing = Keyword.put(config, :spec_classes, [{"decision", "r", files: ["spec/9*.md"]}])
    assert_raise ArgumentError, ~r/matches no spec file/, fn -> Config.scans(missing, dir) end
  end

  @tag verifies: "class-marker-alias"
  test "a declared alias reads a project's own comment as the class marker" do
    text = """
    # Background

    Some history.
    <!-- spec-coverage: informative -->

    # Rule

    A rule.
    """

    alias_list = [{"informative", @informative, marker: ~r/^spec-coverage: informative$/}]
    aliased = units(text, "spec.md", alias_list)
    background = unit(aliased, "spec.md#Background")

    assert class(background) == %{
             name: "informative",
             reason: @informative,
             note: nil,
             by: :alias
           }

    assert class(unit(aliased, "spec.md#Rule")) == nil

    plain = units(text, "spec.md", [])
    assert class(unit(plain, "spec.md#Background")) == nil
    refute unit(plain, "spec.md#Background").hash == background.hash

    unmarked = units(String.replace(text, "<!-- spec-coverage: informative -->\n", ""))
    assert unit(unmarked, "spec.md#Background").hash == background.hash
  end

  @tag verifies: "class-marker-errors"
  test "every misplaced or malformed marker raises naming the file and line" do
    for {text, line, why} <- [
          {"# A\n<!-- surfex: class informal -->\n", 2, "isn't declared"},
          {"# A\n<!-- surfex: b -->\n<!-- surfex: class informative -->\nx\n<!-- /surfex -->\n",
           3, "classes sections only"},
          {"# A\n\n<!-- surfex: r1 -->\n- a rule\n  <!-- surfex: class informative -->\n", 5,
           "rule r1"},
          {"# A\n<!-- surfex: class informative -->\n<!-- surfex: class informative -->\n", 3,
           "already classed"},
          {"# A\n<!-- surfex: class informative -->\n<!-- surfex: deferred #1 -->\n", 3,
           "already classed"},
          {"# A\n<!-- surfex: deferred soon -->\n", 2, "names its issue"},
          {"# A\n<!-- surfex: deferred #x: later -->\n", 2, "names its issue"}
        ] do
      error = assert_raise ArgumentError, fn -> units(text) end
      assert error.message =~ "spec.md:#{line}:"
      assert error.message =~ why
    end

    folded = "# A\n<!-- surfex: a -->\n\n## Sub\n<!-- surfex: class informative -->\nx\n"

    error =
      assert_raise ArgumentError, fn ->
        units(folded, "spec.md", [{"informative", "r"}], fold_paths: true)
      end

    assert error.message =~ "spec.md:5:"
    assert error.message =~ "fold_paths:"
    assert unit(units(folded), "spec.md#A/Sub") |> class() |> Map.get(:name) == "informative"

    for {list, why} <- [
          {[{"informative", ""}], "needs a reason"},
          {[{"in formative", "r"}], "letters, digits"},
          {[{"x", "r", pattern: ~r/x/}], "unknown options"},
          {[{"x", "r", headings: "Process"}], "a class is"},
          {[{"x", "r"}, {"x", "s"}], "different reasons"},
          {[{"x", "r", files: ["docs/*.md"]}], "matches no spec file"},
          {[:x], "a class is"},
          {:x, "must be a list"}
        ] do
      error =
        assert_raise ArgumentError, fn ->
          Config.spec_classes!([spec_classes: list], ["spec.md"])
        end

      assert error.message =~ why
    end

    assert Config.spec_classes!([], ["spec.md"]) == []
  end
end
