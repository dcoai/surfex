# Configuration: .surfex.exs

A keyword list, evaluated as data. An unknown key is refused, naming it.

**What is scanned**
- `sources: ["spec.md"]`: the spec files (required).
- `tests: ["test/**/*_test.exs"]`: test files, scanned per test case. Add
  `Surfex.ExUnitFormatter` to `ExUnit.start(formatters: [...])` to record evidence.
- `namespace:`: the code's namespace (defaults to the app name).
- `scanner:`, `scanner_opts:`: a project scanner (`Surfex.Scanner`) instead of the Elixir one.
- Citation profile: `exclude`, `shape`, `token`, `known_shape`, `normalise`, `subjects`,
  `table_columns`, `file_targets`, `known_external`, `documented_absences`.
- `classes: [{name, reason}]`, `rules: [%{class:, kinds:, name:, parent_cited:, parent:}]`,
  `never_excused:`: kinds of code the spec deliberately doesn't describe.

**Policy**
- `require: [code: [:implements], test_hint: [:verifies]]`: what must take part in a
  relation of those types (keys: a kind, or a spec role `section`, `block`, `test_hint`).
- `triangle: :report | :fail`: whether a unit, its tests and its code must meet.
- `require_red:`: whether a `tests` relation needs its test's red run.
- `adoption: :reevaluate | :trust | [trust: globs, reevaluate: globs]` (`mix surfex.info adoption`).
- `completeness: [min: N]`: fail status below N percent.

**Outputs**
- `goldens: [:status, :completeness]`: `RELATIONS.md`, `COMPLETENESS.md`.
- `process: :print | {:command, argv}`: where `mix surfex.draft --file` sends drafts.

The check's own options (`--validated`, `--no-marks`, `--no-baseline`, …) are on the
command line: `mix surfex.info status`.
