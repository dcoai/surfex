defmodule Surfex.CoverageTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "coverage-verdict"

  alias Surfex.{Coverage, Item, Profile}

  defp item(kind, name, parent \\ nil),
    do: %Item{kind: kind, name: name, file: "x", hash: "0", parent: parent}

  defp profile do
    Profile.new!(
      sources: ["spec.md"],
      shape: ~r/x/,
      classes: [{"helpers", "the code's own factoring"}, {"members", "covered by the parent"}],
      rules: [
        %{class: "members", kinds: [:field], parent_cited: true},
        %{class: "helpers", kinds: [:function], name: ~r/^do_/},
        %{class: "helpers", kinds: [:function, :macro], name: ~r/_helper$/}
      ],
      never_excused: [:wire]
    )
  end

  defp verdict(item, cited \\ []), do: Coverage.verdict(item, MapSet.new(cited), profile())

  test "a cited item is cited, whatever the rules say" do
    assert verdict(item(:wire, "hdr"), ["hdr"]) == :cited
    assert verdict(item(:function, "do_x"), ["do_x"]) == :cited
  end

  test "a class excuses by kind and name pattern" do
    assert verdict(item(:function, "do_x")) == {:expected, "helpers"}
    assert verdict(item(:macro, "x_helper")) == {:expected, "helpers"}
    assert verdict(item(:macro, "do_x")) == :gap
    assert verdict(item(:function, "entry_point")) == :gap
  end

  test "a member is excused only while its parent is cited" do
    assert verdict(item(:field, "len", "hdr"), ["hdr"]) == {:expected, "members"}
    assert verdict(item(:field, "len", "hdr")) == :gap
    assert verdict(item(:field, "len")) == :gap
  end

  # #71: scaffolding is plumbing because of the module it lives in, not its name.
  @tag verifies: "rule-parent"
  test "parent: excuses a module family's members, composed with the rule's other keys" do
    scaffolding =
      Profile.new!(
        sources: ["spec.md"],
        shape: ~r/x/,
        classes: [{"scaffolding", "what the generator emitted"}],
        rules: [
          %{
            class: "scaffolding",
            kinds: [:function, :macro],
            parent: ~r/^MyAppWeb(\.(CoreComponents|Layouts))?$/
          },
          %{
            class: "scaffolding",
            kinds: [:module],
            name: ~r/^MyAppWeb\.(CoreComponents|Layouts)$/
          }
        ]
      )

    v = &Coverage.verdict(&1, MapSet.new(), scaffolding)
    assert v.(item(:function, "list/1", "MyAppWeb.CoreComponents")) == {:expected, "scaffolding"}
    assert v.(item(:macro, "html/0", "MyAppWeb")) == {:expected, "scaffolding"}
    # Another module's list/1 is not scaffolding: the family is the parent, not the name.
    assert v.(item(:function, "list/1", "MyApp.Events")) == :gap
    assert v.(item(:function, "list/1", "MyAppWeb.CoreComponentsExtra")) == :gap
    # A module has no parent: parent: never matches it; name: excuses the modules.
    assert v.(item(:module, "MyAppWeb.Layouts")) == {:expected, "scaffolding"}
    assert v.(item(:module, "MyAppWeb.Other")) == :gap

    # It composes: every constraint a rule gives must hold.
    both =
      Profile.new!(
        sources: ["spec.md"],
        shape: ~r/x/,
        classes: [{"s", "r"}],
        rules: [%{class: "s", kinds: [:function], parent: ~r/^MyAppWeb/, name: ~r/^render/}]
      )

    assert Coverage.verdict(item(:function, "render/2", "MyAppWeb.X"), MapSet.new(), both) ==
             {:expected, "s"}

    assert Coverage.verdict(item(:function, "list/1", "MyAppWeb.X"), MapSet.new(), both) == :gap

    assert_raise ArgumentError, ~r/non-regex :parent/, fn ->
      Profile.new!(
        sources: ["spec.md"],
        shape: ~r/x/,
        classes: [{"s", "r"}],
        rules: [%{class: "s", kinds: [:function], parent: "MyAppWeb"}]
      )
    end
  end

  test "a never-excused kind is a gap, whatever the rules say" do
    assert verdict(item(:wire, "hdr")) == :gap

    # A rule that would excuse it (new!/1 refuses one; a hand-built map may carry it).
    excusing = %{class: "helpers", kinds: [:wire], name: nil, parent_cited: false}

    assert Coverage.verdict(item(:wire, "hdr"), MapSet.new(), %{profile() | rules: [excusing]}) ==
             :gap
  end

  test "the first matching rule wins" do
    p = %{profile() | rules: Enum.reverse(profile().rules)}
    both = item(:function, "do_helper")
    assert Coverage.verdict(both, MapSet.new(), p) == {:expected, "helpers"}

    p = %{p | rules: [%{class: "members", kinds: [:function], name: nil, parent_cited: false}]}
    assert Coverage.verdict(both, MapSet.new(), p) == {:expected, "members"}
  end

  # #15: two items sharing a key are judged each on its own: the gap stays a gap.
  test "two items sharing a key each keep their own verdict" do
    excused = item(:function, "do_twin")
    gap = item(:macro, "do_twin")

    assert Coverage.verdict(gap, MapSet.new(), profile()) == :gap
    assert Coverage.verdict(excused, MapSet.new(), profile()) == {:expected, "helpers"}
  end

  test "verdict/3 reads the rules from a coverage map as from a profile" do
    coverage =
      Surfex.Profile.coverage!(
        classes: [{"helpers", "the code's own factoring"}],
        rules: [%{class: "helpers", kinds: [:function], name: ~r/^do_/}]
      )

    assert Coverage.verdict(item(:function, "do_twin"), MapSet.new(), coverage) ==
             {:expected, "helpers"}

    assert Coverage.verdict(item(:function, "main"), MapSet.new(), coverage) == :gap
  end
end
