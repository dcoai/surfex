# Changelog

All notable changes to Surfex are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
