defmodule Surfex.SignatureExtentTest do
  # §11.8: a contract signature ends where its text parses, not where its indentation
  # returns to the head's column (#271).
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown

  # The section's own prose says what its hint does, so each test verifies both.
  @moduletag verifies: ["signature-extent", "contract-signature-extent"]

  defp contracts(text) do
    for u <- Markdown.sections(text, "spec.md", []), u.role == :contract do
      {u.id, u.location.lines}
    end
  end

  defp fence(lines), do: "# A\n\n<!-- surfex: contract module: M -->\n```elixir\n#{lines}```\n"

  # Each closer, back at its head's column: the head on line 5, the closer on line 7.
  @closers [
    {"}", "@spec f() :: %{\n  a: t\n}\n"},
    {")", "@spec f(\n  t\n) :: t\n"},
    {"]", "@spec f() :: [\n  t\n]\n"},
    {">>", "@spec f() :: <<\n  _::8\n>>\n"}
  ]

  for {closer, lines} <- @closers do
    test "a closing #{closer} at the head's column ends the signature, not the line before it" do
      assert [{"spec.md#M.f/" <> _, {5, 7}}] = contracts(fence(unquote(lines)))
    end
  end

  test "a callback whose map closes at column 0, with comments inside, reads as one unit" do
    lines = """
    @callback plan() :: nil | %{
      kinds: [atom],                # where it offers itself
                                    # (:draft, :review, …)
      steps: [%{
        say: binary,                # what a step proposes
        hold: boolean               # whether it waits for approval
      }],
      tools: [binary]               # what the steps drive
    }
    """

    assert [{"spec.md#M.callback:plan/0", {5, 13}}] = contracts(fence(lines))
  end

  test "once a signature parses, only the lines indented under it are its own" do
    lines = """
    @spec f(a) :: a
          when a: term
    # a comment of the fence
    @spec g(t) ::
    t
    """

    assert [{"spec.md#M.f/1", {5, 6}}, {"spec.md#M.g/1", {8, 9}}] = contracts(fence(lines))
  end

  test "a real sketch still doesn't parse, and is reported at its own line" do
    error =
      assert_raise ArgumentError, fn ->
        contracts(fence("@spec f(%{id:, …}) :: t\n@spec g(t) :: t\n"))
      end

    assert error.message =~ "spec.md:5: the contract signature doesn't parse"
  end

  test "an unfinished signature stops at the next typespec attribute, not running into it" do
    for next <- ~w(@spec @callback @macrocallback @type @typep @opaque) do
      # `@spec f() :: @spec g() :: t` would parse: run into, the next head hides the error.
      for unfinished <- ["@spec f() ::\n", "@spec f() :: %{\n  a: t\n"] do
        lines = unfinished <> "#{next} g() :: t\n"
        assert Code.string_to_quoted(lines) |> elem(0) == :ok or unfinished =~ "%{"
        error = assert_raise ArgumentError, fn -> contracts(fence(lines)) end
        assert error.message =~ "spec.md:5: the contract signature doesn't parse"
      end
    end
  end

  # The property: a fence of typespecs that parses whole has no signature that doesn't
  # parse, whatever columns its continuation and closing lines sit at.
  test "every generated fence that parses whole yields its signatures without an error" do
    shapes = [
      fn i, c -> ["@spec f#{i}() :: %{", "#{i}a: t,", "#{i}b: [t]", "#{c}}"] end,
      fn i, c -> ["@callback f#{i}(", "#{i}t,", "#{i}u", "#{c}) :: t"] end,
      fn i, c -> ["@spec f#{i}() :: [", "#{i}{t, u}", "#{c}]"] end,
      fn i, c -> ["@spec f#{i}() :: <<", "#{i}_::8,", "#{i}_::_*8", "#{c}>>"] end,
      fn i, c -> ["@spec f#{i}(a) :: %{", "#{i}k: a", "#{c}}", "#{i}   when a: term"] end,
      fn i, c -> ["@macrocallback f#{i}(Macro.t()) ::", "#{c}Macro.t()"] end
    ]

    indents = ["", " ", "  ", "        "]

    fences =
      for {shape, n} <- Enum.with_index(shapes),
          inner <- indents,
          closer <- indents,
          extra <- [[], ["# a comment"], ["@type t :: term"], [""]] do
        shape.(n, closer)
        |> Enum.map(&String.replace_prefix(&1, "#{n}", inner))
        |> Kernel.++(extra)
        |> Kernel.++(["@spec last(t) :: t"])
      end

    whole =
      for lines <- fences,
          match?({:ok, _}, Code.string_to_quoted(Enum.join(lines, "\n"))),
          do: lines

    assert length(whole) > 50

    for lines <- whole do
      assert [_, _] = contracts(fence(Enum.join(lines, "\n") <> "\n")), Enum.join(lines, "\n")
    end
  end
end
