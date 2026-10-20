defmodule Surfex.ConfigKeysTest do
  # #288: every .surfex.exs key is validated before scanning, and a refusal names the key,
  # the value as written and the accepted form, every refusal at once.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Surfex.Check
  alias Surfex.Status.Config

  # For every key a .surfex.exs may hold, values of the wrong type: the whole value wrong,
  # and one element of it wrong. A key missing here fails the table test, so a new key
  # can't land without a validator.
  @wrong %{
    sources: [42, "spec.md", ["spec.md", :other]],
    exclude: [42, [:deps]],
    shape: [42, "^MyApp"],
    token: [42, "\\w+"],
    known_shape: [42, "[A-Z]+"],
    normalise: [42, [{"x", "y"}]],
    subjects: [42, [%{file: "a.md", heading: "Cart", items: ["Cart"]}]],
    table_columns: [42, [:field]],
    file_targets: [42, [:items]],
    known_external: [42, [{"Jason", "a dep"}]],
    documented_absences: [42, %{"Gone" => "removed"}],
    classes: [42, [{:helper, "r"}]],
    rules: [42, [%{class: "helper", kinds: []}], [%{class: "helper", kinds: [:fun], name: "x"}]],
    never_excused: [42, ["module"]],
    heading_ids: [42, :roman, [:section_sign, ~r/^R\d+/], []],
    rule_ids: [42, ~r/^P\d+/],
    unit_refs: [42, [~r/^§(?<id>\d+)$/], ["§"]],
    fold_paths: [42, "true"],
    scanner: [42, "MyScanner", :my_scanner],
    scanner_opts: [42, [:paths]],
    scanners: [42, [], [:elixir, "Mine"], [:elixir, :elixir]],
    namespace: [42, :my_app, [], "", [MyApp, 7]],
    goldens: [42, [], ["API.md"], [:trace], [:status, {"RELATIONS.md", Mod, []}]],
    require: [42, [cod: [:implements]], [code: [:likes]], [code: []]],
    tests: [42, "test/**/*_test.exs"],
    declares: [42, [verifies: []], [verifies: [{:tag, :verifies}]], [verifies: [{:tag, :v, :x}]]],
    triangle: [42, :maybe],
    require_red: [42, "yes"],
    router: [42, "MyAppWeb.Router", [], true],
    dispatch: [42, [{MyApp.Ops, :run}], [{MyApp.Ops, :run, -1}]],
    spec_classes: [42, [:x], [{"a b", "r"}], [{"x", ""}], [{"x", "r", file: []}]],
    issues: [42, [command: "gh"], [command: ["gh"], state: 1], [command: ["gh"], host: "x"]],
    not_claims: [42, ["^Legacy"]],
    checks: [
      42,
      [:x],
      [[id: "a", run: 42, verifies: "u"]],
      [[id: "a", run: [], verifies: "u"]],
      [[id: "a", run: "x", verifies: "u", input: []]],
      [[id: "a", run: "x", verifies: "u"], [id: "a", run: "y", verifies: "u"]]
    ],
    adoption: [42, :maybe, [trust: "test/*"], [keep: []]],
    process: [42, :command, {:command, []}, {:command, [:gh]}],
    completeness: [42, [min: 101], [min: "90"], [max: 1]]
  }

  defp refusal_written?(message, value) do
    inner =
      cond do
        is_list(value) -> value
        is_tuple(value) -> Tuple.to_list(value)
        true -> []
      end

    message =~ inspect(value) or Enum.any?(inner, &refusal_written?(message, &1))
  end

  defp refusal(config) do
    assert_raise ArgumentError, fn -> Config.validate!(config) end
  end

  describe "every key" do
    @describetag verifies: ["config-keys-refused", "config-keys"]

    test "every key a .surfex.exs may hold has a validator and a refusal in this table" do
      assert Enum.sort(Config.Keys.keys()) == Enum.sort(Config.keys())
      assert Enum.sort(Map.keys(@wrong)) == Enum.sort(Config.keys())
    end

    test "each refuses a wrong-typed value naming the key and the value as written" do
      for {key, values} <- @wrong, value <- values do
        error = refusal([{key, value}])

        assert error.message =~ "#{key}:",
               "#{key}: #{inspect(value)} gave #{inspect(error.message)}"

        # The value as written, or the entry that is wrong inside it.
        written? = refusal_written?(error.message, value)

        assert written? or error.message =~ "twice" or error.message =~ "different reasons" or
                 error.message =~ "write" or error.message =~ "removed",
               "#{key}: #{inspect(value)} gave #{inspect(error.message)}"
      end
    end

    test "a refusal names the accepted form, and quotes what was written, not a rewrite" do
      assert refusal(namespace: 42).message ==
               ~s{namespace: must be a string ("MyApp"), a module (MyApp), or a non-empty list of them, got 42}

      message = refusal(spec_classes: [{"a b", "r"}]).message
      assert message =~ "a class name must be a string or an atom of letters, digits, - and _"
      assert message =~ ~s|got "a b" in {"a b", "r"}|
      refute message =~ "[]}"

      assert refusal(spec_classes: [{"x", ""}]).message =~
               ~s|a class's reason must be a non-empty string, got "" in {"x", ""}|

      assert refusal(spec_classes: [{"x", "r", file: ["a"]}]).message =~
               "unknown option file: (expected files:, headings:, marker:)"
    end

    test "a valid value of every form is accepted" do
      for config <- [
            [namespace: "MyApp"],
            [namespace: MyApp],
            [namespace: [MyApp, "MyAppWeb"]],
            [spec_classes: [{:informative, "r"}, {"decision", "r", files: ["a.md"]}]],
            [checks: [[id: "a", run: ["mix", "a"], verifies: "u"]]],
            [checks: [[id: "b", run: "mix b && mix c", verifies: ["u"], inputs: ["x"]]]],
            [heading_ids: [:section_sign, ~r/^R(?<id>\d+)/]],
            [heading_ids: nil],
            [router: false],
            [scanners: [:elixir, {MyScanner, paths: ["x"]}]],
            [rules: [%{class: "h", kinds: [:fun]}], classes: [{"h", "r"}]]
          ] do
        assert Config.validate!(config) == config
      end
    end

    test "several refusals are raised together, one per line, with unknown keys", %{
      tmp_dir: root
    } do
      path = Path.join(root, ".surfex.exs")

      File.write!(path, """
      [sources: ["spec.md"], namespace: 42, triangle: :maybe, bogus: 1,
       spec_classes: [{:informative, ""}]]
      """)

      error = assert_raise ArgumentError, fn -> Config.read!(path) end
      [head | lines] = String.split(error.message, "\n")
      assert head == "#{path}: 4 refusals:"
      assert Enum.any?(lines, &(&1 =~ "unknown keys [:bogus]"))
      assert Enum.any?(lines, &(&1 =~ "namespace: must be"))

      assert Enum.any?(
               lines,
               &(&1 =~
                   "triangle: must be :report, :fail, [default: :report, fail: [glob, …]] or [default: :fail, report: [glob, …]], got :maybe")
             )

      assert Enum.any?(lines, &(&1 =~ "spec_classes: a class's reason"))
    end

    test "each key's own reader refuses in the same words" do
      for {read, config} <- [
            {&Config.require!/1, [require: [code: [:likes]]]},
            {&Config.checks!/1, [checks: [[id: "a", run: 42, verifies: "u"]]]},
            {&Config.namespace!/1, [namespace: 42]},
            {&Surfex.Goldens.entries!/1, [goldens: ["API.md"]]}
          ] do
        error = assert_raise ArgumentError, fn -> read.(config) end
        assert error.message == refusal(config).message
      end
    end

    test "nothing is scanned before the config is validated", %{tmp_dir: root} do
      # The root has no spec at all: a scan would fail on that, so the refusal comes first.
      config = [sources: ["spec.md"], tests: ["test/*_test.exs"], namespace: 42]

      for scan <- [
            fn -> Config.scans(config, root) end,
            fn -> Config.read(config, root, nil) end,
            fn -> Config.items(config, root) end
          ] do
        assert_raise ArgumentError, ~r/^namespace: must be/, scan
      end
    end
  end

  describe "name forms" do
    @describetag verifies: ["config-name-forms", "config-keys"]

    test "namespace: given a module reads as its name, and a list of roots as each" do
      assert Config.namespace!(namespace: Acme) == ["Acme"]
      assert Config.namespace!(namespace: "Acme") == ["Acme"]
      assert Config.namespace!(namespace: [Shop, "ShopWeb"]) == ["Shop", "ShopWeb"]
      assert Config.namespace!([]) == nil

      profile = Config.profile!([sources: ["spec.md"], namespace: Acme], nil)
      assert Regex.match?(profile.shape, "Acme.Parser.parse/1")

      both = Config.profile!([sources: ["spec.md"], namespace: [Shop, ShopWeb]], nil)
      assert Regex.match?(both.shape, "ShopWeb.Router")
      assert Regex.match?(both.shape, "Shop.Cart")
    end

    test "a spec_classes: atom name names the class its string does" do
      config = [spec_classes: [{:informative, "r"}]]
      assert Config.validate!(config) == config
      assert [%{name: "informative", reason: "r"}] = Config.spec_classes!(config, ["spec.md"])

      # One name, written once as an atom and once as a string, with two reasons.
      assert_raise ArgumentError, ~r/informative is declared with different reasons/, fn ->
        Config.spec_classes!([spec_classes: [{:informative, "r"}, {"informative", "s"}]], [])
      end
    end
  end

  describe "a check's run:" do
    @describetag verifies: ["check-run-argv", "checks"]

    test "an argv runs with no shell, each element one argument; a string runs through sh -c",
         %{tmp_dir: root} do
      # With a shell, `test a b = a b` splits into five words and fails; as an argv the
      # program gets three arguments.
      assert Check.shell(["test", "a b", "=", "a b"], root) == 0
      assert Check.shell("test 'a b' = 'a b'", root) == 0
      ExUnit.CaptureIO.capture_io(fn -> assert Check.shell("test a b = a b", root) != 0 end)
      assert Check.display(["mix", "a"]) == "mix a"
    end

    test "Config.checks!/1 keeps the argv, and its record carries it", %{tmp_dir: root} do
      File.write!(Path.join(root, "rules.txt"), "x")
      config = [checks: [[id: "a", run: ["mix", "a"], verifies: "u", inputs: ["rules.txt"]]]]

      assert [%{id: "a", run: ["mix", "a"], verifies: ["u"], inputs: ["rules.txt"]}] =
               checks = Config.checks!(config)

      [record] = Surfex.Scan.Checks.records(checks, root)
      assert record.check.run == ["mix", "a"]

      ran = fn command, _root ->
        send(self(), {:ran, command})
        0
      end

      [evidence] = Check.run([record], root, ran)
      assert evidence.result == :passed
      assert_received {:ran, ["mix", "a"]}

      assert_raise ArgumentError,
                   ~r/run: must be a command, a string run through sh -c or an argv/,
                   fn ->
                     Config.checks!(checks: [[id: "a", run: 42, verifies: "u"]])
                   end
    end
  end
end
