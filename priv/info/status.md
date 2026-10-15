# Reading the status

`mix surfex.status` prints a verdict (`ok` or `FAILING`), counts per type and state, then
each group needing attention. It exits non-zero when failing.

Options: `--format json` (the work list), `--verify` (check the log's integrity),
`--evidence` (check evidence confirmations against the last test run), `--merge PATH`
(once per CI job's evidence file: checked together, so no claim goes unchecked), `--validated` (also
fail on unvalidated relations), `--no-planned` (fail on planned), `--no-marks` (fail on
marks), `--no-baseline` (fail on relations resting on an adoption baseline),
`--no-deviations` (fail on declared deviations).

**What fails, and the usual fix:**

| Group | Fix |
|---|---|
| Dangling | see what changed; re-confirm by the process (`mix surfex.info process`) |
| Proposed | validate it: evidence (`confirm --evidence`) or a review (`validate`) |
| Orphaned | `mix surfex.move OLD NEW`, or `retire` |
| Conflicted | `mix surfex.resolve FROM TO --type T --pick TIP` |
| Unmet | relate it (`suggest`, the process), or excuse code with a class |
| Broken / broken citation | fix the tag, or the name the spec cites |
| Failed | its test failed in the run, whatever validated the relation: fix the code or the test |
| Unproven | run the tests; a confirmation the evidence doesn't bear out |
| Undeclared | the test dropped its tag: restore it, or retire the relation |
| Unrecorded | a tag with no `verifies` relation: record it (`suggest`, then validate), or remove the tag; one whose relation was retired: remove the tag, or reinstate the relation |
| Moved | a block or hint now sits in another unit: `mix surfex.suggest --accept` relates the new one and retires the old |
| Stale deviations | a test tagged `deviation:` passed: the code meets the unit now, so drop the tag and validate |
| Triangle | the unit's verifying test must call the implementing code (`triangle: :fail`) |
| Unvalidated (`--validated`) | review it (`mix surfex.validate`) |

**Known deviations.** When the spec is right and the code isn't yet, write the test from
the spec, watch it fail, and tag it `@tag deviation: "#119", skip: "known deviation
(#119)"`. Its units are listed under **Deviating** with the reference; their `proposed`
relations (marked `deviates`) don't fail, and a failed run of it isn't Failed. Check it
with the skip included (`mix surfex.test --deviations` runs exactly those): once it
passes, status fails it as a stale deviation. While the tag is on, `mix surfex.confirm
--evidence` holds back (lists, doesn't validate) any `implements` to the unit or a unit
holding it, and under `claim_grain: true` such a relation is unearned as `deviates`.

Not failing: new, planned, impacted, deviating (unless `--no-deviations`), open marks (unless `--no-marks`), claims not
checked here because this run excluded or skipped their test, and tests unselectable by
`--only`. A test tagged `verifies: ["a", "b"]` is recorded against both ids, but
`mix test --only verifies:a` selects it by neither (ExUnit compares the list as one
string). The text counts them; the JSON's `unselectable` lists each test and its ids.
`mix surfex.test ID` runs them by what they declare, so a list tag costs nothing there.

**Uncredited** (with `--evidence`, not failing): a test that went red then green against
the same code versions, so its red→green can't be credited. What made it pass is outside
what it reaches: look for a call the scanner doesn't see (a dispatch by name, an
unscanned module), a change outside the scanned code, or a flaky test.

**Contained** and **On a container** (not failing): a claim verified only through a claim
inside it, its own prose unclaimed, and a `verifies` aimed at a unit with no text of its
own, which verifies nothing. The header line counts claims by verdict
(`claims: N · verified · contained · unverified · containers`); `mix surfex.info claims`
says what each means and how a contained claim is settled. Under a `require:` spec rule a
contained claim's unmet line ends `contained: a unit inside it is verified, its own text
isn't`.

**Excused and deferred** units (spec classes and deferrals) are counted in one header
line, `excused by class: N (M with claims inside) · deferred: N`, and listed in the JSON.
Under `claim_grain: true` two lists fail: **Contradicted**, a relation to a section its
class says asserts nothing (retire the relation, or remove the class), and **Stale
deferrals**, a deferral whose unit has a test of its own, whose issue is closed, or that
the tracker couldn't answer. `mix surfex.status --issues` asks the tracker through the
`issues:` command; without it only a built unit is judged.

**Unearned** (under `claim_grain: true`, counted in the header): an `implements` no
verified claim's test or check exercises, with why (`unverified`, `not_exercised`,
`nothing_inside`; `mix surfex.info claims`). It meets no `require: code:` rule, and the
list fails where `require: [code: [:implements]]` is set. `not_exercised` usually means
the code belongs to another claim: `mix surfex.migrate --report` shows which. The same
report lists each contained section with the verified claims inside it, the migration's
one work list (spec §14.2).

**Inert** (not failing): a `verifies` tag that applies to no test or property block, so it
verifies nothing: a `@tag` no test follows, a `@moduletag` or `@describetag` over no test,
or any tag in `test/support/`. Move it onto the test that checks the claim, or delete it.

JSON, per relation: `type`, `state`, `impacted`, `tips`, and `ends`, each with `kind`, `id`,
`recorded` and `now` (hashes), `changed`, `planned` and `location`. Work it one relation
at a time.
