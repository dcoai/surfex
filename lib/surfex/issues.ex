defmodule Surfex.Issues do
  @moduledoc """
  The state of the issues a spec's deferrals name (§13.7), asked of the project's own
  tracker through the command `.surfex.exs` declares (`issues:`). Surfex knows no tracker
  (§19): the command is the project's, run with no shell, once per distinct reference,
  and only when a caller asks (`mix surfex.status --issues`). Nothing is stored: an
  issue's state is for the run that asked, as evidence is.

  A state is `:open` (`open` or `opened`, in any case), `:closed` (`closed`), or
  `:unresolved` (anything else): a reference the tracker can't answer can never go
  stale, which the status reports under `--issues`.
  """

  @type state :: :open | :closed | :unresolved
  @type resolver :: %{command: [String.t()], state: String.t() | nil, project: String.t() | nil}

  @doc """
  Each reference in `refs` => its state, by running the resolver's command once per
  distinct reference in `root`. In each argument `{ref}` is the reference as written,
  `{n}` its number and `{project}` its project (`group/project` before the `#`), else the
  resolver's `project`, else empty. With `state` the output is JSON and that key holds
  the state; without it the trimmed output is the state. The first command to exit
  non-zero stops the asking: `{:error, {ref, output}}`, so a tooling failure is loud and
  never read as a state.
  """
  @spec states(resolver, [String.t()], String.t()) ::
          {:ok, %{String.t() => state}} | {:error, {String.t(), String.t()}}
  def states(%{command: [command | args]} = resolver, refs, root) do
    refs
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn ref, {:ok, acc} ->
      argv = Enum.map(args, &substitute(&1, ref, resolver))

      case System.cmd(command, argv, cd: root, stderr_to_stdout: true) do
        {output, 0} -> {:cont, {:ok, Map.put(acc, ref, read(output, resolver.state))}}
        {output, n} -> {:halt, {:error, {ref, "#{command} exited with #{n}:\n#{output}"}}}
      end
    end)
  end

  @doc "The state a tracker's answer names: `open`/`opened` open, `closed` closed."
  @spec state(String.t() | term) :: state
  def state(text) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      open when open in ["open", "opened"] -> :open
      "closed" -> :closed
      _ -> :unresolved
    end
  end

  def state(_other), do: :unresolved

  defp read(output, nil), do: state(output)

  defp read(output, key) do
    case JSON.decode(output) do
      {:ok, %{} = json} -> state(Map.get(json, key))
      _ -> :unresolved
    end
  end

  defp substitute(arg, ref, resolver) do
    [project, n] =
      case String.split(ref, "#", parts: 2) do
        ["", n] -> [resolver.project || "", n]
        [project, n] -> [project, n]
      end

    arg
    |> String.replace("{ref}", ref)
    |> String.replace("{n}", n)
    |> String.replace("{project}", project)
  end
end
