# Configuration: .surfex.exs

A keyword list, evaluated as data. An unknown key is refused, naming it.

**What is scanned**
- `sources: ["spec.md"]`: the spec files (required).
- `heading_ids:`, `rule_ids:`: the ids authors write into headings and into a marked list's
  items: `:section_sign` (`§ID`), `:section_number` (`1.2`), a regex with `(?<id>…)`, or a
  list of them (`mix surfex.info claims`).
- `fold_paths: true`: a heading with no id inside one that has an id is part of that unit,
  not a unit of its own (off by default until 0.8; `mix surfex.info claims`).
- `unit_refs: [~r/^§(?<chapter>\d\d)\.(?<id>[\w.]+)$/]`: the project's own forms of citing
  a spec unit across files, read in `verifies:` tags and by the tasks (`mix surfex.info claims`).
- `tests: ["test/**/*_test.exs"]`: test files, scanned per test case. Add
  `Surfex.ExUnitFormatter` to `ExUnit.start(formatters: [...])` to record evidence.
- `namespace:`: the code's namespace (defaults to the app name).
- `scanners: [:elixir, {MyApp.DslScanner, opts}]`: code scanners whose items are combined
  (`Surfex.Scanner`); one key from two scanners is an error. `scanner:` with
  `scanner_opts:` is the one-element list. A scanner for a DSL gives each block it declares
  (an action, a policy) as an item keyed `Module.name` (`Surfex.Scanner`, spec §4.1), and
  its `calls/3` says which item a call through the DSL's entry drives, so tests reach it
  (spec §5.4).
- `router: MyAppWeb.Router` (or a list, or `false`): the router a test's requests resolve
  through. Without it, the router an endpoint plugs is found from source. A test's
  `live(conn, "/carts/1")`, `get(conn, …)` and the other verbs then call what the route
  runs (a LiveView's `mount/3` and `handle_params/3`, or a controller action), its
  `render_click(view, …)` and friends call the view's `handle_event/3`, and
  `GenServer.call(Module, msg)` calls that module's `handle_call/3` (spec §11.3).
- `checks: [[id:, run:, verifies:, inputs:]]`: gates that verify claims, such as a linter
  rule or a project's own verification task: a command that can fail, the spec units it
  verifies (a table's every row as `TABLE/*`), and the files it inspects, which with the
  declaration make its version (`mix surfex.info validation`, spec §11.4).
- Citation profile: `exclude`, `shape`, `token`, `known_shape`, `normalise`, `subjects`,
  `table_columns`, `file_targets`, `known_external`, `documented_absences`.
- `classes: [{name, reason}]`, `rules: [%{class:, kinds:, name:, parent_cited:, parent:}]`,
  `never_excused:`: kinds of code the spec deliberately doesn't describe.

**Policy**
- `require: [code: [:implements], test_hint: [:verifies]]`: what must take part in a
  relation of those types (keys: a kind, or a spec role `section`, `block`, `test_hint`,
  `table`, `row`, `rule`, `contract`).
- `triangle: :report | :fail`: whether a unit, its tests and its code must meet.
- `require_red:`: whether a `tests` relation needs its test's red run.
- `adoption: :reevaluate | :trust | [trust: globs, reevaluate: globs]` (`mix surfex.info adoption`).
- `completeness: [min: N]`: fail status below N percent.

**Outputs**
- `goldens: [:status, :completeness]`: `RELATIONS.md`, `COMPLETENESS.md`.
- `process: :print | {:command, argv}`: where `mix surfex.draft --file` sends drafts.

The check's own options (`--validated`, `--no-marks`, `--no-baseline`, …) are on the
command line: `mix surfex.info status`.
