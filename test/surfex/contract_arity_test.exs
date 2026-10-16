defmodule Surfex.ContractArityTest do
  # #315 (for #287): a citation of Module.name/arity is checked against the spec's own
  # contracts, so a spec with no code still finds an arity no contract states (§13.15).
  use ExUnit.Case, async: true

  alias Surfex.Status
  alias Surfex.Status.{Config, Report, SpecShape}

  @moduletag :tmp_dir

  @spec_md """
  # 1. `MyApp.Env`

  ```elixir contract
  @spec check(t, keyword) :: :ok
  ```

  ## 1.1 Using it

  Call `MyApp.Env.check/1` first, then `MyApp.Env.check/2`, `MyApp.Env.check` and
  `MyApp.Env.probe/1`.
  """

  defp ca_write(root, path, text) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp ca_status(root, config) do
    {:ok, {scans, opts}} = Config.read(config, root, nil)
    Status.derive(scans, [], [], opts)
  end

  @tag verifies: ["contract-arity-warned", "contract-arity", "spec-shape"]
  test "a citation of an arity no contract states is warned on its unit, with no code, and never fails",
       %{tmp_dir: root} do
    ca_write(root, "spec.md", @spec_md)

    status =
      ca_status(root,
        sources: ["spec.md"],
        namespace: "MyApp",
        scanner_opts: [paths: ["lib/**/*.ex"]]
      )

    assert [warning] = SpecShape.warnings(status)

    assert warning == %{
             kind: :contract_arity,
             file: "spec.md",
             line: 9,
             unit: "spec.md#1. `MyApp.Env`/1.1 Using it",
             message:
               "`MyApp.Env.check/1` cites an arity no contract states; the contracts state MyApp.Env.check/2 at spec.md:4"
           }

    # Listed under Spec shape and in the JSON; the status fails only on its broken citations.
    assert Report.text(status) =~
             "Cited arities no contract states (the contracts state the function at others)"

    assert [%{"kind" => "contract_arity", "line" => 9}] =
             JSON.decode!(Report.json(status))["spec_warnings"]

    refute Status.failing?(%{status | citations: []})
  end

  @tag verifies: ["contract-arity-warned", "contract-arity"]
  test "the warning's unit is the innermost holding the line: the contract inside its section" do
    units = Surfex.Scan.Markdown.sections(@spec_md, "spec.md")

    assert Surfex.Scan.at(units, "spec.md", 9).id == "spec.md#1. `MyApp.Env`/1.1 Using it"
    assert Surfex.Scan.at(units, "spec.md", 4).id == "spec.md#MyApp.Env.check/2"
    assert Surfex.Scan.at(units, "spec.md", 2).id == "spec.md#1. `MyApp.Env`"
    assert Surfex.Scan.at(units, "other.md", 4) == nil
  end

  @tag verifies: ["contract-arity-warned", "contract-arity"]
  test "with the code defining the cited arity, nothing is warned", %{tmp_dir: root} do
    ca_write(root, "spec.md", @spec_md)

    ca_write(root, "lib/env.ex", """
    defmodule MyApp.Env do
      @moduledoc "Env."
      @doc "Checks."
      def check(t), do: t
      @doc "Checks."
      def check(t, opts), do: {t, opts}
    end
    """)

    status = ca_status(root, sources: ["spec.md"], namespace: "MyApp")
    assert SpecShape.warnings(status) == []
  end
end
