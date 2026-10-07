# Surfex holds its own specification to its own code and tests with its own relation log
# (.surfex/): which spec units, functions and tests were confirmed to belong together, at
# which versions. `mix surfex.status` is the check:
#
#   * every public module and function implements some section, and every public type
#     does or is excused as a type (require:, classes:)
#   * every test hint in spec.md is verified by a test tagged `@tag verifies: "<hint id>"`
#   * every name spec.md cites exists
#   * the spec/test/code triangle is closed (triangle: :fail): every section something
#     implements is verified by a test, and that test exercises the implementing code
#
# `mix surfex.goldens` gates RELATIONS.md, the relation status as a committed record, and
# COMPLETENESS.md, the completeness report.
[
  goldens: [:status, :completeness],
  # Every spec unit, test and code item stays covered by validated relations (§20).
  completeness: [min: 100],
  # Code implements a section, or is excused by a class. The one class is types (#137), so
  # every module and function still implements one.
  require: [code: [:implements, :excuses], test_hint: [:verifies]],
  classes: [
    {"type",
     "a type is the shape of the data its functions take and return: it is described, " <>
       "tested and versioned with them, and a spec cites it where it matters"}
  ],
  rules: [%{class: "type", kinds: [:type]}],
  tests: ["test/*_test.exs", "test/surfex/*_test.exs"],
  triangle: :fail,
  sources: ["spec.md"],
  # Found work goes to this environment's proposal system (§19), only with
  # `mix surfex.draft --file`.
  process:
    {:command,
     ["glab", "issue", "create", "--label", "Proposal", "--title", "{title}", "--description", "{body}"]}
]
