defmodule Surfex.LibraryApiContractsTest do
  # #334: each contract §23.1.1 and §23.2 state is verified by a test that calls its
  # function and checks what the contract's prose and the function's @doc say, so its
  # `implements` relation is reviewed against a green run of the code it names.
  use ExUnit.Case, async: true

  alias Surfex.{Golden, SourceScan}

  defp contracts_write(root, path, text) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp contracts_module(source), do: Code.string_to_quoted!(source, token_metadata: true)

  describe "Surfex.Golden" do
    @tag verifies: ["Surfex.Golden.render/1"]
    test "render/1 is a pure function of its spec, the same for any order of its rows" do
      spec = %{
        name: "SURFACE",
        purpose: "What the code declares.",
        task: "surface",
        gate: "surface",
        hardness: :hard,
        columns: ["Item", "Locus"],
        rows: [
          %{"Item" => {:code, "B.f/1"}, "Locus" => {:locus, "lib/b.ex", nil}},
          %{"Item" => {:code, "A.f/1"}, "Locus" => {:locus, "lib/a.ex", nil}}
        ]
      }

      text = Golden.render(spec)
      assert text == Golden.render(%{spec | rows: Enum.reverse(spec.rows)})
      assert text == Golden.render(spec)
      assert String.starts_with?(text, "# SURFACE\nWhat the code declares.\n")
      [a, b] = for row <- ["`A.f/1`", "`B.f/1`"], do: :binary.match(text, row)
      assert a < b
    end

    @tag verifies: ["Surfex.Golden.stat/2"]
    test "stat/2 is its lead, its dimensions and its rendered line" do
      assert Golden.stat("3 items", [{"hard", 2}, "drifted"]) == %{
               lead: "3 items",
               dims: [{"hard", 2}, "drifted"],
               text: Golden.stat_line("3 items", [{"hard", 2}, "drifted"])
             }
    end

    @tag verifies: ["Surfex.Golden.stat_line/2"]
    test "stat_line/2 is the bold lead, then each dimension's label and value, a bare label a flag" do
      assert IO.iodata_to_binary(Golden.stat_line("3 items", [{"hard", 2}, "drifted"])) ==
               "**3 items** · hard 2 · drifted"
    end

    @tag verifies: ["Surfex.Golden.natural_key/1"]
    test "natural_key/1 sorts the digit runs of a text by number" do
      assert Enum.sort_by(~w(Foo.10 Foo.9 Bar.2), &Golden.natural_key/1) == ~w(Bar.2 Foo.9 Foo.10)
    end
  end

  describe "Surfex.SourceScan" do
    @describetag :tmp_dir

    @tag verifies: ["Surfex.SourceScan.project_root/2"]
    test "project_root/2 ascends from start to the first directory holding marker, else start",
         %{tmp_dir: root} do
      contracts_write(root, "mix.exs", "")
      deep = Path.join(root, "lib/a/b")
      File.mkdir_p!(deep)

      assert SourceScan.project_root("mix.exs", deep) == root
      assert SourceScan.project_root("no-such-marker", deep) == deep
    end

    @tag verifies: ["Surfex.SourceScan.lib_sources/1"]
    test "lib_sources/1 is every .ex in a first-party lib/, sorted, never one under deps or test",
         %{tmp_dir: root} do
      contracts_write(root, "mix.exs", "")
      contracts_write(root, "lib/b.ex", "")
      contracts_write(root, "lib/a/a.ex", "")
      contracts_write(root, "lib/notes.md", "")
      contracts_write(root, "deps/dep/mix.exs", "")
      contracts_write(root, "deps/dep/lib/dep.ex", "")
      contracts_write(root, "test/fixture/mix.exs", "")
      contracts_write(root, "test/fixture/lib/f.ex", "")
      contracts_write(root, "scratch/lib/s.ex", "")

      assert SourceScan.lib_sources(root) == [
               Path.join(root, "lib/a/a.ex"),
               Path.join(root, "lib/b.ex")
             ]
    end

    @tag verifies: ["Surfex.SourceScan.defs/1"]
    test "defs/1 is a module's public definitions, sorted, each with its version and doc version" do
      module =
        contracts_module("""
        defmodule M do
          @doc "Bee."
          def b(x), do: x
          def a(x, y \\\\ 1), do: {x, y}
          @doc false
          def hidden, do: :ok
          defp private, do: :ok
          defmodule Inner do
            def inner, do: :ok
          end
        end
        """)

      defs = SourceScan.defs(module)

      assert for(d <- defs, do: {d.name, d.arity, d.kind}) == [
               {:a, 1, :function},
               {:a, 2, :function},
               {:b, 1, :function}
             ]

      [a1, a2, b] = defs
      assert a1.hash == a2.hash and a1.hash != b.hash
      assert is_binary(b.doc) and b.doc != a1.doc
      assert {_, _} = b.lines
    end

    @tag verifies: ["Surfex.SourceScan.types/1"]
    test "types/1 is a module's public types, each with its version and doc version" do
      module =
        contracts_module("""
        defmodule M do
          @typedoc "A thing."
          @type t :: atom
          @opaque o :: term
          @typep p :: term
          @typedoc false
          @type gone :: term
        end
        """)

      assert [%{name: :o, arity: 0}, %{name: :t, arity: 0} = t] =
               Enum.sort_by(SourceScan.types(module), & &1.name)

      assert is_binary(t.hash) and is_binary(t.doc)
      assert {_, _} = t.lines
    end

    @tag verifies: ["Surfex.SourceScan.line_range/1"]
    test "line_range/1 is the first and last line a quoted node spans, or nil with no metadata" do
      module = contracts_module("defmodule M do\n  def f, do: :ok\n\nend\n")

      assert SourceScan.line_range(module) == {1, 4}
      assert SourceScan.line_range(:atom) == nil
    end

    @tag verifies: ["Surfex.SourceScan.module_hash/1"]
    test "module_hash/1 covers a module's public surface, not its function bodies" do
      version = fn body ->
        SourceScan.module_hash(contracts_module("defmodule M do\n#{body}\nend"))
      end

      base = version.("@moduledoc \"M.\"\ndef f(x), do: x")

      assert version.("@moduledoc \"M.\"\ndef f(x), do: x + 1") == base
      refute version.("@moduledoc \"Em.\"\ndef f(x), do: x") == base
      refute version.("@moduledoc \"M.\"\ndef f(x), do: x\ndef g, do: :ok") == base
    end

    @tag verifies: ["Surfex.SourceScan.hidden_module?/1"]
    test "hidden_module?/1 says whether a defmodule declares @moduledoc false in its own body" do
      assert SourceScan.hidden_module?(contracts_module("defmodule M do\n@moduledoc false\nend"))
      refute SourceScan.hidden_module?(contracts_module("defmodule M do\n@moduledoc \"M.\"\nend"))

      refute SourceScan.hidden_module?(
               contracts_module("defmodule M do\ndefmodule I do\n@moduledoc false\nend\nend")
             )
    end

    @tag verifies: ["Surfex.SourceScan.defmodules/1"]
    test "defmodules/1 is every defmodule node in source order, nested ones included" do
      ast = contracts_module("defmodule A do\ndefmodule A.B do\nend\nend\ndefmodule C do\nend")

      assert for(
               {:defmodule, _, [{:__aliases__, _, parts}, _]} <- SourceScan.defmodules(ast),
               do: Module.concat(parts)
             ) == [A, A.B, C]
    end

    @tag verifies: ["Surfex.SourceScan.definition_hash/1"]
    test "definition_hash/1 is the same for the same code, as source or AST, whatever its layout" do
      hash = SourceScan.definition_hash("def f(x), do: x + 1")

      assert hash == SourceScan.definition_hash("def f(x) do\n  x +\n    1\nend")
      assert hash == SourceScan.definition_hash(Code.string_to_quoted!("def f(x), do: x + 1"))
      refute hash == SourceScan.definition_hash("def f(x), do: x + 2")
      assert hash =~ ~r/\A[0-9a-f]{8}\z/
    end
  end

  describe "Surfex.Scanner" do
    @tag verifies: ["Surfex.Scanner.callback:items/2"]
    test "items/2: a scanner gives every item under root, keyed and hashed, file relative to root" do
      assert {:items, 2} in Surfex.Scanner.behaviour_info(:callbacks)
      root = "test/fixtures/dsl_project"
      items = Surfex.Test.FixtureDsl.Scanner.items(root, [])

      assert items != []

      for item <- items do
        assert %Surfex.Item{file: "lib/" <> _, hash: hash} = item
        assert File.exists?(Path.join(root, item.file))
        assert is_binary(hash)
      end

      assert Surfex.Test.FixtureDsl.Scanner.items(root, paths: ["none/*.ex"]) == []
    end

    @tag verifies: ["Surfex.Scanner.callback:calls/3"]
    test "calls/3 is optional, answers the keys a remote call names, and [] for a call it doesn't recognise" do
      assert Surfex.Scanner.behaviour_info(:optional_callbacks) == [calls: 3]
      call = Code.string_to_quoted!("FixtureDsl.run(Order, :checkout, input)")
      aliases = %{FixtureDsl: "Surfex.Test.FixtureDsl", Order: "Shop.Order"}

      assert Surfex.Test.FixtureDsl.Scanner.calls(call, aliases, []) == ["Shop.Order.checkout"]

      assert Surfex.Test.FixtureDsl.Scanner.calls(
               Code.string_to_quoted!("Enum.map(xs, f)"),
               aliases,
               []
             ) ==
               []
    end
  end
end
