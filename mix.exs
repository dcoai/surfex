defmodule Surfex.MixProject do
  use Mix.Project

  @version "0.5.16"
  @source_url "https://github.com/dcoai/surfex"

  @moduledoc """
  Keep a document honest about code.

  A **surface golden** is generated from a source scan, lists what the code declares, and is
  gated so it cannot disagree with the code: CI regenerates it and byte-compares, and a
  difference fails the build.

  `deps: []`, stdlib only, and that is a policy rather than a coincidence — three projects
  take this as a dev/test dependency, and none of them should inherit a kernel with it.
  """

  def project do
    [
      app: :surfex,
      version: @version,
      elixir: "~> 1.15",
      # Fixture data and sources, not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: Mix.env() == :prod,
      # A true leaf at runtime. A runtime or test dependency is inherited by every project
      # that scans its own source, so the bar for one is: it cannot be done with the stdlib.
      # ex_doc builds the docs and is dev-only, so no consumer ever fetches it.
      deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}],
      name: "Surfex",
      description:
        "Keep a specification, its tests and its code aligned: a log of which versions were confirmed to belong together, checked from source without compiling it",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files:
          ~w(lib usage-rules.md usage-rules guides mix.exs README.md CHANGELOG.md spec.md LICENSE)
      ],
      source_url: @source_url,
      docs: [
        main: "readme",
        source_url: @source_url,
        source_ref: "v#{@version}",
        # Surfex is a mix tool: its docs lead with how to use it. The usage pages are the
        # ones `mix surfex.info` prints and usage_rules ships (usage-rules.md, usage-rules/).
        extras:
          ["README.md", {"usage-rules.md", title: "Using surfex"}] ++
            Path.wildcard("usage-rules/*.md") ++
            [
              "guides/writing-specs.md",
              "guides/adopting-an-existing-suite.md",
              "spec.md",
              "CHANGELOG.md"
            ],
        groups_for_extras: [
          "Using surfex": ["usage-rules.md" | Path.wildcard("usage-rules/*.md")],
          Guides: ~w(guides/writing-specs.md guides/adopting-an-existing-suite.md),
          Reference: ~w(spec.md CHANGELOG.md)
        ],
        # The mix tasks, and the three modules a project writes code against. Every other
        # module keeps its docs in the code (`h` in iex) without being the package's docs.
        filter_modules:
          ~r/^Elixir\.(Mix\.Tasks\.Surfex(\.|$)|Surfex\.(ExUnitFormatter|Scanner|Item)$)/,
        # Names of modules not on hexdocs render as code, not as links that go nowhere.
        skip_code_autolink_to: &skip_autolink?/1,
        # The changelog names functions earlier versions removed: history, not dead links.
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  @shown ~w(Surfex.ExUnitFormatter Surfex.Scanner Surfex.Item)

  # A reference's module is its capitalised segments: `Surfex.Item.key/1` is `Surfex.Item`.
  defp skip_autolink?(ref) do
    module = ref |> String.split(".") |> Enum.take_while(&(&1 =~ ~r/^[A-Z]/)) |> Enum.join(".")
    String.starts_with?(module, "Surfex") and module not in @shown
  end
end
