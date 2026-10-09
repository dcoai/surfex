defmodule Surfex.LibraryApiTest do
  # #150: Surfex.Golden and Surfex.SourceScan are the whole of surfex for a project that
  # renders surface goldens without a relation log. Their documented surface is pinned
  # here, so a change to it is a deliberate one, made with a CHANGELOG entry (§21).
  use ExUnit.Case, async: true
  @moduletag verifies: "library-api-stable"

  @golden_functions ~w(natural_key/1 render/1 stat/2 stat_line/2)
  @golden_types ~w(cell/0 group/0 row/0 spec/0 stat/0)
  @scan_functions ~w(definition_hash/1 defmodules/1 defs/1 hidden_module?/1 lib_sources/1
                     line_range/1 module_hash/1 project_root/2 types/1)
  @scan_types ~w(definition/0)

  defp documented(module, kinds) do
    {:docs_v1, _, _, _, %{}, _, docs} = Code.fetch_docs(module)

    for {{kind, name, arity}, _, _, doc, _} <- docs,
        kind in kinds,
        doc != :hidden,
        do: "#{name}/#{arity}"
  end

  test "the documented functions and types of Golden and SourceScan are exactly the pinned ones" do
    assert Enum.sort(documented(Surfex.Golden, [:function, :macro])) == @golden_functions
    assert Enum.sort(documented(Surfex.Golden, [:type])) == @golden_types
    assert Enum.sort(documented(Surfex.SourceScan, [:function, :macro])) == @scan_functions
    assert Enum.sort(documented(Surfex.SourceScan, [:type])) == @scan_types

    # project_root/2's default keeps the one-argument form library users call. Loaded
    # first: function_exported?/3 is false for a module not loaded yet, and tests load
    # modules lazily, so without it the answer depended on test order (#158).
    Code.ensure_loaded!(Surfex.SourceScan)
    assert function_exported?(Surfex.SourceScan, :project_root, 1)
  end

  test "definition_hash/1's output is stable: the same code gives the same version, release to release" do
    assert Surfex.SourceScan.definition_hash("def f(x), do: x + 1") == "f9bc39cf"
  end
end
