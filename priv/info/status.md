# Reading the status

`mix surfex.status` prints a verdict (`ok` or `FAILING`), counts per type and state, then
each group needing attention. It exits non-zero when failing.

Options: `--format json` (the work list), `--verify` (check the log's integrity),
`--evidence` (check evidence confirmations against the last test run), `--merge PATH`
(once per CI job's evidence file: checked together, so no claim goes unchecked), `--validated` (also
fail on unvalidated relations), `--no-planned` (fail on planned), `--no-marks` (fail on
marks), `--no-baseline` (fail on relations resting on an adoption baseline).

**What fails, and the usual fix:**

| Group | Fix |
|---|---|
| Dangling | see what changed; re-confirm by the process (`mix surfex.info process`) |
| Proposed | validate it: evidence (`confirm --evidence`) or a review (`validate`) |
| Orphaned | `mix surfex.move OLD NEW`, or `retire` |
| Conflicted | `mix surfex.resolve FROM TO --type T --pick TIP` |
| Unmet | relate it (`suggest`, the process), or excuse code with a class |
| Broken / broken citation | fix the tag, or the name the spec cites |
| Unproven | run the tests; a confirmation the evidence doesn't bear out |
| Undeclared | the test dropped its tag: restore it, or retire the relation |
| Triangle | the unit's verifying test must call the implementing code (`triangle: :fail`) |
| Unvalidated (`--validated`) | review it (`mix surfex.validate`) |

Not failing: new, planned, impacted, open marks (unless `--no-marks`), and claims not
checked here because this run excluded or skipped their test.

JSON, per relation: `type`, `state`, `impacted`, `tips`, and `ends`, each with `kind`, `id`,
`recorded` and `now` (hashes), `changed`, `planned` and `location`. Work it one relation
at a time.
