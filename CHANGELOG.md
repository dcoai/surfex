# Changelog

All notable changes to Surfex are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
