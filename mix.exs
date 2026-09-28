defmodule Surfex.MixProject do
  use Mix.Project

  @version "0.4.0"
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
      # A true leaf. Anything added here is inherited by every project that scans its own
      # source, so the bar is: it cannot be done with the stdlib.
      deps: [],
      name: "Surfex",
      description:
        "Keep a specification, its tests and its code in step: a log of which versions were confirmed to belong together, checked from source without compiling it",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib guides mix.exs README.md CHANGELOG.md spec.md LICENSE)
      ],
      source_url: @source_url,
      docs: [
        main: "readme",
        source_url: @source_url,
        source_ref: "v#{@version}",
        extras: ["README.md", "guides/writing-specs.md", "spec.md", "CHANGELOG.md"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
