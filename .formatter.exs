[
  # Not test/fixtures: those are captured data and another project's sources, kept as recorded.
  inputs: [
    "{mix,.formatter}.exs",
    "lib/**/*.{ex,exs}",
    "test/{surfex,support}/**/*.{ex,exs}",
    "test/*.exs"
  ],
  line_length: 98,
  # extla's specification DSL, for the model of the relation log (#128). extla exports no
  # formatter config, and it is a test-only dependency, so import_deps can't name it.
  locals_without_parens: [
    constant: 2,
    variable: 2,
    action: 3,
    invariant: 2,
    invariant: 3,
    terminal: 2,
    temporal: 2,
    fairness: 2,
    require: 1,
    let: 1,
    assert_spec: 2
  ]
]
