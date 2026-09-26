defmodule Surfex.ProfileTest do
  use ExUnit.Case, async: true

  alias Surfex.Profile

  @base [sources: ["spec.md"], shape: ~r/^x_/]

  defp new(extra), do: Profile.new!(@base ++ extra)

  test "defaults fill in, rules gain :name and :parent_cited" do
    p = new(classes: [{"c", "why"}], rules: [%{class: "c", kinds: [:f]}])
    assert Regex.match?(p.token, "abc")
    assert [%{class: "c", kinds: [:f], name: nil, parent_cited: false}] = p.rules
  end

  test "sources and shape are required" do
    assert_raise ArgumentError, ~r/:sources is required/, fn -> Profile.new!(shape: ~r/x/) end
    assert_raise ArgumentError, ~r/:shape is required/, fn -> Profile.new!(sources: ["a"]) end
  end

  test "an unknown key is named" do
    assert_raise ArgumentError, ~r/unknown profile keys: \[:sorces\]/, fn -> new(sorces: []) end
  end

  test "a wrong type is named" do
    assert_raise ArgumentError, ~r/:shape is invalid/, fn -> new(shape: "x_") end
    assert_raise ArgumentError, ~r/:sources is invalid/, fn -> new(sources: []) end
    assert_raise ArgumentError, ~r/:subjects is invalid/, fn -> new(subjects: [%{file: "a"}]) end
    assert_raise ArgumentError, ~r/unknown profile keys: \[:scope\]/, fn -> new(scope: nil) end
    assert_raise ArgumentError, ~r/:normalise is invalid/, fn -> new(normalise: [{"a", "b"}]) end
  end

  test "a rule must name a declared class" do
    assert_raise ArgumentError, ~r/class "nope", which :classes lacks/, fn ->
      new(rules: [%{class: "nope", kinds: [:f]}])
    end
  end

  test "a rule may not excuse a never-excused kind" do
    assert_raise ArgumentError, ~r/would excuse \[:wire\]/, fn ->
      new(
        classes: [{"c", "why"}],
        rules: [%{class: "c", kinds: [:f, :wire]}],
        never_excused: [:wire]
      )
    end
  end

  test "a malformed rule is named" do
    assert_raise ArgumentError, ~r/needs :class and :kinds/, fn -> new(rules: [%{class: "c"}]) end
    assert_raise ArgumentError, ~r/:rules is invalid/, fn -> new(rules: :none) end

    assert_raise ArgumentError, ~r/non-empty :kinds/, fn ->
      new(classes: [{"c", "w"}], rules: [%{class: "c", kinds: []}])
    end
  end
end
