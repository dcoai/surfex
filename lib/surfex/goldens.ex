defmodule Surfex.Goldens do
  @moduledoc """
  Every golden a project gates, run together: what `mix surfex.goldens` does, without Mix.

  The list comes from `.surfex.exs`'s `goldens:` key. Each entry is:

    * `:status` or `{:status, output}` — the relation status (`Surfex.Status`) as a golden,
      `RELATIONS.md` by default: the committed record of every relation's state
    * `{output, module, opts}` — a project golden: `module` implements `Surfex.Surface`,
      and its `c:Surfex.Surface.spec/1` is rendered to `output`

  With no `goldens:` key the list is `[:status]`. The v0.2 trace's `:trace` entry was
  removed in 0.4.0, and naming it raises with that reason.
  """

  alias Surfex.{Gate, Golden, Log, Status}
  alias Surfex.Status.{Config, Report}

  @type entry :: :status | {:status, String.t()} | {String.t(), module, keyword}

  @doc "The validated entries of a `.surfex.exs` config. Raises naming a bad entry."
  @spec entries!(keyword) :: [entry]
  def entries!(config) do
    entries = Keyword.get(config, :goldens, [:status])

    unless is_list(entries) and entries != [],
      do: raise(ArgumentError, "goldens must be a non-empty list, got #{inspect(entries)}")

    if :trace in entries,
      do:
        raise(
          ArgumentError,
          "goldens entry :trace was removed in 0.4.0 with the v0.2 trace: " <>
            "the relation log (:status) replaces it"
        )

    for entry <- entries, not valid?(entry) do
      raise ArgumentError,
            "goldens entry #{inspect(entry)} is not :status, {:status, output} or {output, module, opts}"
    end

    outputs = Enum.map(entries, &output/1)

    case outputs -- Enum.uniq(outputs) do
      [] -> entries
      dups -> raise ArgumentError, "two goldens write #{inspect(Enum.uniq(dups))}"
    end
  end

  defp valid?(:status), do: true
  defp valid?({:status, out}), do: is_binary(out)
  defp valid?({out, mod, opts}), do: is_binary(out) and is_atom(mod) and Keyword.keyword?(opts)
  defp valid?(_), do: false

  defp output(:status), do: "RELATIONS.md"
  defp output({:status, out}), do: out
  defp output({out, _mod, _opts}), do: out

  @doc """
  Whether running `entries` needs the project compiled: a project golden's module is
  project code, and so is a project scanner the status reads. The built-in Elixir scanner
  reads source and needs nothing compiled.
  """
  @spec needs_compile?([entry], keyword) :: boolean
  def needs_compile?(entries, config) do
    Enum.any?(entries, fn
      :status -> Keyword.get(config, :scanner, :elixir) != :elixir
      {:status, _output} -> Keyword.get(config, :scanner, :elixir) != :elixir
      {_output, _module, _opts} -> true
    end)
  end

  @doc """
  Renders every entry under `root` and writes (`write?`) or checks each against its
  file. Returns every failure, one message each, in entry order. `defaults` carries what
  the config may leave out (the namespace); `command` is what regenerates the goldens.
  """
  @spec run([entry], keyword, String.t(), keyword, String.t(), boolean) :: [String.t()]
  def run(entries, config, root, defaults, command, write?) do
    Enum.flat_map(entries, &run_one(&1, config, root, defaults, command, write?))
  end

  defp run_one(:status, config, root, defaults, command, write?),
    do: run_one({:status, "RELATIONS.md"}, config, root, defaults, command, write?)

  # The committed record of the relation status. Its drift is a failure here; whether the
  # relations are healthy is `mix surfex.status`'s question.
  defp run_one({:status, output}, config, root, defaults, command, write?) do
    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []
    {scans, options} = Config.load(config, root, defaults[:namespace])
    status = Status.derive(scans, entries, Config.require!(config), options)

    Gate.run(
      Path.join(root, output),
      Golden.render(Report.golden(status, output)),
      command,
      write?
    )
  end

  defp run_one({output, module, opts}, _config, root, _defaults, command, write?) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :spec, 1),
      do: raise(ArgumentError, "#{inspect(module)} does not implement Surfex.Surface")

    Gate.run(Path.join(root, output), Golden.render(module.spec(opts)), command, write?)
  end
end
