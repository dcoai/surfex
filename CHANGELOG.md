# Changelog

All notable changes to Surfex are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

`mix.exs` reads `0.8.1-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

## [0.8.0] — 2026-10-13

A planted bug now fails the gate. A failed test fails its relations whatever validated
them, so a project validated by review no longer passes while the tests behind its
requirements fail (#211). And a version now covers the hidden code its item runs, so
changing a GenServer's `handle_call/3` dangles the relations on its module and on the
functions that call it (#210). A minor release because the second changes versions:
**upgrade step** below, a one-time review of the hidden code no earlier review saw.

### Changed

- **A version covers the hidden code its item runs** (#210, #193, #213). A `@doc false`
  definition, or an `@impl` callback with no `@doc`, is no item, and until now no version
  covered it, so changing a GenServer's `handle_call/3` dangled nothing. The Elixir
  scanner now folds hidden definitions into versions. A module's version covers its
  hidden definitions; a module with none keeps its version. A public function's version
  covers the hidden definitions it runs: those it calls locally, and the module's hidden
  callbacks when it dispatches through its own behaviour (`GenServer.call`,
  `GenServer.start_link`, `:gen_statem.call` from a module that `use`s or declares that
  behaviour). A call naming a hidden definition, such as a Mix task's `run/1`, now reaches
  the module and goes on through what the definition calls, so evidence credits the code
  a task hands its work to. `Surfex.Item` and code records gain `hidden`, and
  `Surfex.SourceScan.module_hash/1` and `defs/1` are unchanged, so surface goldens built
  on them don't move.

  **Upgrade step.** Every module with a hidden definition, and every function running
  one, gets a new version once, and its relations dangle. Measured on seven adopting
  projects, 4 to 185 item versions change. Most of the relations that dangle are `tests`
  relations, which `mix surfex.suggest --accept` re-records. After `mix test`, `mix
  surfex.confirm --evidence` re-confirms the `implements` relations confirmed by
  evidence. What remains, between 1 and 108 `implements` validated by review, is a
  review, and reading the hidden code is the point of it: no earlier review saw it
  versioned.

### Fixed

- **A failed test fails its relations, whatever validated them** (#211, #212). With
  `--evidence` or `--merge`, a current `verifies` or `tests` relation whose test failed at
  the version the relation holds is now reported as **failed**, and fails the check. That
  holds whether the relation was validated by evidence, a review, a judgement or a
  baseline. Before, only claims by evidence or baseline were checked against a run, so a
  project validated by review (`adoption: :reevaluate`) passed its surfex gate while the
  tests behind its requirements failed. The relation isn't invalidated: once its test
  passes again, it holds with no new review. A claim by evidence whose test failed now
  appears under the new `Failed` heading (JSON `failed`), not under `Unproven`. An
  `implements` claim judged over its candidate tests stays under `Unproven`. A gate whose
  tests pass sees no change.

## [0.7.2] — 2026-10-13

A fix for 0.7.0's slow evidence check. `mix surfex.status --verify --evidence` took 36
minutes on a project with about 4,000 tests and 500,000 evidence records, where 0.6.2
took 5. It now takes seconds, with an identical result (#201). No upgrade step.

### Fixed

- **`mix surfex.status --evidence` grows with the project in proportion again** (#201,
  #202). Since 0.7.0 every test's reached code joins the pairs an `implements` claim's
  candidate tests are found among. The check scanned every `verifies` pair against all of
  them for each claim, and then the whole run's evidence for each candidate test. On a
  project with about 4,000 tests and 500,000 evidence records, that took 36 minutes,
  where 0.6.2 took 5. The candidates and each test's latest record are now indexed once
  per check. On that project, the check's derivation takes 10 seconds, with an identical
  result. A test now holds the check's work over a project twice as large to about twice.

## [0.7.1] — 2026-10-13

What 0.7.0's users asked for, and two corrections. Unit ids take several heading grammars
and lettered section numbers, and a marked table keys on several columns and can leave
measured ones out of a row's version (#187). A review credits only the code its test
calls, and reached code once you name it (#191). A test tagged with a list of ids, which
`mix test --only` can't select, is counted by status (#190), and `mix surfex.test UNIT`
runs it with the rest of a requirement's tests (#198). No upgrade step. A misspelt table
marker option, which used to leave the table unmarked, is now an error.

### Added

- **Several heading grammars, and lettered section numbers** (#187, #188). `heading_ids:`
  takes a list of grammars, tried in order, for a spec that writes ids in more than one
  form: `[~r/^(?<id>ADR-\d+[a-z]?)\b/, :section_number]`. A single grammar stays valid,
  and two grammars reading one id is the repeat error it would be from one.
  `:section_number` reads a lowercase letter on a number's last part when its dot follows:
  `## 2a. Model checking` is `#2a`, while `## 3d rendering` is still a path. A spec using
  `:section_number` with such headings sees them re-id'd with their versions unchanged, so
  `mix surfex.suggest --accept` carries their relations across as moves.

- **Composite table keys, and columns left out of a row's version** (#187, #189). A table
  whose row is identified by a pair keys on both: `<!-- surfex: table options key:
  [Function, Key] -->` gives `file#options/render/2/:width`. A column that records a
  measurement rather than stating a claim can be left out of each row's version, so
  refreshing it dangles nothing: `ignore: [Measured]`. It can't name a key column. The
  options read in either order, and a single `key: Header` is unchanged.

- **Status says which tests `mix test --only` can't select** (#190, #196). ExUnit
  compares a list tag as one string, its ids run together, so a test tagged
  `verifies: ["a", "b"]` is selected by neither `--only verifies:a` nor `verifies:b`,
  while surfex records it against both. A one-id list stays selectable. The test record's
  `unselectable` lists those ids, `mix surfex.status` counts the tests in one line
  (`unselectable by --only: N tests`), and `--format json` lists each with its ids. It
  never fails: a list is the honest tag for a test that verifies several requirements,
  and the count shows what it costs. §11 no longer says `--only` always runs exactly a
  requirement's tests.

- **`mix surfex.test UNIT` runs a requirement's tests, list tags included** (#198, #200).
  It selects every test whose `verifies:` declarations resolve to the unit, as surfex reads
  them, and runs `mix test FILE:LINE …`, which ExUnit's location filter selects exactly.
  It exits with that run's status. `--within` adds the tests of the blocks, hints and rows
  inside a unit, `--list` names the tests without running them, and arguments after `--` go
  to `mix test`. A unit that is unknown, ambiguous or that no test declares is an error
  rather than an empty, passing run. `Surfex.Select` makes the selection.

### Changed

- **A table marker's text after its id must be its options** (#189). A misspelt option
  (`keys: A`) or a repeated one used to leave the line as body, so the table quietly wasn't
  marked. It's now an error naming the line.

### Fixed

- **A review credits the code its test calls, and reached code only when named** (#191,
  #192). Since 0.7.0, `mix surfex.validate` credited every `implements` its test reached
  under the one note, including code behind an entry point that the reviewer never read.
  Now code the test reaches only through other code is credited when you name it:
  `--code ID`, once per item. A named id the green run didn't reach is an error, and a
  review with only reached code to record says which to name. Evidence still credits
  reach without naming.

## [0.7.0] — 2026-10-12

Finer units and honest credit, the first part of claim grain (#145). Headings keep the ids
their authors write, a marked table's rows are units, and a test is credited for the code
it reaches through an entry point. Completeness counts a function once whatever its
default arguments, and the triangle reads what a test calls from the source. One upgrade
step: `verifies` tags now combine as ExUnit merges them, so a test inherits a requirement
only where it doesn't set its own (see Upgrading). Claim forms, the rest of #145's plan,
come in a later release.

### Added

- **Headings keep the ids their authors write** (#179, #180). A section's id is, in order:
  - an id comment at the end of the heading, `## Totals <!-- surfex: totals -->`, which
    doesn't render, so it suits ex_doc extras where `{#id}` shows as text;
  - an anchor, `{#totals}`;
  - what the project's heading grammar reads, set by `heading_ids:` in `.surfex.exs`:
    `:section_sign` for `## §Api.3.2 — Limits`, `:section_number` for `## 1.2 Totals`, or
    a regex with a named capture `id`;
  - otherwise its heading path, as before.

  A written id survives renaming the heading, is never numbered `~2` (a repeat is an
  error), and may be cited bare. A `§` id may keep its sign: `§Api.3.2`. Ids may now hold
  letters of either case, digits and `. _ - :`; every existing id stays valid. Turning on
  `heading_ids:` re-ids the matching sections with their versions unchanged, so
  `mix surfex.suggest --accept` carries each relation across as a move.

- **A marked table's rows are units** (#179, #181). `<!-- surfex: table ID -->` on the line
  before a table makes the table a unit (role `:table`, its header) and each row one (role
  `:row`), with id `file#ID/KEY`. KEY is the row's first cell, or the column named by
  `key: Header` in the marker, without code or emphasis marks: `` `:word` `` is `:word`.
  Editing a row changes only that row's version. A table without the marker is body, as
  before. The reports count tables and rows only where a spec marks one.

- **A test reaches what the code it calls calls** (#183, #185, #186). Each function and
  macro the Elixir scanner reports now lists the code it calls (`Surfex.Item` and code
  records' `calls`): through its private helpers, a local call to its module's public
  functions, and a `defdelegate`'s target. `Surfex.Scan.reach/1` follows a test through
  them. A section may now cite the function that does the work while its test drives the
  public entry point (a mix task's `run/1` that formats through another module, say):
  - `Surfex.ExUnitFormatter` records the versions of everything a test reaches;
  - `mix surfex.confirm --evidence` carries `implements` to reached code, and a change to
    it dangles the relation until a green run re-confirms it;
  - `mix surfex.validate` credits it by review;
  - `mix surfex.status --verify --evidence` checks the claim against the run;
  - the triangle counts it exercised.
  Reach credits relations someone recorded and never suggests one: `tests` relations
  still name what a test calls itself. Calls aren't part of any version, so nothing
  dangles on upgrade. A scanner of your own may fill `calls`; one that doesn't is
  unchanged.

### Changed

- **`verifies` tags combine as ExUnit merges them** (#149, #171). The most specific level
  that sets `verifies` replaces the others: a test's own `@tag` over its describe's
  `@describetag` over its module's `@moduletag`. Until now surfex took their union, so
  surfex disagreed with `mix test --only verifies:id`, and a test could be recorded as
  verifying its module's requirement without anyone having judged it. §11 states the rule.

### Fixed

- **The triangle reads what a test calls from the source** (#173). A test counts as
  exercising code when its scan record calls it, as well as when a `tests` relation records
  it, compared by definition. A project that doesn't record `tests` relations (by running
  `suggest`) no longer sees the code its tests call reported as untested. A call to code not
  written yet still shows the code missing. Gaps can only shrink.

- **Completeness counts a function once, whatever its default arguments** (#182). A
  function's default-argument arities (`f/2`, `f/3`) are one code item, as they already
  were to `require:`, the triangle and `validate`. They're judged together, counted once,
  and listed under the first id. A relation per arity is no longer needed to score 100%,
  and the code total now counts definitions, so it may drop.

### Upgrading

- `mix surfex.status` lists the relations a test no longer declares under
  "Undeclared". For each, judge whether the test really verifies the inherited
  requirement:
  - if it does, name it in the test's own list: `@tag verifies: ["own-id", "module-id"]`.
    `mix test --only` then selects that test by neither id, since ExUnit compares a list
    as one string (#190; 0.7.1's status counts such tests);
  - if it doesn't, retire the relation with a note:
    `mix surfex.retire "test:<test id>" "spec:<unit>" --type verifies --note "why"`.
- Measured on six adopters before the change, the cost ranged from none (where tests
  already name every id they verify) to about two hundred relations. Surfex settled its
  own 133 this way, keeping 42 and retiring 91, and added two tests for
  `recording-by-name` that the union had been standing in for.

## [0.6.3] — 2026-10-11

The first release published to GitHub with its full history, from the v0.2.8 cut. No change
to surfex itself and no upgrade step; a clone made from GitHub before the recut needs the
README's "History" steps.

### Changed

- **GitHub carries the full history, from v0.2.8** (#174). Until 0.6.2 it carried release
  snapshots, since the earliest commits held material from the project surfex grew out
  of. The history is recut at v0.2.8, the first release after the separation, and
  published from there. A clone made before the recut needs a forced fetch; the README's
  "History" section says how.

## [0.6.2] — 2026-10-09

Making the honest path cheap, from the users' RFC on #145: batched `confirm` and
`validate` with a distinct note per relation, `annotate` for a current relation, declining
shown beside each suggestion, code moves suggested when a function's arity changes, CI's
evidence readable by the recording commands, and `suggest` about fifteen times faster on a
large log. `Surfex.Golden` and `Surfex.SourceScan` are now documented, supported library
API. No upgrade step.

### Added

- **Recording reads CI's evidence** (#154). `--merge PATH` on `confirm --evidence`,
  `validate`, `relate` and `suggest --accept` reads other runs' evidence files (CI
  artifacts) with the local run as one history, so a test excluded locally because it
  needs a service you don't run counts from CI's run. A missing file fails.
- **`suggest` proposes code moves** (#153). When a function's arity changes
  (`render/2` → `render/3`), its relations used to orphan, and each was retired and
  re-validated. Now suggest proposes the move, which carries them across to be judged once
  more. `mix surfex.move` already worked for code ids; its docs now say so.
- **`mix surfex.annotate`** (#152): a current relation takes a new note, re-recorded at its
  own versions and basis. A re-review that changes nothing, such as fixing a batch of
  templated notes, now lands in the log rather than a commit message.
- **The docs say plainly that `@doc` isn't covered** (#155). A function's or type's
  version leaves out its docstring, so a `@doc` stating a contract can drift from the spec
  unnoticed. A test pins this, so covering docstrings (planned with claim-level relations)
  will change it deliberately.
- **`suggest` shows how to decline each judgement** (#148). Under each `implements` and
  `excuses` candidate it prints the exact `retire` command that declines it, so the decision
  lands in the log and the pair is never proposed again. Declined in a commit message, it
  came back on every run.
- **Batched `confirm` and `validate`** (#147). `--file PATH` records many relations in one
  run, one per line (tab-separated, each line ending with its own note), saving the project
  load per relation that made agents script loops with templated notes. **The notes must be
  distinct**, or the batch is refused; each line is judged as the single form judges it, and
  a refused line fails the whole batch.
- **`Surfex.Golden` and `Surfex.SourceScan` are supported library API** (#150). Projects
  that render surface goldens without a relation log call them, and their CI gates rest on
  them, yet since 0.5.16 they weren't on hexdocs.
  - They are documented now, with a guide, "Using surfex as a library", and a promise:
    their documented functions and types keep their shapes (as they have since v0.1.0), and
    `definition_hash/1` gives the same version for the same code.
  - A change to either comes only in a minor release, marked here for library users. A
    test pins their documented surface.
- **`mix surfex.info` notes a project with no relation log:** rendering goldens is a use of
  surfex, not adoption.

### Fixed

- **`suggest` is linear in the log** (#168). It re-filtered the whole log once per
  relation, so on surfex's own log (~10k entries) it took ~32 s, ~30 of them in that one
  helper; it now takes ~2 s. A test counts its work (reductions, not seconds) over N and
  2N relations.
- **Suggestions no longer follow the order of the scans or the log's lines** (#151). A
  shuffled input reordered `suggest`'s lists (the `tests` suggestions showed it). Every
  list is now sorted by the ids it names, and a test renders every report, golden and
  suggestion list from surfex's own log in two orders and requires them identical.
- **`confirm --file` no longer crashes** (#162). Its option guard used `or` on an absent
  switch (`nil`). Both tasks' `--file` paths are now tested end to end.
- **A function's default-argument arities are one item to `require:`** (#146). `f/1` and
  `f/2` from one `def f(x, y \\ 1)` each needed their own relation, so projects wrote a
  call or a citation per arity to clear "unmet". The triangle and `validate` already compared
  code by definition; now the policy does too.
- **The library-API pin test no longer depends on test order** (#158).
  `function_exported?/3` is false for a module not yet loaded, and tests load modules lazily,
  so the test failed about one run in four. It loads the module first now.

## [0.6.1] — 2026-10-07

An ExUnitProperties `property` is now a test, so a suite's generative tests can verify
spec units. No upgrade step.

### Added

- **Properties are tests** (#141). The ExUnit scanner records an ExUnitProperties
  `property` as it does a `test`: its id, its `verifies` tags, what it calls, and a version
  that changes with its `check all` generators. Its runs are evidence, so a property can
  verify a spec unit.

## [0.6.0] — 2026-10-07

Public types are items: a spec may cite `Mod.t()`, and a relation to a type is judged,
since no test run exercises one. The relation log is model-checked with extla, the real
code as oracle, which found two defects, both fixed here: tips that agree are not a
conflict, and a review records only what isn't validated already. Projects that require
code relations have one upgrade step (below).

### Upgrading (0.6)

Public types are now code items (#137). A project whose `require:` asks code for a
relation (`require: [code: [...]]`) finds each public type unmet until it is related or
excused. To excuse them as a class, add to `.surfex.exs`:

```elixir
require: [code: [:implements, :excuses], ...],
classes: [{"type", "a type is the shape of the data its functions take and return"}],
rules: [%{class: "type", kinds: [:type]}],
```

then `mix surfex.suggest --accept` proposes one `excuses` per type, and each is confirmed
by judgement (`mix surfex.confirm class:type code:t:Mod.t/0 --type excuses --note …`). A
type the spec cites is related instead, by judgement (below).

### Added

- **Types are items** (#137). Each public `@type` and `@opaque` is an item keyed as ExDoc
  writes it, `t:Mod.t/0`, versioned by its own declaration. A spec cites it as `Mod.t()`
  or `t:Mod.t/0`; an undeclared or private type is still an unresolved citation. A
  function of the same name keeps its own key.
- **A shape is judged** (#137). A type has no behaviour for a test run to exercise, so an
  `implements` relation to one is confirmed by judgement, with a note saying what was
  compared, and dangles when the type changes. The scanner marks such items (`shape`);
  code with behaviour is still never confirmed by hand, and a judgement on it doesn't
  validate.
- **Models of the relation log** (§22). Exhaustive extla models drive the real recording
  code and check the real status in every state they reach. Across two branches and main,
  merged by git's union merge: order doesn't matter, a conflict is a disagreement between
  tips, resolving ends it, and every entry reads back. Through versions and validation,
  on the evidence path and the review path: a current relation's ends are at their
  versions, a current `implements` rests on evidence or a review, every entry on evidence
  is borne out by runs, and every review rests on a green run. Through moves: every claim,
  retirement and red→green survives a rename. And liveness: whatever changes, a dangling
  relation whose test passes comes back to current. They run in a Mix environment of
  their own (`MIX_ENV=model`) and their own CI job.

### Changed

- **A review records only what isn't validated already** (#138). `validate` re-recorded
  the test's `verifies` on every call, and replaced one on its failing run (a claim CI
  checks) with a review (which it doesn't). Now that `verifies` keeps its basis, and a
  review with nothing left to record is refused. Found by the model of the log.
- **The README installs surfex from Hex** (`~> 0.6.0`) rather than from GitHub, and
  points to the docs on hexdocs.
- **The README drops "Upgrading from the v0.2 trace"**: the trace went in 0.4.0, and
  spec §9 and the 0.4.0 entry below keep the record.
- **Tips that agree are not a conflict** (§13.1). Two branches that record the same
  judgement without seeing each other (the same operation, ends at the same versions, and
  basis) no longer leave a conflict to resolve, as when both re-run `confirm --evidence`
  after merging main. Who recorded it, when and the note are context, so both entries
  stay in the log and both tips are reported. A different operation, version or basis still
  conflicts, and `resolve` refuses tips that agree. Found by the model of the log.

## [0.5.24] — 2026-10-02

The first release on Hex. Its usage rules are one short page for an agent that points to
`mix surfex.info`, so a project's `AGENTS.md` stays small and the detail always matches the
installed version.

### Changed

- **The usage rules are one short page that points to `mix surfex.info`** (§21).
  `usage-rules.md` is now the agent page: what surfex is, the rules for an agent, and where
  to find the rest. The directory and the other topics are back in `priv/info/`, so
  `mix usage_rules.sync` copies one short page into a project's `AGENTS.md` instead of
  every topic, and the detail always matches the installed version.

## [0.5.16] — 2026-10-02

The first release on Hex. Its docs are a guide to using surfex as a mix tool, and its
usage pages ship as `usage-rules.md` for `usage_rules`, so the same text reaches the
terminal (`mix surfex.info`), hexdocs and a project's `AGENTS.md`. It also keeps a moved
baseline relation in CI's check, and makes the baseline adopt tags deliberately.

### Added

- **Docs on hexdocs, as a usage guide** (§21). They lead with the README and the usage
  pages, then the `mix surfex.*` tasks and the three modules a project writes code
  against (the evidence formatter, the scanner behaviour and its item). Every other
  module keeps its documentation in the code.
- **Usage rules for agents** (§21). The `mix surfex.info` pages ship as `usage-rules.md`
  and `usage-rules/`, so `mix usage_rules.sync` gathers them into a project's
  `AGENTS.md`. The main file carries the core rules for an agent as well as the map.
- **The baseline adopts the tags already written, and says so** (§18.1). `mix surfex.baseline`
  refuses when the trusted tests declare no `verifies:` tags, since a one-shot step would
  spend itself on test versions alone, unless `--no-tags` says that is intended. It ends
  by reporting the trusted test versions, the `verifies` adopted and the spec units left
  without one, and the adoption guide now tags first.

### Changed

- **Surfex is described as keeping a spec, its tests and its code aligned**, and the README
  opens with the problems it catches when building with an LLM.

### Fixed

- **A moved baseline relation stayed out of CI's check** (§17). `--evidence` found its
  claims partly by the note "confirmed by evidence", which a move replaces, so a baseline
  relation carried by a move (a split test file, a renamed section) was no longer checked.
  Claims are now found by basis, `evidence` or `baseline`.

## [0.5.0] — 2026-10-02

Validated, not asserted. Every `implements` relation is now shown by the process: a test
that failed and then passed against the code, or a reviewed test that passes against
it, recorded with the basis that validated it. A test version's red→green is kept in the
log, so it survives a clean checkout. An established project can adopt its suite on
trust, once, and earn evidence as its tests next discriminate. Surfex now explains itself
to an agent (`mix surfex.info`), scores completeness, marks a spec that is wrong in use,
hands found work to a project's own process, checks a suite split across CI jobs, and
keeps what the log decided across renames. A **minor** release that breaks:
`implements` can no longer be confirmed by hand (`mix surfex.confirm` refuses it), the
log enforces its own grammar when it reads an entry, and the unused `config` end kind is
gone. Existing logs load unchanged, with every id as it was.

### Added

- **Declining a suggestion** (§14). `mix surfex.retire` on a pair never related records
  the decision not to relate it, with a required note, so `suggest` never proposes it.
  Before, declining took a `relate` whose only purpose was to be retired.
- **Excusing a module family** (§8). A rule's `parent:` regex matches a member's parent
  module, so scaffolding a generator emits (`MyAppWeb.CoreComponents`, `Layouts`, …) is
  excused by family rather than by a list of function names that also catches real
  entry points elsewhere. A class whose rules don't use it keeps its version.
- **Moving a test brings its records** (§14). `mix surfex.move` carries a test's
  red→green and baseline records to its new id when its version is unchanged, as when a
  test file is split into sub-modules or a `describe` regrouped. A test that changed earns
  them again, and the task lists what stayed behind. A carried baseline is not a second
  one. `mix surfex.suggest` spots these moves itself (same version, one to one), and lists
  a version found under several ids as ambiguous rather than guessing.
- **A suite split across CI jobs can pass `--evidence`** (§17). The formatter records an
  excluded or skipped test as such, at its version. A claim whose test this run left out
  is listed as *not checked here* in every report and doesn't fail; a test with no record
  at all still fails, so a broken job can't hide behind an exclusion. A final job checks
  every job's evidence together with `mix surfex.status --merge PATH` (once per file): a
  disproof in any job fails, and so does a claim no job ran.

- **`mix surfex.info [TOPIC]`** (§21): Surfex explains itself to an agent from the
  installed version. With no topic, a directory of under 100 lines: what Surfex is, a
  topic per line, and every command grouped by job. With a topic (model, process, agent,
  status, recording, validation, marks, adoption, completeness, drafts, goldens, config),
  a dense page with exact commands. The pages ship in `priv/info/`; a test keeps every
  command listed.
- **Adopting an existing suite** (§18.1): `adoption:` in `.surfex.exs` is `:reevaluate` (the
  default: every test earns its relations by discriminating), `:trust`, or `[trust: globs,
  reevaluate: globs]` by area. Under trust, `mix surfex.baseline --note N` takes a one-shot
  baseline: a `baseline` observation per trusted test version that has run green, and its
  declared `verifies` with the new basis `baseline`. A baselined test carries `implements`
  through `confirm --evidence` as `baseline` too. Trust only shrinks: a changed test
  version isn't baselined, narrowing `adoption:` leaves its relations unvalidated, and a
  test's first red→green moves them to `evidence`. Every report counts baseline relations
  with the mode, `--no-baseline` (`baseline: :fail`) fails on them, and completeness counts
  a baseline that holds as validated. A new guide, *Adopting an existing suite*, says
  when to trust, what the baseline is and isn't, and what each change costs afterwards.

- **Needs-update marks** (§12.1, §13.1, §14): `mix surfex.mark SPEC_UNIT --needs-update
  --note N` records that a spec unit itself needs to change, because the tests reflect it
  and the code passes them but the result is wrong. A mark is open while the unit is at
  the version marked and resolved when the spec changes; `--withdraw` withdraws one.
  Status reports open and orphaned marks in every report, and `--no-marks` fails on them.
  Entries recorded before marks keep their ids.
- **Change drafts and the hand-off** (§19): `mix surfex.draft [ID…] [--format
  markdown|json] [--file]` writes up every open mark, unmet id and triangle gap (or the
  items named) as a draft: the problem, the unit's text, the tests and code it touches, and
  the process's steps. `process:` in `.surfex.exs` (`:print`, or `{:command, argv}` with
  `{title}`, `{body}` and `{file}`) is how `--file` hands them to the project's own change
  process. `mix surfex.mark` prints the new mark's draft.
- **Completeness** (§20): `mix surfex.completeness [--format text|json]` scores how much
  of the spec, the tests and the code is covered by validated relations, per kind and
  overall, and lists each incomplete item with what it lacks. `completeness: [min: N]`
  makes `mix surfex.status` fail below a floor, and `:completeness` in `goldens:` commits
  the report. Surfex scores 100% and holds itself there.
- **Discrimination is kept in the log** (§12.1, §17): `mix surfex.confirm --evidence`
  records each test version that went red then green as a `red_green` observation. From then
  on, after `mix clean`, on a fresh checkout or in another worktree, a green run against the
  current code re-confirms that test's relations. Observations are one-ended entries
  (`op: observe`), never relations.

### Changed

- **The log enforces its own grammar** (§12.1). Each type's end kinds and direction, and
  the bases each type and op may carry, are checked when an entry is built or decoded, so
  a malformed line from a bad merge or a hand edit is refused where it is read, naming the
  entry and the rule. `mix surfex.log --verify` gives each problem's file and line.
  Entries written before bases existed still load (a basis-less `implements`, `verifies`
  or `excuses`), and every existing id is unchanged. `implements` never carries
  `judgement`; a `depends_on` joins code to code. The unused `config` end kind is gone.
- **The README opens with what Surfex does** and the situations it handles, without
  commands; the how-to list gave way to `mix surfex.info`.
- **A relation is validated by the process, never asserted** (§18).
  - Code relations (`implements`) become current only on evidence (a verifying test that
    went red and then green) or a review (`mix surfex.validate`).
  - Test relations (`verifies`) are recorded on the test's failing run.
  - A citation, a tag on a test that never failed, or a pair named by hand is recorded as
    **proposed**, which fails the check until validated. `mix surfex.suggest --accept`
    validates nothing.
  - Each entry records its `basis` (`evidence`, `review`, `judgement`, `proposed`). It is
    written only when set, so every existing entry keeps its id.
  - Relations current without a validating basis are reported as **unvalidated**, and
    `mix surfex.status --validated` fails on them.
  - A move keeps the basis it carries.
  - The text report lists proposed relations with the other failing states, and counts
    unvalidated ones, listing them under `--validated`. The JSON report lists them as
    `unvalidated`.
- **`mix surfex.confirm` confirms one relation, with a note:**
  `confirm FROM TO --type T --note N`. It is the judgement path (a spec reworded without
  a change of behaviour, an excuse), and it refuses `implements`. `confirm ID`, which
  confirmed every relation touching an id, is removed, as are
  `Surfex.Record.confirm/4` and `/5` (now `/6` and `/7`, one relation).
  `mix surfex.confirm --evidence` also records a test relation on its failing run.
- **`mix surfex.validate TEST SPEC_UNIT --note N`** (`Surfex.Record.validate/6`) records a
  review: the test was examined against the unit, judged to validate it, and passes
  against the code. The unit may be a section whose hint or block the test verifies, once
  that relation is validated: the review then records the section's `implements` alone.
- **`mix surfex.suggest --accept` refreshes structural relations** (§15): a dangling
  `tests` relation whose test still calls the code, or `refines` relation whose block is
  still within its unit, is recorded again. They record facts read from source, so reading
  it again re-establishes them. Judgement relations are never refreshed.
- Surfex's own relations are all validated by review (§2–§17), and its CI now runs
  `mix surfex.status --verify --evidence --validated`.
- Spec §10.4 said `mix surfex.goldens --write` fails after regenerating a drifted golden.
  It never did, and it shouldn't: regenerating is how a drift is resolved. The spec and
  the task's docs now say it succeeds, and a test pins it (#84).
- The README's worked example, and the guide's test-first and LLM sections, now describe
  the process.

- **Surfex closes its own spec/test/code triangle, and gates it** (`triangle: :fail`).
  Every section that code implements now states its claims as test hints (46 in all),
  each verified by tagged tests that exercise the implementing code; new tests cover the
  claims that were unchecked (the gate, item keys, the scanner contract, the log's
  vocabulary, the config readers, and more). Relations that existed only because a section
  mentioned code described elsewhere were retired.

### Fixed

- **A move keeps the relations someone retired** (§14). `mix surfex.move` carried only
  live relations, so after an anchor was added the retired ones were forgotten and
  `suggest` proposed them again. A retired relation now comes across as retired, with its
  reason, and `suggest` finds a move whose old id only retirements name.
- **A name glued to a root is no citation of it** (§5.2). `MyAppCollector.Forge`,
  `MyAppWeb.…` and a `MyApp-Profile` header were read as citations of the root module
  `MyApp` and suggested as `implements`, hiding a stale name as a plausible relation.
  A name now ends where a name ends, and every top-level module the code defines is a
  root (a Phoenix app's `MyAppWeb` beside `MyApp`), so a stale name under any root is
  reported as an unresolved citation.
- **`exclude:` drops a file from the spec entirely** (§8). It left an excluded file's
  headings in as spec sections and dropped only its citations, so an excluded README
  became sections in no relation.
- **A test's calls see aliases where they're declared** (§11). An alias inside a test
  body was ignored, so a call through it was recorded under the short name and the test
  had no `tests` relation to the code it plainly calls. A `describe`'s alias, meanwhile,
  reached every describe in the module. Aliases now apply as the compiler sees them.

- **A planned `verifies` is proposed** (§14). `mix surfex.relate --planned` wrote one with
  no basis, so it read as a legacy entry. `Surfex.Record` now refuses to write any
  basis-less `implements` or `verifies`.

- **Resolving a conflict keeps the chosen tip's basis** (§14, §18). `mix surfex.resolve`
  re-recorded the tip without it, so resolving between validated tips left the relation
  unvalidated, and resolving between proposed ones made a claim current.

- **A `verifies` relation outlived its test's declaration.** Removing a
  `@tag verifies:` left the relation current, because a tag isn't part of a test's
  version. Such a relation is now **undeclared**, and fails the check;
  `mix surfex.suggest --accept` retires it, since the test's own source says the claim is
  gone.
- A test of the scanner contract could fail when its scanner module, defined later in the
  file, wasn't loaded yet as async tests started.
- **The triangle reported false gaps.** A test's `calls` now include every module it calls
  or names (a module handed to a helper, as a Mix task is), so a module a section names
  counts as exercised. The private helpers defined inside a `describe` block are followed,
  for a test's calls and for its **version**: weakening such a helper now changes the
  test's version, as weakening a top-level one always did. Code is compared by definition
  (`Surfex.Scan.definition/1`), so one function's default arities are one code. On surfex
  itself this removed 20 of 99 gaps, all false.

## [0.4.0] — 2026-09-28

Specs and tests in step. Tests are scanned and say what they verify, and each spec unit is
checked from three sides: its code implements it, a test verifies it, and that test
exercises the code. Test runs record evidence, and a test that went red and then green
confirms its code, with no human confirmation, while CI checks every such claim against
its own run and records nothing. The spec gains finer units (anchors, marked
requirements, test hints), code the spec doesn't describe is excused by class, and a spec
naming what doesn't exist fails. A **minor** release that breaks: the v0.2 trace is
removed, and a config written for it fails naming the keys and why (see the README's
upgrade section).

### Removed

- **The v0.2 trace.** It was deprecated in 0.3.0, and the relation log now does everything
  it did. Removed:
  - `Surfex.Trace` and `mix surfex.trace`;
  - the `:trace` goldens entry (`goldens:` now defaults to `[:status]`) and `SPEC_TRACE.md`;
  - `Surfex.Coverage.verdicts/3`;
  - `Surfex.Cite.by_item/2`, `Surfex.Cite.section_label/2` and `Surfex.Cite.headings/2`;
  - the `file_labels:` profile key.

  A `.surfex.exs` that still has a trace-only key (`output`, `purpose`, `columns`,
  `groups`, `prose`, …) raises, naming the keys and why. The README describes the
  upgrade.
- `Surfex.Gate.drift/2` no longer formats a `Cited by` column specially: only the trace's
  golden had one.

### Changed

- Every task reads `.surfex.exs` through `Surfex.Status.Config.read!/1`, which rejects
  unknown keys rather than ignoring them.
- `Surfex.Suggest.candidates/5` and `all/5` take a `Surfex.Profile`
  (`Surfex.Status.Config.profile!/2`) instead of a trace.

### Added

- **Test evidence.** `Surfex.ExUnitFormatter` records each test's result at its exact
  version, with the versions of the code it calls, to `_build/surfex/evidence.jsonl`
  (`Surfex.Evidence`). The file is scratch and never committed. A test version
  **discriminates** once it has failed against one version of its code and passed
  against another, unchanged itself. That is what confirmation by evidence rests on.
  Surfex records its own test runs.
- **Confirmation by evidence.** `mix surfex.confirm --evidence`
  (`Surfex.Record.confirm_by_evidence/4`) confirms:
  - a dangling `tests` relation whose test version has failed once and passes now against
    the current code;
  - then each dangling `implements` relation a verifying test with such evidence carries.

  `verifies` stays a judgement, confirmed by name. After a spec change, only a test
  verifying that exact unit can carry `implements`. The evidence is written into each
  entry's note. `require_red: true` makes a `tests` relation unconfirmable by hand too
  until its test was red.
- **CI validates evidence claims, and records nothing.** `mix surfex.status --evidence`
  checks every relation confirmed by evidence against the last `mix test`'s evidence. It
  fails on one the run doesn't bear out: its test didn't run, failed, or ran against
  other code. Surfex's CI runs its tests from an empty evidence file, then
  `mix surfex.status --verify --evidence`, in one job.
- **A specification guide**, `guides/writing-specs.md`: how to write a spec Surfex relates
  precisely (section sizing, stable headings, naming the code, checkable claims, examples
  and invariants, test-first work, working with an LLM), with a worked example that
  Surfex's tests run.
- **Planned relations.** `mix surfex.relate --planned` (`Surfex.Record.plan/7`) relates a
  section to code that doesn't exist yet, or the other way round. The missing end is
  recorded without a hash. The relation is **planned** until the id is scanned, then
  dangling until someone confirms it, so spec-first and test-first work can record
  intent before the code. A planned relation meets a `require:` policy. A section whose
  only `implements` relations are planned is reported as **unimplemented**.
  `mix surfex.status --no-planned` (`Surfex.Status.derive/4` with `planned: :fail`)
  also fails on anything planned and not built, for a release's check. A plausibility
  check refuses a planned id the project couldn't have, so a typo doesn't become a
  plan.
- **Finer spec units.** A heading anchor (`## Adding items {#cart-add}`) gives a section
  an id that survives renaming its heading. A **marked block** (the lines between
  `<!-- surfex: ID -->` and `<!-- /surfex -->`) is one requirement, and a **test hint**
  (a fence whose info string is `test ID`) says how to test something. Each is a spec
  record of its own, with its own version, and is left out of the version of what it
  sits in, so editing one requirement no longer dangles its neighbours. `Surfex.Scan`
  gains `role` and `within`. `mix surfex.suggest` relates a citation in a block to the
  block. A spec that uses none of these scans exactly as before.
- **Moving relations.** `mix surfex.move OLD NEW` (`Surfex.Record.move/5`) carries every
  live relation of a renamed or re-anchored spec id onto its new id. It retires the old
  relation and relates the new one at the versions that were recorded, so a move never
  confirms anything.
- **More suggestions.** `mix surfex.suggest` (`Surfex.Suggest.all/5` and `accept_all/4`)
  now also proposes:
  - moves, for a related id that is gone and a new id at the same version;
  - `refines`, from each block and hint to what it sits in.
- **Tests as scanned items.** `tests:` in `.surfex.exs` turns on `Surfex.Scan.ExUnit`,
  which reads ExUnit tests from source without compiling them.
  - A test's version covers its body, the private helpers and attributes it reads, its
    setups, and the generators of a comprehension that defines it. Weakening a test
    through any of them changes its version.
  - A test says what it verifies with a plain ExUnit tag, `@tag verifies: "id"`
    (`@describetag`, `@moduletag` too). `mix test --only verifies:id` then runs one
    requirement's tests.
  - A declaration naming no spec unit is **broken** and fails the check.
    `Surfex.Scan.resolve/2` resolves a full or bare id.
  - The new relation type `verifies` runs from a test to a spec unit.
  - `require:` takes spec roles as keys: `test_hint: [:verifies]` requires a test for
    every hint.
- **The spec/test/code triangle.** When tests are scanned, `mix surfex.status` checks
  each spec unit that something implements.
  - It reports the unit if no test verifies it, if a verifying test calls none of the
    implementing code, or if implementing code is called by no verifying test.
  - Gaps are reported, and fail the check with `triangle: :fail`.
  - `mix surfex.suggest` proposes `verifies` from tests' tags, and `tests` from what each
    test calls, with aliases, pipes, captures, imports and private helpers followed.
  - Surfex runs on it: its spec carries test hints, the tests that verify them are
    tagged, and every hint must be verified.
- **Excusals as relations.** Classes in `.surfex.exs` (the trace's `classes:` and
  `rules:`) are scanned as items (`Surfex.Scan.Classes`), and `mix surfex.suggest`
  proposes an `excuses` relation between an item and the class of the first rule it
  matches.
  - Only an item nothing implements is proposed.
  - `require: [code: [:implements, :excuses]]` then means every public item is either
    described or deliberately excused, on record.
  - Rewording a class's reason or changing its rules dangles its excuses.
  - On the reference fixture, the suggested excusals are exactly the trace's verdicts.
  - An excuse its class no longer covers is **stale** and fails the check: the item is
    now implemented, no longer matches a rule, or another class's rule matches it first.
  - Code records now carry the item's kind as `role` and its parent as `within`.
  - The guide has a section on excusing code.
- **Broken citations fail `mix surfex.status`.** A name the spec cites that resolves to
  nothing (a deleted or misspelt function) or to more than one item is reported and fails
  the check, read by `Surfex.Cite` as the trace read it. It was the trace's last check
  the relation log lacked. `Surfex.Status.Config.load/3` scans once for everything status
  needs.
- The status reports count spec units by role (`Surfex.Status.units/1`), and the JSON
  gives each id's role and what it sits in.
- Surfex's own spec now has an anchor on every heading. Its relations moved across and
  the old ones were retired, with their history kept.

### Fixed

- **The JSON status report wrote a missing value as the string `"nil"`.** A gone end's
  hash and location, and a conflicted relation's recorded hashes, reached tools as a hash
  named `nil`. They are now `null`.

- **The markdown scanner read code fences wrongly.** A tilde fence wasn't a fence, and a
  shorter inner fence closed a longer outer one, so a `#` line in a code block could
  become a section and shift the ids and versions after it. Fences now follow
  CommonMark. A spec with neither form scans as before.

- **Two code items sharing a key couldn't be related.** A C scanner's function and
  constant both called `twin` had one id, so the relation log couldn't tell them apart:
  relating either was refused with a misleading message, and status judged whichever came
  last. Their ids now carry their kind (`twin (function)`, `twin (const)`), and status
  raises on two records with one kind and id. Unique keys are unchanged.

## [0.3.0] — 2026-09-28

The relation log. Surfex now records which versions of the spec and the code were
confirmed to belong together, and fails on anything that changed since, by name, on
either side. A **minor** release: a new public API, and every module's and function's
version changes once. The v0.2 trace is deprecated.

### Added

- **Scan records**, the first part of the relation log: `Surfex.Scan` (`{kind, id, hash,
  location}`), a markdown spec scanner that hashes each section's own body
  (`Surfex.Scan.Markdown`), and line ranges on code items (`Surfex.Item` `lines`,
  `Surfex.SourceScan.line_range/1`).
- **The relation log**: `Surfex.Log.Entry` (canonical JSON lines, content-hash ids) and
  `Surfex.Log` (append-only segments in `.surfex/`, verified loading, union merge), with
  `mix surfex.log --init | --break | --verify | --rechain`. Nothing is ever edited or
  removed.
- **Relation status**: `Surfex.Status` derives each relation's state (current, dangling
  with the side that changed, orphaned, conflicted, retired; impacted as a flag), the new
  ids and the ids a `require:` policy leaves unmet. `mix surfex.status [--format json]
  [--verify]` reports it and is the check. Directed relation types (`depends_on`,
  `refines`, `tests`) keep their ends in order.
- **Recording**: `Surfex.Record` and `mix surfex.relate`, `confirm`, `retire`, `resolve` and
  `history`. A relation moves back to current only when someone names it in `confirm`.
- **Suggesting relations**: `Surfex.Suggest` and `mix surfex.suggest [--accept]` propose
  `implements` relations from the spec's existing citations, which is also how a project
  adopts the relation log. `--accept` never confirms a dangling relation.
- **A committed status golden**: `:status` (or `{:status, output}`) in `goldens:` gates
  `RELATIONS.md`, the relation status as a reviewable record.
- **Surfex runs on its own relation log**: `.surfex/` holds 120 relations adopted from
  `spec.md`, every public item must implement a section, `RELATIONS.md` is committed, and
  CI runs `mix surfex.status --verify`.

### Deprecated

- **The trace** (`Surfex.Trace`, `mix surfex.trace`, `:trace` goldens): the relation log
  replaces it. It keeps working until a later release removes it.

### Changed

- The README leads with the relation log.
- **A module's version is its public surface** (`Surfex.SourceScan.module_hash/1`): its
  moduledoc, public definitions, behaviours, `use`s, struct fields and types, not its
  functions' bodies. A function edit no longer dangles its module's relations as well.
  Every module's version moves once with this change.
- `Surfex.SourceScan.project_root/2` takes a starting directory; `/1` is unchanged. Its tests
  had to change the VM-wide working directory, which made the suite fail about once in
  fifteen runs, and a test now keeps async tests from doing that.
- **A function's version covers what it depends on.** It used to hash only the function's
  own clauses, so a change made through a private helper, or a module attribute, went
  unseen. It now also covers every private definition the function calls (transitively,
  including piped calls, captures and default arguments) and the module attributes they
  read, and renaming a variable no longer counts as a change. **Every function's version
  changes once**, with this release; regenerate goldens after upgrading.
- The README is rewritten: shorter, installing from GitHub, with one worked example, and
  `spec.md` for everything else. `spec.md` now ships in the package and the docs.

## [0.2.8] — 2026-09-26

The first release published to GitHub. It fixes a GAP that a shared key could hide.

### Fixed

- **A GAP could be hidden by a key two items share.** `Surfex.Coverage.verdicts/3` kept
  one verdict per key, so when two items shared a key, one item's verdict overwrote the
  other's. A GAP could then vanish from the golden and from the gate. Every item now keeps
  its own verdict, and a failure about an item whose key is shared names its kind.

### Changed

- `Surfex.Coverage.verdicts/3` returns `[{item, verdict}]` in item order, not a map keyed
  by item key. Strictly a breaking change, it is made in a patch release because the
  trace has shipped only in 0.2.0, with no dependent yet, and the map was the defect.
- The package points at its public repository, <https://github.com/dcoai/surfex>: the
  `links` Hex requires, and the docs' source links, pinned to the release's tag.

## [0.2.0] — 2026-09-25

The first release with two-way spec↔code traces. A **minor** release: a whole public API
has been added since 0.1.0.

### Added

- **Two-way spec↔code traces**. A specification's prose already names the code it
  describes, and Surfex now checks both directions. Every name the spec cites must exist,
  and every public module and function must be cited or excused by a class. The result
  is a gated golden, `SPEC_TRACE.md`.
  - `Surfex.Item`, `Surfex.Cite`, `Surfex.Coverage` and `Surfex.Profile`: citations in
    five statuses (resolved, ambiguous, unresolved, external, documented absence) and a
    verdict per item (cited, excused by a class, or GAP), configured entirely by data.
    Subject sections, citing table columns, member paths and alias families
    (`Mod.fun` cites every arity) are general features, not any project's quirks.
  - `Surfex.Scanner`, a language-agnostic scanner contract, and `Surfex.Scanner.Elixir`,
    which reads a project's public API from source without compiling it.
    `Surfex.SourceScan.defs/1` gives a module's public definitions with one content hash
    per function.
  - `Surfex.Trace` and `mix surfex.trace`: a whole trace defined in `.surfex.exs`, with
    every failure (drift, GAPs, broken citations, uncited required sections) reported in
    one run.
  - `Surfex.Surface`, `Surfex.Goldens`, `Surfex.Gate` and `mix surfex.goldens`: a
    project's own goldens, gated alongside the trace with one command.
- `spec.md`, the full specification of Surfex, traced against Surfex's own code in CI.
- The release method: derived patch numbers, this changelog, and a maintainer's
  release guide.

### Fixed

- `Surfex.SourceScan.lib_sources/1` no longer counts test fixtures or the `tmp/` trees
  ExUnit leaves behind as first-party source. A `lib/` counts only when its parent has a
  `mix.exs` and no directory on the way is `deps`, `_build`, `test`, `tmp` or hidden.
  Before, a golden could drift on the machine that had just run the tests, and never in
  CI.

## [0.1.0] — 2026-09-01

### Added

- `Surfex.SourceScan` (read source without compiling it, and version a definition by
  a hash of its structure) and `Surfex.Golden` (the one renderer for surface goldens:
  typed cells, stats lines, order-invariant output, no dates). Extracted from
  agentronic, where ten goldens use them.
