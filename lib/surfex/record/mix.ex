defmodule Surfex.Record.Mix do
  @moduledoc false
  # What the recording tasks share: read `.surfex.exs`, scan, load the log, fill in who and
  # when from git, append what `Surfex.Record` returns, and say what was recorded.

  alias Surfex.{Gate, Log}
  alias Surfex.Log.Entry
  alias Surfex.Status.Config

  @switches [type: :string, note: :string, pick: :string, config: :string]

  def parse(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    {opts, positional}
  end

  # {scans, entries, meta} for the project in the working directory.
  def context(opts) do
    root = File.cwd!()
    config = Gate.config!(Path.join(root, opts[:config] || ".surfex.exs"))
    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    unless File.dir?(Log.dir(root)),
      do: Mix.raise("no relation log in #{Log.dir(root)}: run `mix surfex.log --init`")

    meta =
      [by: author(root), commit: head(root)] ++ if(opts[:note], do: [note: opts[:note]], else: [])

    {root, Config.scans(config, root), Log.load(root), meta}
  end

  def type!(opts) do
    case opts[:type] do
      nil ->
        Mix.raise("--type is required: one of #{Enum.join(Entry.types(), ", ")}")

      text ->
        Enum.find(Entry.types(), &(Atom.to_string(&1) == text)) ||
          Mix.raise("--type must be one of #{Enum.join(Entry.types(), ", ")}, got #{text}")
    end
  end

  def two!([from, to]), do: {from, to}
  def two!(_), do: Mix.raise("give two ids: FROM TO")

  # Appends what a Surfex.Record function returned, or stops with its reason.
  def record(root, {:ok, entries}) do
    Log.append(root, entries)
    Enum.each(entries, &Mix.shell().info("recorded #{describe(&1)}"))
  end

  def record(_root, {:error, why}), do: Mix.raise(why)

  def describe(%Entry{} = e) do
    [a, b] = e.ends
    arrow = if e.type in Entry.directed(), do: "→", else: "↔"
    note = if e.note, do: " — #{e.note}", else: ""

    "#{e.op} #{e.type}  #{a.kind} #{a.id}@#{a.hash} #{arrow} #{b.kind} #{b.id}@#{b.hash}  [#{String.slice(e.id, 0, 12)}]#{note}"
  end

  # Who: git's user, when there is one. Where: HEAD, when there is one. Both are context;
  # a project without git still records, with them empty.
  defp author(root) do
    with name when is_binary(name) <- git(root, ["config", "user.name"]),
         email when is_binary(email) <- git(root, ["config", "user.email"]) do
      "#{name} <#{email}>"
    else
      _ -> git(root, ["config", "user.name"])
    end
  end

  defp head(root), do: git(root, ["rev-parse", "HEAD"])

  defp git(root, args) do
    if System.find_executable("git") do
      case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    end
  end
end
