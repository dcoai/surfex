defmodule Surfex.ContractModulesTest do
  # §11.9: which module a contract signature is about, and how a callback keys apart (#270).
  use ExUnit.Case, async: true

  alias Surfex.Scan.Markdown

  # The section's own prose says what its hint does, so each test verifies both.
  @moduletag verifies: ["contract-modules", "contract-module-resolution"]

  defp contracts(text, opts \\ []) do
    for u <- Markdown.sections(text, "spec.md", opts), u.role == :contract do
      {String.replace_prefix(u.id, "spec.md#", ""), u.contract}
    end
  end

  defp raises(text, opts \\ []) do
    assert_raise ArgumentError, fn -> Markdown.sections(text, "spec.md", opts) end
  end

  test "a defmodule around a signature in the fence names its module, nested ones joining" do
    text = """
    # Sanitizing

    <!-- surfex: contract module: Outer -->
    ```elixir
    defmodule App.Sanitizer do
      @callback sanitize(term, keyword) :: term

      defmodule Rules do
        @spec load(Path.t()) :: [term]
      end

      @spec rules() :: [term]
    end

    @spec after_it() :: :ok
    ```
    """

    assert contracts(text) == [
             {"App.Sanitizer.callback:sanitize/2", "App.Sanitizer.sanitize/2"},
             {"App.Sanitizer.Rules.load/1", "App.Sanitizer.Rules.load/1"},
             {"App.Sanitizer.rules/0", "App.Sanitizer.rules/0"},
             {"Outer.after_it/0", "Outer.after_it/0"}
           ]
  end

  test "a signature takes the nearest heading naming a module, climbing past those naming none" do
    text = """
    ## 1. `ExT` — the facade

    ### 1.3 Input

    ```elixir contract
    @spec send_key(id, ExT.Key.t()) :: :ok
    ```

    ## 2. `ExT.Vt` — the functional core

    ```elixir contract
    @spec send_key(t, ExT.Key.t()) :: {t, iodata}
    ```
    """

    assert contracts(text) == [
             {"ExT.send_key/2", "ExT.send_key/2"},
             {"ExT.Vt.send_key/2", "ExT.Vt.send_key/2"}
           ]
  end

  test "a subject beats a heading's backticks, and the marker's module: beats the heading" do
    subjects = [%{file: "spec.md", heading: ~r/^Feeds/, items: ["MyApp.Feed"]}]

    text = """
    # Feeds, after `Other`

    ```elixir contract
    @spec feed(t) :: t
    ```

    <!-- surfex: contract module: MyApp.Pump -->
    ```elixir
    @spec pump(t) :: t
    ```
    """

    assert contracts(text, subjects: subjects) == [
             {"MyApp.Feed.feed/1", "MyApp.Feed.feed/1"},
             {"MyApp.Pump.pump/1", "MyApp.Pump.pump/1"}
           ]

    assert [{"Other.feed/1", _}, _] = contracts(text)
  end

  test "a callback and a spec of one name and arity are two units" do
    text = """
    # Handlers

    ```elixir contract
    defmodule App.Handler do
      @callback content_schema() :: map
      @spec content_schema() :: map
      @macrocallback content_schema() :: Macro.t()
    end
    ```
    """

    assert contracts(text) == [
             {"App.Handler.callback:content_schema/0", "App.Handler.content_schema/0"},
             {"App.Handler.content_schema/0", "App.Handler.content_schema/0"},
             {"App.Handler.macrocallback:content_schema/0", "App.Handler.content_schema/0"}
           ]
  end

  test "one function stated in two fences of one file stays an error naming both lines" do
    text = """
    # `App.Controller`

    ```elixir contract
    @spec start_link(keyword) :: GenServer.on_start()
    ```

    ## Starting

    ```elixir contract
    @spec start_link(term) :: GenServer.on_start()
    ```
    """

    error = raises(text)
    assert error.message =~ "spec.md:10: spec.md#App.Controller.start_link/1"
    assert error.message =~ "already the id of line 4"
  end

  test "a signature no module places, or whose heading names several, is an error naming its line" do
    assert raises("# Api\n\n```elixir contract\n@spec f(t) :: t\n```\n").message =~
             "spec.md:4: the contract signature names no module"

    several = "# `A` and `B`\n\n```elixir contract\n@spec A.g(t) :: t\n@spec f(t) :: t\n```\n"

    assert raises(several).message =~
             "spec.md:5: the contract signature names no module, and its heading names several, A, B"

    assert contracts(String.replace(several, "@spec f(t) :: t\n", "")) == [{"A.g/1", "A.g/1"}]
  end
end
