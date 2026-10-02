defmodule Surfex.SourceScanTest do
  @moduledoc """
  The claims `definition_hash/1` makes.

  These are asserted here because nothing downstream can check them: a consuming project's
  drift gate proves its goldens are *stable*, not that the hash is stable for the right
  reasons. A hash that changed on every reformat would still produce a self-consistent
  golden — it would just restamp every row, and the gate would cry wolf until someone
  turned it off.
  """

  use ExUnit.Case, async: true

  alias Surfex.SourceScan

  @definition """
  def transfer(from, to, amount) do
    debit(from, amount)
    credit(to, amount)
  end
  """

  @tag verifies: "source-not-compiled"
  test "code no compiler would accept is still read" do
    # Undefined functions and modules, and a behaviour that doesn't exist: compiling this
    # fails, reading it doesn't.
    source = ~S"""
    defmodule Unbuilt do
      @behaviour NoSuchBehaviour
      def f(x), do: not_defined_anywhere(x) + Missing.Module.call()
      def g, do: undefined_variable
    end
    """

    {_, [_ | _]} =
      Code.with_diagnostics([log: false], fn ->
        assert_raise CompileError, fn -> Code.compile_string(source) end
      end)

    [mod] = source |> Code.string_to_quoted!() |> SourceScan.defmodules()
    assert Enum.map(SourceScan.defs(mod), &{&1.name, &1.arity}) == [f: 1, g: 0]
    assert SourceScan.module_hash(mod) =~ ~r/^[0-9a-f]{8}$/
    refute Code.ensure_loaded?(Unbuilt)
  end

  describe "definition_hash/1 is a function of structure, not position" do
    @describetag verifies: "structure-versions"

    # The claim that lets a golden's Locus be a bare path instead of `path.ex:line`.
    test "a blank line above the definition does not change it" do
      assert SourceScan.definition_hash("\n\n" <> @definition) ==
               SourceScan.definition_hash(@definition)
    end

    test "reindenting does not change it" do
      indented = @definition |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

      assert SourceScan.definition_hash(indented) == SourceScan.definition_hash(@definition)
    end

    test "a comment inside the body does not change it" do
      with_comment =
        String.replace(@definition, "debit(from, amount)", "# why\n  debit(from, amount)")

      assert SourceScan.definition_hash(with_comment) == SourceScan.definition_hash(@definition)
    end

    test "but changing the body does" do
      changed = String.replace(@definition, "credit(to, amount)", "credit(to, amount + 1)")

      refute SourceScan.definition_hash(changed) == SourceScan.definition_hash(@definition)
    end

    test "and so does renaming it" do
      renamed = String.replace(@definition, "def transfer", "def move")

      refute SourceScan.definition_hash(renamed) == SourceScan.definition_hash(@definition)
    end
  end

  describe "definition_hash/1's shape" do
    @describetag verifies: "structure-versions"

    test "is 8 lowercase hex characters" do
      hash = SourceScan.definition_hash(@definition)

      assert String.length(hash) == 8
      assert hash =~ ~r/^[0-9a-f]{8}$/
    end

    test "accepts a quoted node and a source binary, and agrees on both" do
      quoted = Code.string_to_quoted!(@definition)

      assert SourceScan.definition_hash(quoted) == SourceScan.definition_hash(@definition)
    end

    test "distinguishes definitions that differ only in a literal" do
      refute SourceScan.definition_hash("def f, do: 1") ==
               SourceScan.definition_hash("def f, do: 2")
    end
  end

  describe "defmodules/1" do
    @describetag verifies: "public-definitions"

    test "returns every module in source order, nested ones included" do
      ast =
        Code.string_to_quoted!("""
        defmodule Outer do
          defmodule Inner do
          end
        end

        defmodule Second do
        end
        """)

      names =
        ast
        |> SourceScan.defmodules()
        |> Enum.map(fn {:defmodule, _, [{:__aliases__, _, name}, _]} -> name end)

      assert names == [[:Outer], [:Inner], [:Second]]
    end

    test "an AST with no modules yields none" do
      assert SourceScan.defmodules(Code.string_to_quoted!("1 + 1")) == []
    end
  end

  # Given a starting directory, never by changing the working directory: that belongs to
  # the whole VM, and this module runs async (#27).
  describe "project_root/2" do
    @describetag verifies: "finding-lib-sources"

    setup do
      root = Path.join(System.tmp_dir!(), "surfex-root-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "nested/deeper"))
      File.write!(Path.join(root, "mix.exs"), "")
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "ascends to the directory holding the marker", %{root: root} do
      found = SourceScan.project_root("mix.exs", Path.join(root, "nested/deeper"))
      # Compared through `Path.expand/1` because a tmp dir is often reached via a symlink.
      assert Path.expand(found) == Path.expand(root)
    end

    test "falls back to the starting directory when the marker is nowhere", %{root: root} do
      start = Path.join(root, "nested")
      assert SourceScan.project_root("no-such-marker-anywhere", start) == Path.expand(start)
    end

    test "starts from the working directory by default" do
      assert SourceScan.project_root("mix.exs") == Path.expand(Path.join(__DIR__, "../.."))
    end
  end

  describe "lib_sources/1" do
    @describetag verifies: "finding-lib-sources"

    setup do
      root = Path.join(System.tmp_dir!(), "surfex-src-#{System.unique_integer([:positive])}")

      for dir <- ~w(lib/a deps/other/lib _build/dev/lib/x),
          do: File.mkdir_p!(Path.join(root, dir))

      File.write!(Path.join(root, "mix.exs"), "")
      File.write!(Path.join(root, "lib/a/one.ex"), "")
      File.write!(Path.join(root, "deps/other/mix.exs"), "")
      File.write!(Path.join(root, "deps/other/lib/two.ex"), "")
      File.write!(Path.join(root, "_build/dev/lib/x/three.ex"), "")
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    # A scan that catalogued its own dependencies would report a surface the project does
    # not own, which is worse than reporting none.
    test "finds first-party sources and excludes deps and _build", %{root: root} do
      assert root |> SourceScan.lib_sources() |> Enum.map(&Path.basename/1) == ["one.ex"]
    end

    # #9: ExUnit's tmp_dir trees and test fixtures have a lib/ too. Counting them made a
    # golden drift on the machine that had just run the tests, and never in CI.
    test "only a Mix project's own lib/, outside test, tmp and hidden trees", %{root: root} do
      tree = %{
        "app/mix.exs" => "",
        "app/lib/member.ex" => "",
        "loose/lib/no_mix.ex" => "",
        "test/fixtures/proj/mix.exs" => "",
        "test/fixtures/proj/lib/fixture.ex" => "",
        "tmp/T/case/mix.exs" => "",
        "tmp/T/case/lib/scratch.ex" => "",
        ".hidden/mix.exs" => "",
        ".hidden/lib/hidden.ex" => "",
        "app/test/support/lib/support.ex" => ""
      }

      for {path, text} <- tree do
        File.mkdir_p!(Path.join(root, Path.dirname(path)))
        File.write!(Path.join(root, path), text)
      end

      assert root |> SourceScan.lib_sources() |> Enum.map(&Path.relative_to(&1, root)) ==
               ["app/lib/member.ex", "lib/a/one.ex"]
    end
  end

  describe "defs/1" do
    @describetag verifies: "public-definitions"

    defp defs(source) do
      [mod | _] = source |> Code.string_to_quoted!() |> SourceScan.defmodules()
      SourceScan.defs(mod)
    end

    defp arities(source), do: source |> defs() |> Enum.map(&{&1.name, &1.arity, &1.kind})

    test "groups clauses, expands defaults, keeps public definers" do
      assert arities(~S"""
             defmodule M do
               def f(a, b \\ 1)
               def f(0, b), do: b
               def f(a, b), do: a + b
               def g, do: :g
               defmacro m(x), do: x
               defguard is_z(n) when n == 0
               defdelegate d(x), to: Kernel, as: :abs
               defp p(x), do: x
               defmacrop mp(x), do: x
               defguardp is_p(n) when n > 0
               def unquote(:dyn)(), do: 1
             end
             """) == [
               {:d, 1, :function},
               {:f, 1, :function},
               {:f, 2, :function},
               {:g, 0, :function},
               {:is_z, 1, :macro},
               {:m, 1, :macro}
             ]
    end

    test "@doc false hides one function and does not leak onto the next" do
      assert arities("""
             defmodule M do
               @doc false
               def hidden(x), do: x
               def hidden(x, y), do: {x, y}
               def shown(x), do: x
             end
             """) == [{:hidden, 2, :function}, {:shown, 1, :function}]
    end

    test "later clauses inherit the first clause's visibility" do
      assert arities("""
             defmodule M do
               @doc false
               def h(0), do: 0
               def h(n), do: n
             end
             """) == []
    end

    test "an @impl callback is hidden unless it has its own @doc" do
      assert arities("""
             defmodule M do
               @impl true
               def init(a), do: a
               @impl true
               @doc "shown"
               def call(a), do: a
               @impl false
               def plain(a), do: a
             end
             """) == [{:call, 1, :function}, {:plain, 1, :function}]
    end

    test "nested modules' definitions are not the parent's" do
      assert arities("""
             defmodule M do
               def outer, do: 1
               defmodule Inner do
                 def inner, do: 2
               end
             end
             """) == [{:outer, 0, :function}]
    end

    test "a function's hash ignores position and changes with any clause" do
      base = "def f(0), do: 0\n  def f(n), do: n * 2"

      hash = fn body ->
        [%{hash: h}] = defs("defmodule M do\n  #{body}\nend\n")
        h
      end

      assert hash.("\n\n# a comment\n" <> base) == hash.(base)
      assert hash.(String.replace(base, "\n  ", "\n      ")) == hash.(base)
      refute hash.(String.replace(base, "n * 2", "n * 3")) == hash.(base)
      refute hash.(String.replace(base, "f(0), do: 0", "f(0), do: 1")) == hash.(base)
    end

    test "hidden_module?/1 reads @moduledoc false" do
      [hidden, shown] =
        "defmodule A do\n @moduledoc false\nend\ndefmodule B do\n @moduledoc \"b\"\nend"
        |> Code.string_to_quoted!()
        |> SourceScan.defmodules()

      assert SourceScan.hidden_module?(hidden)
      refute SourceScan.hidden_module?(shown)
    end
  end

  # #20: a function's hash covers what it depends on, not only its own clauses.
  describe "defs/1: what a function's hash depends on" do
    @describetag verifies: "structure-versions"

    @base ~S"""
    defmodule M do
      @rate 5
      @other 1
      def price(x), do: x * @rate + fee(x)
      def piped(x), do: x |> fee()
      def cap, do: Enum.map([1], &fee/1)
      def dflt(x), do: opt(x)
      def rec(n), do: loop(n)
      def total, do: sub()
      def sub, do: 1
      defp fee(x), do: deep(x) + 1
      defp deep(x), do: x * 2
      defp unused(x), do: x
      defp opt(a, b \\ 1), do: a + b
      defp loop(0), do: 0
      defp loop(n), do: loop(n - 1)
    end
    """

    defp hashes(source) do
      [mod] = source |> Code.string_to_quoted!() |> SourceScan.defmodules()
      Map.new(SourceScan.defs(mod), &{&1.name, &1.hash})
    end

    defp changes?(fun, from, to) do
      assert @base =~ from
      hashes(@base)[fun] != hashes(String.replace(@base, from, to))[fun]
    end

    test "a private helper it calls, directly or transitively" do
      assert changes?(:price, "deep(x) + 1", "deep(x) + 2")
      assert changes?(:price, "do: x * 2", "do: x * 3")
    end

    test "a module attribute it reads, and no other" do
      assert changes?(:price, "@rate 5", "@rate 7")
      refute changes?(:price, "@other 1", "@other 2")
    end

    test "a helper it does not call is not part of it" do
      refute changes?(:price, "defp unused(x), do: x", "defp unused(x), do: x + 1")
    end

    test "piped calls, captures and default-argument calls are followed" do
      assert changes?(:piped, "deep(x) + 1", "deep(x) + 9")
      assert changes?(:cap, "deep(x) + 1", "deep(x) + 9")
      assert changes?(:dflt, "do: a + b", "do: a - b")
    end

    test "public callees are not followed: they have their own rows" do
      refute changes?(:total, "def sub, do: 1", "def sub, do: 2")
    end

    test "renaming a variable is not a change; changing an expression is" do
      refute changes?(
               :price,
               "def price(x), do: x * @rate + fee(x)",
               "def price(y), do: y * @rate + fee(y)"
             )

      assert changes?(:price, "x * @rate", "x + @rate")
    end

    test "recursion terminates" do
      assert is_binary(hashes(@base)[:rec])
    end
  end

  # #33: a module's version is its public surface, so its relations don't dangle on every
  # function edit.
  describe "module_hash/1" do
    @describetag verifies: "structure-versions"

    @mod ~S"""
    defmodule M do
      @moduledoc "doc"
      @behaviour B
      use GenServer
      defstruct [:a, :b]
      @type t :: integer
      @type u :: atom
      def f(x), do: x
      def g, do: 1
      defp p(x), do: x
    end
    """

    defp module_hash(source) do
      [mod | _] = source |> Code.string_to_quoted!() |> SourceScan.defmodules()
      SourceScan.module_hash(mod)
    end

    defp surface_changes?(from, to) do
      assert @mod =~ from
      module_hash(@mod) != module_hash(String.replace(@mod, from, to))
    end

    test "a function body or a private helper is not part of it" do
      refute surface_changes?("def f(x), do: x", "def f(x), do: x + 1")
      refute surface_changes?("defp p(x), do: x", "defp p(x), do: x * 2")
      refute surface_changes?("defp p(x), do: x", "defp p(x), do: x\n  defp q, do: 0")
    end

    test "its public definitions, docs, behaviours, uses, struct and types are" do
      assert surface_changes?("def g, do: 1", "def g, do: 1\n  def h, do: 2")
      assert surface_changes?(~s("doc"), ~s("docs"))
      assert surface_changes?("@behaviour B", "@behaviour C")
      assert surface_changes?("use GenServer", "use Agent")
      assert surface_changes?("[:a, :b]", "[:a, :c]")
      assert surface_changes?("@type t :: integer", "@type t :: float")
      assert surface_changes?("@type u :: atom", "@opaque u :: atom")
      assert surface_changes?("@type u :: atom", "@type u :: atom\n  @callback c() :: :ok")
      assert surface_changes?("@type u :: atom", "@type u :: atom\n  @macrocallback m() :: :ok")
      assert surface_changes?("defstruct [:a, :b]", "defexception [:a, :b]")
    end

    test "a nested module is not part of it" do
      refute surface_changes?(
               "defp p(x), do: x",
               "defp p(x), do: x\n  defmodule Inner do\n    def i, do: 1\n  end"
             )
    end

    test "reordering is not a change" do
      refute surface_changes?(
               "  @type t :: integer\n  @type u :: atom\n",
               "  @type u :: atom\n  @type t :: integer\n"
             )

      refute surface_changes?(
               "  def f(x), do: x\n  def g, do: 1\n",
               "  def g, do: 1\n  def f(x), do: x\n"
             )
    end
  end
end
