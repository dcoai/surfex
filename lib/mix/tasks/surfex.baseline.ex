defmodule Mix.Tasks.Surfex.Baseline do
  @shortdoc "Adopt an existing suite once: take the baseline under adoption: :trust"

  @moduledoc """
  Takes the one-shot baseline (`Surfex.Record.baseline/4`, §18.1): every test version the
  project's `adoption:` trusts counts as if it had discriminated, and its `verifies:` tags
  become `verifies` relations with basis `baseline`.

      mix test
      mix surfex.baseline --note "written test-first, reviewed in every MR"

  It refuses under `adoption: :reevaluate` (the default), a second time, without `tests:`,
  and before every trusted test has run green at its current version. Baselined relations
  stay counted (`mix surfex.status` shows them, `--no-baseline` fails on them), and each
  moves to `evidence` the first time its test goes red then green.
  """

  use Mix.Task

  alias Surfex.Evidence
  alias Surfex.Record.Mix, as: R
  alias Surfex.Status.Config

  @impl Mix.Task
  def run(args) do
    {opts, _ids} = R.parse(args, no_tags: :boolean)
    {root, scans, entries, meta} = R.context(opts)
    config = Config.read!(Path.join(root, opts[:config] || ".surfex.exs"))

    meta =
      meta
      |> Keyword.put(:adoption, Config.adoption!(config, root))
      |> Keyword.put(:no_tags, opts[:no_tags] == true)

    evidence = Evidence.load(Evidence.path(root))
    result = Surfex.Record.baseline(scans, entries, evidence, meta)
    R.record(root, result)

    {:ok, recorded} = result
    s = Surfex.Record.baseline_summary(scans, recorded)

    Mix.shell().info(
      "baseline: #{s.trusted} trusted test version#{plural(s.trusted)}, #{s.verifies} verifies " <>
        "adopted, #{s.units_without} spec unit#{plural(s.units_without)} without one"
    )
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
