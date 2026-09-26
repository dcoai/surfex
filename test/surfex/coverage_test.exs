defmodule Surfex.CoverageTest do
  use ExUnit.Case, async: true

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

  test "a never-excused kind is a gap" do
    assert verdict(item(:wire, "hdr")) == :gap
  end

  test "the first matching rule wins" do
    p = %{profile() | rules: Enum.reverse(profile().rules)}
    both = item(:function, "do_helper")
    assert Coverage.verdict(both, MapSet.new(), p) == {:expected, "helpers"}

    p = %{p | rules: [%{class: "members", kinds: [:function], name: nil, parent_cited: false}]}
    assert Coverage.verdict(both, MapSet.new(), p) == {:expected, "members"}
  end

  test "verdicts/3 joins by_item, one pair per item, in item order" do
    items = [item(:wire, "hdr"), item(:field, "len", "hdr"), item(:function, "main")]

    assert Coverage.verdicts(items, %{"hdr" => ["spec — 1"]}, profile()) == [
             {Enum.at(items, 0), :cited},
             {Enum.at(items, 1), {:expected, "members"}},
             {Enum.at(items, 2), :gap}
           ]
  end

  # #15: keyed by Item.key/1, the second item's verdict overwrote the first's, and a GAP
  # could vanish from the gate.
  test "two items sharing a key each keep their own verdict" do
    excused = item(:function, "do_twin")
    gap = item(:macro, "do_twin")

    assert Coverage.verdicts([gap, excused], %{}, profile()) == [
             {gap, :gap},
             {excused, {:expected, "helpers"}}
           ]
  end
end
