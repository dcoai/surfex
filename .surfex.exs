# Surfex holds its own specification to its own code and tests with its own relation log
# (.surfex/): which spec units, functions and tests were confirmed to belong together, at
# which versions. `mix surfex.status` is the check:
#
#   * every public module and function implements some section (require:)
#   * every test hint in spec.md is verified by a test tagged `@tag verifies: "<hint id>"`
#   * every name spec.md cites exists
#
# Its tests are scanned (tests:), and the spec/test/code triangle is reported.
# `mix surfex.goldens` gates RELATIONS.md, the relation status as a committed record.
[
  goldens: [:status],
  require: [code: [:implements], test_hint: [:verifies]],
  tests: ["test/*_test.exs", "test/surfex/*_test.exs"],
  sources: ["spec.md"]
]
