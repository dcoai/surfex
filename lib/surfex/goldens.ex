defmodule Surfex.Goldens do
  @moduledoc """
  Every golden a project gates, run together: what `mix surfex.goldens` and
  `mix surfex.trace` do, without Mix.

  The list comes from `.surfex.exs`'s `goldens:` key. Each entry is:

    * `:trace` — the spec↔code trace defined by the rest of the file (`Surfex.Trace`)
    * `{output, module, opts}` — a project golden: `module` implements `Surfex.Surface`,
      and its `c:Surfex.Surface.spec/1` is rendered to `output`

  With no `goldens:` key the list is `[:trace]`.
  """

  alias Surfex.{Gate, Golden, Trace}

  @type entry :: :trace | {String.t(), module, keyword}

  @doc "The validated entries of a `.surfex.exs` config. Raises naming a bad entry."
  @spec entries!(keyword) :: [entry]
  def entries!(config) do
    entries = Keyword.get(config, :goldens, [:trace])

    unless is_list(entries) and entries != [],
      do: raise(ArgumentError, "goldens must be a non-empty list, got #{inspect(entries)}")

    for entry <- entries, not valid?(entry) do
      raise ArgumentError,
            "goldens entry #{inspect(entry)} is neither :trace nor {output, module, opts}"
    end

    outputs = Enum.map(entries, &output(&1, config))

    case outputs -- Enum.uniq(outputs) do
      [] -> entries
      dups -> raise ArgumentError, "two goldens write #{inspect(Enum.uniq(dups))}"
    end
  end

  defp valid?(:trace), do: true
  defp valid?({out, mod, opts}), do: is_binary(out) and is_atom(mod) and Keyword.keyword?(opts)
  defp valid?(_), do: false

  defp output(:trace, config), do: Keyword.get(config, :output, "SPEC_TRACE.md")
  defp output({out, _mod, _opts}, _config), do: out

  @doc """
  Whether running `entries` needs the project compiled: a project golden's module is
  project code, and so is a trace scanner other than the built-in one. The built-in
  Elixir scanner reads source and needs nothing compiled.
  """
  @spec needs_compile?([entry], keyword) :: boolean
  def needs_compile?(entries, config) do
    Enum.any?(entries, fn
      :trace -> Keyword.get(config, :scanner, :elixir) != :elixir
      {_output, _module, _opts} -> true
    end)
  end

  @doc """
  Renders every entry under `root` and writes (`write?`) or checks each against its
  file. Returns every failure, one message each, in entry order: each drift, and the
  trace's own failures (`Surfex.Trace.failures/2`). `defaults` fill trace keys the config
  does not set (the namespace); `command` is what regenerates the goldens.
  """
  @spec run([entry], keyword, String.t(), keyword, String.t(), boolean) :: [String.t()]
  def run(entries, config, root, defaults, command, write?) do
    Enum.flat_map(entries, &run_one(&1, config, root, defaults, command, write?))
  end

  defp run_one(:trace, config, root, defaults, command, write?) do
    trace = Trace.new!(Keyword.merge(defaults, Keyword.delete(config, :goldens)))
    analysis = Trace.analyse(trace, Trace.items(trace, root), root)
    golden = Trace.render(trace, analysis)

    Gate.run(Path.join(root, trace.output), golden, command, write?) ++
      Trace.failures(trace, analysis)
  end

  defp run_one({output, module, opts}, _config, root, _defaults, command, write?) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :spec, 1),
      do: raise(ArgumentError, "#{inspect(module)} does not implement Surfex.Surface")

    Gate.run(Path.join(root, output), Golden.render(module.spec(opts)), command, write?)
  end
end
