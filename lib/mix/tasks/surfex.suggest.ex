defmodule Mix.Tasks.Surfex.Suggest do
  @shortdoc "Suggest relations from the spec's citations of the code (--accept to record them)"

  @moduledoc """
  Lists candidate `implements` relations: each spec section paired with each code item it
  names (`Surfex.Suggest`). Pairs already related, in any state, are left out.

      mix surfex.suggest                         # list them; nothing is written
      mix surfex.suggest --accept                # record each as a relation
      mix surfex.suggest --accept --note "adopted the relation log"

  `--accept` only creates relations that don't exist. It never confirms a dangling one:
  that stays `mix surfex.confirm`, one named id at a time.

  Adopting the relation log is `mix surfex.log --init`, then this with `--accept`.
  """

  use Mix.Task

  alias Surfex.{Gate, Log, Suggest, Trace}
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [accept: :boolean, note: :string, config: :string])

    root = File.cwd!()
    config = Gate.config!(Path.join(root, opts[:config] || ".surfex.exs"))
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    trace = Trace.new!(Keyword.merge([namespace: namespace], Trace.own_keys(config)))
    if trace.scanner != :elixir, do: Mix.Task.run("compile")

    scans = Config.scans(config, root)
    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []
    candidates = Suggest.candidates(trace, Trace.items(trace, root), scans, entries, root)

    for c <- candidates do
      {file, line} = c.cited_at
      Mix.shell().info("implements  #{c.spec.id} ↔ #{c.code.id}  (cited at #{file}:#{line})")
    end

    cond do
      candidates == [] ->
        Mix.shell().info("nothing to suggest: every citation's pair is already related")

      opts[:accept] ->
        {^root, scans, entries, meta} = R.context(Keyword.take(opts, [:note, :config]))
        R.record(root, Suggest.accept(candidates, scans, entries, meta))

      true ->
        Mix.shell().info(
          "#{length(candidates)} suggested; `mix surfex.suggest --accept` records them"
        )
    end
  end
end
