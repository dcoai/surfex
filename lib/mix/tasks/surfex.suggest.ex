defmodule Mix.Tasks.Surfex.Suggest do
  @shortdoc "Suggest relations from what the spec already says (--accept to record them)"

  @moduledoc """
  Lists what the spec already implies (`Surfex.Suggest.all/5`):

    * **moves** — a related spec id that is gone, and a new id at the same version: a
      renamed heading, or an anchor added. Accepting moves each relation onto the new id
      (`mix surfex.move`).
    * **refines** — each marked block and test hint refines the section or block it sits
      in.
    * **implements** — each spec unit paired with each code item it names.
    * **verifies** — each test paired with the spec unit its `@tag verifies:` names.
    * **tests** — each test paired with each code item it calls.
    * **excuses** — each code item nothing implements, paired with the class of the first
      rule in `.surfex.exs` it matches.

  Pairs already related, in any state, are left out.

      mix surfex.suggest                         # list them; nothing is written
      mix surfex.suggest --accept                # record them
      mix surfex.suggest --accept --note "adopted the relation log"

  `--accept` only creates relations that don't exist, and carries judgements across
  moves. It never confirms a dangling relation: that stays `mix surfex.confirm`, one named
  id at a time.

  Adopting the relation log is `mix surfex.log --init`, then this with `--accept`.
  """

  use Mix.Task

  alias Surfex.{Log, Suggest}
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [accept: :boolean, note: :string, config: :string])

    root = File.cwd!()
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))
    namespace = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    profile = Config.profile!(config, namespace)
    if Keyword.get(config, :scanner, :elixir) != :elixir, do: Mix.Task.run("compile")

    scans = Config.scans(config, root)
    entries = if File.dir?(Log.dir(root)), do: Log.load(root), else: []
    suggestions = Suggest.all(profile, Config.items(config, root), scans, entries, root)

    for m <- suggestions.moves, do: Mix.shell().info("move        #{m.from} → #{m.to.id}")
    for r <- suggestions.refines, do: Mix.shell().info("refines     #{r.from.id} → #{r.to.id}")

    for v <- suggestions.verifies, do: Mix.shell().info("verifies    #{v.from.id} → #{v.to.id}")
    for t <- suggestions.tests, do: Mix.shell().info("tests       #{t.from.id} → #{t.to.id}")
    for x <- suggestions.excuses, do: Mix.shell().info("excuses     #{x.from.id} ↔ #{x.to.id}")

    for c <- suggestions.implements do
      {file, line} = c.cited_at
      Mix.shell().info("implements  #{c.spec.id} ↔ #{c.code.id}  (cited at #{file}:#{line})")
    end

    count = suggestions |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    cond do
      count == 0 ->
        Mix.shell().info("nothing to suggest: everything the spec implies is already related")

      opts[:accept] ->
        {^root, scans, entries, meta} = R.context(Keyword.take(opts, [:note, :config]))
        R.record(root, Suggest.accept_all(suggestions, scans, entries, meta))

      true ->
        Mix.shell().info("#{count} suggested; `mix surfex.suggest --accept` records them")
    end
  end
end
