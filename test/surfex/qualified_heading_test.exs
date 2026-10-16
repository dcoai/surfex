defmodule Surfex.QualifiedHeadingTest do
  # #312 (for #287): a heading naming a qualified function names its module for that
  # function's signature, and a nearer heading the code says holds the function is never
  # silently passed over for an outer one (§11.14).
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown
  alias Surfex.Status.Config

  @moduletag :tmp_dir

  defp qh_ids(text, opts \\ []) do
    for %{role: :contract, id: id} <- Markdown.sections(text, "spec.md", opts), do: id
  end

  defp qh_code(defined) do
    fn written ->
      Enum.find_value(defined, fn {module, names} ->
        if Enum.any?(
             names,
             &(written in ["#{module}.#{&1}", "#{module}.#{String.replace(&1, ~r/\/\d+$/, "")}"])
           ),
           do: module
      end)
    end
  end

  @tag verifies: ["qualified-heading-module", "qualified-heading"]
  test "a heading's M.f/a names M for f/a, M.f for every arity, and nothing for another function" do
    text = """
    # `A`

    ### `A.B.emit/3`

    ```elixir contract
    @spec emit(t, event, meta) :: :ok
    @spec other(t) :: t
    ```

    ### The `A.C.close` function

    ```elixir contract
    @spec close(t) :: :ok
    @spec close(t, timeout) :: :ok
    ```
    """

    assert qh_ids(text) == [
             "spec.md#A.B.emit/3",
             "spec.md#A.other/1",
             "spec.md#A.C.close/1",
             "spec.md#A.C.close/2"
           ]
  end

  @tag verifies: ["qualified-heading-conflict", "qualified-heading"]
  test "a nearer heading's module the code says has the function, passed over for an outer one, is a scan error naming both lines" do
    text = """
    # `A`

    ### `A.B.other/1` and its kin

    ```elixir contract
    @spec emit(t, event, meta) :: :ok
    ```
    """

    only_nearer = qh_code([{"A.B", ["emit/3", "other/1"]}])
    {_scans, errors} = Markdown.read(text, "spec.md", code: only_nearer)

    assert [%{line: 6, message: message}] = errors

    assert message ==
             "the contract signature `emit/3` would be keyed `A.emit/3` from the heading at line 1, " <>
               "but only `A.B`, which the nearer heading at line 3 names, has `emit/3`: " <>
               "mark the fence module: (§11.14)"

    # Where the outer module has it too, or the code isn't known, the outer module keys it.
    both = qh_code([{"A.B", ["emit/3"]}, {"A", ["emit/3"]}])
    assert {[_ | _], []} = Markdown.read(text, "spec.md", code: both)
    assert "spec.md#A.emit/3" in qh_ids(text)

    # A marker's module: says which, and is never second-guessed.
    marked =
      String.replace(
        text,
        "```elixir contract",
        "<!-- surfex: contract module: A.B -->\n```elixir"
      )

    assert {scans, []} = Markdown.read(marked, "spec.md", code: only_nearer)
    assert "spec.md#A.B.emit/3" in for(%{role: :contract, id: id} <- scans, do: id)
  end

  @tag verifies: ["qualified-heading-module", "qualified-heading-conflict", "qualified-heading"]
  test "through the config, a heading's short module resolves as a citation does, and a conflict fails the read",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "lib/a.ex"), """
    defmodule MyApp.Engine.Telemetry do
      @moduledoc "Telemetry."
      @doc "Emits."
      def emit(t, event, meta), do: {t, event, meta}
    end
    """)

    File.write!(Path.join(root, "spec.md"), """
    # `MyApp.Engine`

    ### `Telemetry.emit/3`

    ```elixir contract
    @spec emit(t, event, meta) :: :ok
    ```
    """)

    config = [
      sources: ["spec.md"],
      namespace: "MyApp",
      normalise: [{~r/^Telemetry\./, "MyApp.Engine.Telemetry."}]
    ]

    assert ["spec.md#MyApp.Engine.Telemetry.emit/3"] =
             for(%{role: :contract, id: id} <- Config.scans(config, root), do: id)

    File.write!(Path.join(root, "spec.md"), """
    # `MyApp.Engine`

    ### `MyApp.Engine.Telemetry.flush/0` and emitting

    ```elixir contract
    @spec emit(t, event, meta) :: :ok
    ```
    """)

    assert {:error, [%{file: "spec.md", line: 6, message: message}]} =
             Config.read([sources: ["spec.md"], namespace: "MyApp"], root, nil)

    assert message =~ "would be keyed `MyApp.Engine.emit/3` from the heading at line 1"
    assert message =~ "only `MyApp.Engine.Telemetry`, which the nearer heading at line 3 names"
  end
end
