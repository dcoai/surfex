defmodule Surfex.LogTaskTest do
  # The task reads the working directory, which is global.
  use ExUnit.Case, async: false
  @moduletag verifies: "log-append-only"
  @moduletag :tmp_dir

  alias Surfex.Log

  defp task(root, args) do
    File.cd!(root, fn ->
      Mix.shell(Mix.Shell.Process)
      Mix.Tasks.Surfex.Log.run(args)
    end)
  after
    Mix.shell(Mix.Shell.IO)
  end

  test "mix surfex.log takes exactly one of --init, --break, --verify, --rechain", %{
    tmp_dir: root
  } do
    for args <- [[], ["--init", "--verify"]] do
      assert_raise Mix.Error, ~r/exactly one of --init, --break, --verify, --rechain/, fn ->
        task(root, args)
      end
    end

    task(root, ["--init"])
    assert_received {:mix_shell, :info, ["relation log ready in " <> _]}
    task(root, ["--break"])
    assert File.exists?(Path.join(Log.dir(root), "surfex_1.log"))
    task(root, ["--rechain"])
    task(root, ["--verify"])
    assert_received {:mix_shell, :info, ["relation log verified: 0 entries"]}
  end
end
