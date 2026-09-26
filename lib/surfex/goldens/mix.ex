defmodule Surfex.Goldens.Mix do
  @moduledoc false
  # What `mix surfex.goldens` and `mix surfex.trace` share: options, config, namespace,
  # compile-if-needed, and the one report of every failure.

  alias Surfex.{Gate, Goldens}

  def run(args, which, command) do
    {opts, _rest} = OptionParser.parse!(args, strict: [write: :boolean, config: :string])
    root = File.cwd!()
    config = Gate.config!(Path.join(root, opts[:config] || ".surfex.exs"))
    entries = if which == :all, do: Goldens.entries!(config), else: [:trace]
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()

    if Goldens.needs_compile?(entries, config), do: Mix.Task.run("compile")

    case Goldens.run(entries, config, root, [namespace: namespace], command, opts[:write]) do
      [] ->
        verb = if opts[:write], do: "wrote", else: "checked"
        Mix.shell().info("#{verb} #{length(entries)} golden(s): all current, nothing failing")

      failures ->
        Mix.raise(Enum.join(failures, "\n"))
    end
  end
end
