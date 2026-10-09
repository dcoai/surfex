defmodule Surfex.InfoTest do
  use ExUnit.Case, async: true
  @moduletag verifies: "info-directory"

  alias Surfex.Info

  test "the directory is under 100 lines and lists every topic and every command" do
    directory = Info.directory()
    assert length(String.split(directory, "\n", trim: true)) < 100

    for {topic, summary} <- Info.topics() do
      assert directory =~ "#{topic}", "the directory doesn't list #{topic}"
      assert directory =~ summary
    end

    {:ok, modules} = :application.get_key(:surfex, :modules)

    for module <- modules,
        task = Mix.Task.task_name(module),
        String.starts_with?(task, "surfex."),
        Mix.Task.task?(module) do
      assert directory =~ "mix #{task} ", "the directory doesn't list mix #{task}"
    end
  end

  # #117, #126: the pages live with the code; the package's usage rules are one short page
  # (the agent topic) that points to them, so a project's AGENTS.md stays small and current.
  @tag verifies: "usage-rules-shipped"
  test "usage-rules.md is the short agent page pointing to mix surfex.info; the rest stay in priv/info" do
    root = Path.expand("../..", __DIR__)
    rules = File.read!(Path.join(root, "usage-rules.md"))

    assert {:ok, rules} == Info.page("agent")
    assert rules =~ "mix surfex.info"

    assert length(String.split(rules, "\n", trim: true)) < 40,
           "usage-rules.md is meant to be short"

    refute File.exists?(Path.join(root, "usage-rules")), "no sub-rules for usage_rules to copy"

    assert Info.directory() == File.read!(Path.join(root, "priv/info/index.md"))

    topics = for {topic, _} <- Info.topics(), do: topic

    files =
      for f <- Path.wildcard(Path.join(root, "priv/info/*.md")),
          name = Path.basename(f, ".md"),
          name != "index",
          do: name

    assert Enum.sort(topics) == Enum.sort(["agent" | files]),
           "every page is a listed topic, and every topic a page"

    for topic <- topics -- ["agent"] do
      assert {:ok, File.read!(Path.join(root, "priv/info/#{topic}.md"))} == Info.page(topic)
    end

    for topic <- topics, do: assert(Info.directory() =~ "- `mix surfex.info #{topic}`")

    config = Mix.Project.config()
    assert "usage-rules.md" in config[:package][:files]
    assert "priv" in config[:package][:files]
    refute "usage-rules" in config[:package][:files]

    extras =
      config[:docs][:extras]
      |> Enum.map(&if(is_tuple(&1), do: elem(&1, 0), else: &1))
      |> Enum.map(&to_string/1)

    assert "usage-rules.md" in extras
    assert "priv/info/index.md" in extras
    for topic <- topics -- ["agent"], do: assert("priv/info/#{topic}.md" in extras)

    # hexdocs present the mix tasks, the three modules users write code against, and the
    # two a project renders surface goldens with (#150).
    shown = &Regex.match?(config[:docs][:filter_modules], "Elixir." <> &1)

    for name <-
          ~w(Mix.Tasks.Surfex.Status Mix.Tasks.Surfex.Info Surfex.ExUnitFormatter Surfex.Scanner Surfex.Item Surfex.Golden Surfex.SourceScan),
        do: assert(shown.(name), "#{name} isn't on hexdocs")

    for name <- ~w(Surfex.Record Surfex.Status Surfex.Log.Entry),
        do: refute(shown.(name), "#{name} is on hexdocs")
  end

  test "each topic prints its page; an unknown topic is refused, naming the topics" do
    for {topic, _summary} <- Info.topics() do
      assert {:ok, page} = Info.page(topic)
      assert page =~ ~r/\A# /, "#{topic}'s page has no title"
      assert length(String.split(page, "\n")) > 5
    end

    assert {:error, message} = Info.page("nonsense")
    assert message =~ "no topic nonsense"
    assert message =~ "process"
  end

  # #150: a project that renders goldens with surfex but keeps no relation log hasn't
  # adopted it, and the directory says so (extc found this the expensive way).
  @tag verifies: "info-without-log"
  @tag :tmp_dir
  test "the directory notes when the project has no relation log", %{tmp_dir: root} do
    assert Info.adoption_note(root) =~ "no relation log"
    assert Info.adoption_note(root) =~ "mix surfex.log --init"

    File.mkdir_p!(Path.join(root, ".surfex"))
    assert Info.adoption_note(root) == nil
  end

  test "mix surfex.info prints the directory, or a topic's page" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Surfex.Info.run([])
    assert_received {:mix_shell, :info, [directory]}
    assert directory == Info.directory()

    Mix.Tasks.Surfex.Info.run(["process"])
    assert_received {:mix_shell, :info, [page]}
    assert {:ok, ^page} = Info.page("process")

    assert_raise Mix.Error, ~r/no topic nonsense/, fn ->
      Mix.Tasks.Surfex.Info.run(["nonsense"])
    end
  end
end
