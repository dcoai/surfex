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

  @tag verifies: ["library-api-stable", "library-api"]
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

  # #208: a project scanner, and a DSL plugin above all, is written against these two (§23.1).
  @tag verifies: ["scanner-api-stable", "scanner-api"]
  test "Surfex.Scanner's callbacks and Surfex.Item's fields are exactly the pinned ones" do
    assert Enum.sort(Surfex.Scanner.behaviour_info(:callbacks)) == [calls: 3, items: 2]
    # calls/3 came later (#241), so it is optional: a scanner without it still works.
    assert Surfex.Scanner.behaviour_info(:optional_callbacks) == [calls: 3]

    fields = for %{field: f, required: r} <- Surfex.Item.__info__(:struct), do: {f, r}

    assert Enum.sort(fields) == [
             aliases: false,
             calls: false,
             detail: false,
             dispatch: false,
             doc: false,
             file: true,
             hash: true,
             hidden: false,
             kind: true,
             lines: false,
             name: true,
             parent: false,
             runs: false,
             shape: false,
             type: false,
             value: false
           ]

    item = %Surfex.Item{kind: :action, name: "checkout", file: "f.ex", hash: "h"}
    assert Surfex.Item.key(item) == "checkout"
    assert Surfex.Item.key(%{item | parent: "Shop.Order"}) == "Shop.Order.checkout"
  end

  @tag verifies: ["library-api-stable", "library-api"]
  test "definition_hash/1's output is stable: the same code gives the same version, release to release" do
    assert Surfex.SourceScan.definition_hash("def f(x), do: x + 1") == "f9bc39cf"
  end

  # #334: §23.1.1 and §23.2 state the pinned functions and callbacks as contract fences.
  # The pins above and the contracts below are one list: each is checked against the
  # other in both directions, reading the contracts as surfex reads them.

  defp contract_units(section) do
    config = Surfex.Status.Config.read!(".surfex.exs")
    spec_classes = Surfex.Status.Config.spec_classes!(config, ["spec.md"])

    "spec.md"
    |> File.read!()
    |> Surfex.Scan.Markdown.sections("spec.md", spec_classes: spec_classes)
    |> Enum.filter(&(&1.role == :contract and &1.within == "spec.md#" <> section))
  end

  # What one list has and the other lacks, both ways: `{pinned without a contract,
  # contracts of nothing pinned}`.
  defp contract_drift(pinned, contracts) do
    {pinned -- contracts, contracts -- pinned}
  end

  # A contract's signature, as its fence lines hold it, and the code's declaration of the
  # same function, both read as quoted Elixir with no metadata.
  defp contract_signature(%{location: %{lines: {first, last}}}) do
    "spec.md"
    |> File.read!()
    |> String.split("\n")
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.join("\n")
    |> Code.string_to_quoted!()
    |> contract_strip()
  end

  defp contract_declarations(file) do
    {_, found} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _, [{kind, _, [declaration]}]} = node, acc when kind in [:spec, :callback] ->
          {node, [{kind, contract_key(declaration), contract_strip(node)} | acc]}

        node, acc ->
          {node, acc}
      end)

    for {kind, key, node} <- found, into: %{}, do: {{kind, key}, node}
  end

  defp contract_key({:"::", _, [{:when, _, [call | _]}, _]}),
    do: contract_key({:"::", [], [call, nil]})

  defp contract_key({:when, _, [declaration | _]}), do: contract_key(declaration)
  defp contract_key({:"::", _, [{name, _, args}, _]}), do: "#{name}/#{length(args)}"

  defp contract_strip(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))

  defp contract_names(units, module) do
    for %{contract: contract} <- units,
        String.starts_with?(contract, module <> "."),
        do: String.replace_prefix(contract, module <> ".", "")
  end

  @tag verifies: ["library-function-contracts", "library-api-contracts"]
  test "§23.2's contracts are exactly the pinned functions of Golden and SourceScan" do
    units = contract_units("library-api-contracts")

    assert contract_drift(@golden_functions, Enum.sort(contract_names(units, "Surfex.Golden"))) ==
             {[], []}

    assert contract_drift(@scan_functions, Enum.sort(contract_names(units, "Surfex.SourceScan"))) ==
             {[], []}

    assert length(units) == length(@golden_functions) + length(@scan_functions)
  end

  @tag verifies: ["library-function-contracts", "library-api-contracts"]
  test "the cross-check fails both ways: a pinned function with no contract, a contract pinning nothing" do
    pinned = ~w(render/1 stat/2)

    assert contract_drift(pinned, ~w(render/1)) == {["stat/2"], []}
    assert contract_drift(pinned, ~w(render/1 stat/2 natural_key/1)) == {[], ["natural_key/1"]}
    assert contract_drift(pinned, ~w(render/1 stat/2)) == {[], []}
  end

  @tag verifies: ["library-function-contracts", "library-api-contracts"]
  test "each of §23.2's contracts states its function's @spec as the code declares it" do
    code = %{
      "Surfex.Golden" => contract_declarations("lib/surfex/golden.ex"),
      "Surfex.SourceScan" => contract_declarations("lib/surfex/source_scan.ex")
    }

    for %{contract: contract} = unit <- contract_units("library-api-contracts") do
      [module, key] = String.split(contract, ~r/\.(?=[^.]+\/\d+$)/)
      declared = Map.fetch!(code[module], {:spec, key})
      assert contract_signature(unit) == declared, "#{contract}'s contract isn't its @spec"
    end
  end

  @tag verifies: ["scanner-callback-contracts", "scanner-api-contracts"]
  test "§23.1.1's contracts are exactly Surfex.Scanner's callbacks, each as the behaviour declares it" do
    units = contract_units("scanner-api-contracts")

    callbacks =
      for {name, arity} <- Surfex.Scanner.behaviour_info(:callbacks), do: "#{name}/#{arity}"

    assert contract_drift(
             Enum.sort(callbacks),
             Enum.sort(contract_names(units, "Surfex.Scanner"))
           ) ==
             {[], []}

    assert Enum.sort(for u <- units, do: u.id) == [
             "spec.md#Surfex.Scanner.callback:calls/3",
             "spec.md#Surfex.Scanner.callback:items/2"
           ]

    declared = contract_declarations("lib/surfex/scanner.ex")

    for %{contract: "Surfex.Scanner." <> key} = unit <- units do
      assert contract_signature(unit) == Map.fetch!(declared, {:callback, key})
    end
  end
end
