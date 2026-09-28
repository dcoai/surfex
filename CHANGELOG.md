# Changelog

All notable changes to Surfex are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
