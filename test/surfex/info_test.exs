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
