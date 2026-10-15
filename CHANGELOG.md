# Changelog

All notable changes to Surfex are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

`mix.exs` reads `0.9.2-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

Plan v2's B.1 (#205, claim forms) is landing here piece by piece, unreleased until most of
milestone "Claims own their code" is in. So is B.5 (#209), the migration from section grain
to claim grain, with a walkthrough in the new guide "Migrating to claim grain". Claim
grain is now the only reading, and `claim_grain:` is refused (#285, under Changed): every
entry below that says "under `claim_grain: true`" applies to every project.

### Added

- **Rules and paragraphs as claim units** (#205, #234). A claim smaller than a section is a
  unit of its own, role `:rule`, once its author names it (spec §11.1):
  - an id comment of its own line directly before a paragraph or list item,
    `<!-- surfex: no-override -->`, names it `file#no-override`, as does one that starts
    the item or paragraph;
  - `<!-- surfex: rules NAME -->` before a list makes each top-level item a rule, its id
    the item's id comment or what the new `rule_ids:` grammar reads from its text, in the
    forms `heading_ids:` takes (`:section_sign` reads `1. §Tenancy.1.4 …`);
  - a rule's version is its text and nested lines without the list marker or id comment,
    so renumbering a list changes nothing, and it is left out of its section's version;
  - an item of a marked list with no id is an error naming its line, never an ordinal.
    Bold is never read as a claim.

  `require:` takes the `:rule` role, and the status counts rules once a spec names one.
  ex_doc renders the comment of its own line and the rules marker as comments, but shows
  a comment inside a list item as text and lets one starting a paragraph swallow the
  heading after it; §11.1 says which form to use.

  A spec that names no claim scans as before. The one change for an existing spec: an id
  comment of its own line that was an unclosed block's error now names the paragraph or
  item after it, and a list item or paragraph already starting with `<!-- surfex: ID -->`
  becomes a rule, leaving its section's version.

- **Contract fences** (#205, #235, #270, #277). A fenced block after
  `<!-- surfex: contract -->`, or opened as ```` ```elixir contract ````, is one unit of
  role `:contract` per function its `@spec`, `@callback` and `@macrocallback` lines name,
  keyed by the function it states, `file#MyApp.Feed.feed/2`, so changing one signature
  dangles only that function's relations (spec §11.1). An unqualified signature's module
  is, nearest first, the `defmodule M do` around it inside the fence (nested ones join),
  the marker's `module:` option, then the nearest enclosing heading that names one (a
  `subjects:` item, else a module alias alone in backticks), climbing past headings that
  name none (spec §11.9). So two functions of one name in two modules of one file are two
  units. A `@callback` keys apart from a `@spec` of the same name and arity,
  `file#MyApp.Feed.callback:init/1` (`macrocallback:` likewise). The same id in two fences
  of one file, and a signature no module places, stay errors naming the lines. The new
  scan-record field `contract` holds the function, `MyApp.Feed.feed/2`. ex_doc renders the
  marker as a comment, but an `elixir contract` info string swallows the heading after
  it, as `test ID` does.

- **A contract stated differently in several files is listed** (#270, #278). Two contract
  units with the same id after the file (the same `Module.name/arity`, of the same kind)
  in several spec files, at more than one version, are `restated`: the status derives
  `%{contract, units}` for each, the text report lists them, the JSON gives `restated`, and
  the status golden holds a `restated` table and header count, each only where there is
  one. It never fails, with or without `claim_grain:` (spec §13.10). Measured read-only
  over three adopters' specs: 4 restated contracts in one, 1 in another, and none in the
  third until its unplaced fences name their module.

- **Path headings fold into an id'd section, opt-in** (#205, #237). With `fold_paths: true`,
  a heading with no id inside a section that has one is part of that section's unit: its
  text counts in the section's version and its hints, blocks, rules, rows and contracts sit
  in that section (spec §11.1). **Upgrade step, when it becomes the default** (under
  `claim_grain: true` now, for everyone in the release that completes claim grain, #260)
  **wherever `heading_ids:` is set:** a spec that writes ids keeps fewer units, and each
  folded heading's relations move to the id'd section (`mix surfex.suggest --accept`
  carries them as moves), or set `fold_paths: false` to keep path headings as units.
- **List-shaped table keys warn** (#205, #238). A marked table's row whose key reads as a
  list (`1001, 1005 legacy hilite`: it holds `, `, ` / ` or ` and `) is probably two things
  in one row. `Surfex.Status.list_keys/1` lists them, and the status reports them in a list
  of their own (`list_keys` in the JSON), as a warning that never fails (spec §11.2).
- **A project's citation forms** (#205, #236). `unit_refs:` in `.surfex.exs` lists the
  forms a project cites spec units in across files, each a regex with named captures `id`
  and `file` or `chapter` (a spec file's leading number):
  `~r/^§(?<chapter>\d\d)\.(?<id>[\w.]+)$/` makes `§03.4` name `spec/03-wire-format.md#4`
  (spec §11.1). `Surfex.Scan.resolver/2` takes them and `Surfex.Scan.resolve/2` tries them
  first; a test's `verifies:`, `mix surfex.test` and the recording tasks that take a unit
  accept the forms.
- **Several code scanners, combined** (#208, #239). `scanners:` in `.surfex.exs` lists the
  code scanners whose items are combined: `scanners: [:elixir, {MyApp.DslScanner, opts}]`
  keeps every Elixir item and adds a project scanner's (spec §5.3). Each item keeps its own
  scanner's file, lines, hash and kind. One key from two scanners is an error naming both.
  `scanner:` with `scanner_opts:` keeps working as the one-element list, so nothing changes
  for an existing config; giving both `scanner:` and `scanners:` is refused.
  `Surfex.Status.Config.scanners!/1` reads the list.
- **DSL items, as a contract** (#208, #240). A block a DSL declares inside a module (an
  action, a policy) can be an item: a project scanner for the DSL gives it as a
  `Surfex.Item` with the DSL's kind, the declaring module as parent, the DSL's name (key
  `Module.name`), `Surfex.SourceScan.definition_hash/1` over the block, the block's lines,
  the keys it references as calls, and `shape` for a pure declaration (spec §4.1). A DSL
  item carries no hidden definitions and runs no hidden code: its hash covers its block.
  Surfex depends on no DSL; its own tests prove the contract with a fixture DSL and scanner.
- **Calls resolved to DSL items by a scanner** (#208, #241). `Surfex.Scanner` gains an
  optional callback, `calls(call, aliases, opts)`: the test scanner and the Elixir scanner
  ask each of the project's scanners implementing it about every remote call they read
  (a piped call with its piped value as first argument), and add the item keys it answers
  to the caller's calls (spec §5.4). A test driving `MyDsl.run(MyApp.Order, :checkout, …)`
  then reaches the `checkout` item and, through its calls, the code its block references,
  so evidence, the triangle and suggestions work for DSL items. A scanner without the
  callback is never asked, so nothing changes for one; an answer that isn't a list of
  keys raises naming the scanner. `Surfex.Status.Config.call_scanners/1` gives the
  scanners asked, and `Surfex.Scan.ExUnit.records/4` takes them.
- **`Surfex.Scanner` and `Surfex.Item` are supported API** (#150, #208, #240). The
  stability promise of `Surfex.Golden` and `Surfex.SourceScan` now covers them (spec
  §23.1): callbacks and fields keep their names and shapes, additions are optional or have
  a default, and a change comes only in a minor release under "Changed". A test pins both.
- **Reviews through a path no call shows** (#206, #242). `mix surfex.validate TEST UNIT
  --code ID --through HOW --note N` credits named code the test's green run didn't reach,
  with `HOW` saying how the test exercises it (`route GET /settings`, `message {:feed, _}`,
  `js hook Canvas`). The log entry gains an optional `through` field, written only when
  set and only on a reviewed `implements` (spec §12.1, §18.2); a move, a resolve and
  `annotate` keep it, `mix surfex.history` shows it, and `Surfex.Status.through_count/1`
  counts such reviews in the status text, JSON and, when there are any, `RELATIONS.md`.
  The triangle counts the named code as exercised. Without `--through`, an unreached
  `--code` is still an error. The guide and `mix surfex.info validation` say that code
  relates to the claim it realises, and how to record that by hand. Every existing entry
  keeps its line and id; a log holding a `through` entry needs this version to read it.
- **Routes, LiveView events and messages are a test's calls** (#206, #243). A test's
  `live(conn, "/carts/1")`, `get/post/put/patch/delete(conn, PATH)` and
  `live_isolated(conn, Module)` resolve through the project's router, read from source,
  to the LiveView (`mount/3`, `handle_params/3`) or the controller action; an event
  (`render_click`, `render_submit`, … given the view or an element or form of it) to the
  mounted view's `handle_event/3`; and `GenServer.call/cast(Module, msg)` to
  `Module.handle_call/3` or `handle_cast/2` (spec §11.3). The router is found from the
  endpoint, or named with the new `router:` key (`false` turns it off). Literal paths and
  `~p` paths with interpolated segments, matched against the route patterns in order.
  `Surfex.Scan.ExUnit.records/5` and `tests/5` take the routes,
  `Surfex.Status.Config.routes/2` gives them, and `Surfex.SourceScan.Calls.of/4` asks a
  reader about each whole body. Only test records change: no code version moves. On
  upgrade a Phoenix project's tests reach more code, so `mix surfex.suggest` proposes more
  `tests` relations and the triangle reports fewer gaps; nothing that held stops holding.
- **A claim's implements suggested from its tests, opt-in** (#206, #244). With
  `claim_implements: true` in `.surfex.exs`, `mix surfex.suggest` proposes `implements`
  between each claim (block, test hint, row, rule, contract) and the scanned code its
  verifying tests call directly; a hidden callback a route or message names proposes its
  module. Code reached only through a called function is one `reached … through X: N more
  items` line per claim and entry, never a list (`reached` in `Surfex.Suggest.all/6`'s
  result; new `Surfex.Scan.reacher/1`). A claim with no verifying test, and a section, get
  nothing: the filter is the direct-call rule, decided at evaluation, with no section pool
  (spec §15.1). **Upgrade step, when it becomes the default (with the release that
  completes claim grain):** `suggest --accept` will then record these as proposed
  `implements`, which fail the check until validated; until then nothing changes unless
  a project sets it.
- **Checks: gates that verify claims** (#207, #245). Some claims are verified by a tool,
  not a test: a lint rule, a security scanner, a project's own verification task.
  `checks:` in `.surfex.exs` declares each as `[id:, run:, verifies:, inputs:]`: a
  command that can fail, the spec units it verifies (`TABLE/*` for a table's every row,
  and `unit_refs:` forms), and the files it inspects (spec §11.4). A check is a scan
  record of the new kind `:check` (`Surfex.Scan.Checks`), versioned over its declaration
  and its inputs' content; the log's `verifies` now runs from a test or a check, and a
  `red_green` observation may be a check's (spec §12.1). `mix surfex.check [ID…]` runs
  them and records each result as evidence in the test formatter's file (`Surfex.Check`).
  A check discriminates as a test does, failing against one set of inputs and passing
  against another, and then `mix surfex.confirm --evidence` confirms its `verifies`; one
  that never failed is validated only by `mix surfex.validate CHECK UNIT --note`, the note
  saying what it would catch (spec §17.1, §18.3). CI's `--evidence` check covers
  check-confirmed claims, so a check CI doesn't run reads as not run. Checks are
  suggested, listed as unrecorded and undeclared as tests are, close the triangle for the
  code in their inputs, count in completeness, and are listed in the status text, its JSON
  (`checks`) and `RELATIONS.md`. `mix surfex.test UNIT` names the checks verifying a unit,
  and runs them with `--checks`. A project with no `checks:` scans and reports as before.
- **Inert verifies tags are reported** (#207, #246). A `verifies` declaration counts only
  from the test or property block it applies to, or from a check (spec §11.5, §17.2). A
  tag that applies to none (a `@tag` no test follows, a `@moduletag` or `@describetag`
  over a module or describe with no test, any `verifies` tag under `test/support/`) is
  listed as **inert** (`Surfex.Scan.ExUnit.inert/2`; `inert` in the JSON and, where there
  are any, in `RELATIONS.md`), so a misplaced tag is visible rather than silently ignored.
  It never fails the check, and nothing it names was ever credited by it.
- **`validate` names the arities one review credits** (#209, #249). A function with
  default arguments is one definition under several arities (`put/3` and `put/4`), so a
  review of either credits both under one note. `mix surfex.validate` now says so after
  recording, naming them (`Surfex.Record.shared_definitions/2`, spec §18.4), so the note is
  written for the definition rather than for the arity the test calls.
- **A project's own declaration forms** (#209, #250). `declares:` in `.surfex.exs` names
  other forms the test scanner reads as `verifies` declarations, for a project that
  already records them: `[verifies: [{:tag, :validates, strip: ~r/@[0-9a-f]+$/}]]` reads
  `@tag validates: ["Engine.15.2@abc123"]` (at any tag level) as declaring `Engine.15.2`,
  and `{:attribute, :validates}` reads `@validates [...]` before a test (spec §11.6). The
  ids resolve through `unit_refs:` and are suggested and confirmed as any declaration; they
  are counted unselectable by `mix test --only`, and `mix surfex.test` selects them. Opt-in:
  without the key nothing changes.
- **`mix surfex.migrate`: section grain to claim grain, one section at a time** (#209,
  #251). For a section, each live `implements` between code and it (or a table in it) is
  listed with the claims inside that could own the code (`Surfex.Migrate.proposals/3`,
  spec §14.1): a row whose key names it (an arity-less key `Mod.fun` names every arity), a
  contract unit for it, a claim whose verifying test calls it, or, failing those, one whose
  test reaches it, naming through what. Arities of one definition are one proposal. Code no
  claim owns is listed first, several candidates are listed and never decided. `--within
  PREFIX` takes every section under a prefix. `--report` says what migrating buys: per
  section, the relations an edit dangles now and after, the marking a prose section needs
  first (one marker line re-versions the section), and each code item's dangle width; with
  no section, every section worst first and the population split into sections whose
  claims are already units and prose ones (`Surfex.Migrate.report/3`). Read-only.
- **Migrating: a section moves over several commits, green** (#209, #252). `mix
  surfex.migrate SECTION --accept` records each single proposal as an `implements` to its
  claim, proposed, with the new entry field `migrates` naming the section (spec §12.1,
  §14.1). Such a relation doesn't fail the status while the section still holds its own,
  and the status lists it as **migrating** (text, JSON `migrating` and each relation's
  `migrates`, `RELATIONS.md`). Once the claim's relation is validated the pair is settled,
  and `--accept` or `mix surfex.suggest --accept` (a new `migrated` suggestion) retires the
  section's relation, noting the claim: a section never loses a relation before its claim
  holds one. `--code ID --to CLAIM` records a reviewer's choice. Additive: an entry without
  `migrates` keeps its line and id, and nothing changes for a project that doesn't migrate.
- **A baseline carried to the claim** (#209, #253). A section relation resting on the
  baseline (§18.1) migrates to a claim whose verifying test is the same baselined test, at
  the trusted version, exercising the code: the claim relation keeps basis `baseline`,
  holds at once, and the section's retires in the same `--accept` (spec §14.1). A project
  that baselined at section grain starts its migration from that baseline instead of
  redoing it. Any other claim relation is proposed, as before.

  Measured read-only over the volunteer projects before release (#145, #254): of 526
  sections holding section-grain `implements` in five relation logs, 121 (750 `implements`)
  already have their claims as units and migrate today; in the two projects that have
  them, what an edit of a section can dangle falls from 1,128 relations to 413, and in the
  widest section the widest code item from 81 to 6. The other 405 sections (2,698
  `implements`) are prose: their first marker would dangle up to 153 relations at once,
  which the report counts. An import through `declares:` read 2,370 declarations on 1,237
  tests in one project's own tag form, every one of its 257 ids resolving.

- **Verdicts: what verified means for each spec unit** (#256, #258). Plan item C.1 starts
  here. A unit's own text is its body without the finer units inside it: a **claim** has
  some (a section or block with prose of its own, and every hint, rule, row and contract),
  a **container** has none (a heading over subsections, a section whose body is only named
  claims, a marked table). `Surfex.Status.derive/4` gives every unit one verdict
  (`verdicts`, `Surfex.Status.verdict/2`): `:verified` (a current `verifies` of its own),
  `:contained` (none of its own, but a claim inside it is verified: its own text isn't),
  `:unverified`, or `:through_claims` for a container, with how many of its claims are
  verified (spec §13.4). No credit moves up to the claims inside a verified unit, and none
  into a unit's own text. The status lists the **contained** claims and each `verifies`
  aimed at a container (**on a container**: it verifies nothing), counts claims by verdict
  (`claims: N · verified · contained · unverified · containers`), and gives `verdicts`,
  `contained`, `on_container` and `containers` in the JSON. A section now records the
  section whose heading it sits under (scan-record field `under`). Additive: nothing new
  fails. **Upgrade step:** `RELATIONS.md` gains a claims line among its stats, and
  `contained` and `on container` tables where there are any, so run `mix surfex.goldens
  --write` once.

- **Earning: the one definition of an earned `implements`** (#256, #259).
  `Surfex.Status.earning/2` says whether an `implements` earns, and why not:
  `Surfex.Status.earned?/2` is its yes or no (spec §13.5). Code earns its relation to a
  `:verified` unit, or to a container or `:contained` unit through a verified claim inside
  it whose verifying test reaches the code (directly, through what it calls, or by another
  arity of the same definition), holds a `tests` relation to it, or whose verifying check
  inspects its file; a current `--through` review counts too. Otherwise it is unearned:
  `unverified`, `not_exercised` or `nothing_inside`. A section's own tag gives the claims
  inside it nothing. Additive: nothing reads it yet. B.3's unearned rule (#247) will fail
  `require: [code: [:implements]]` through it, in the same release.

- **Spec rules judge claims, and name a contained one** (#256, #260). A `require:` rule on
  a spec role (`section:`, …) or on the kind `spec:` no longer judges a container (a
  heading over subsections, a section whose body is only named claims, a marked table):
  its claims answer under their own roles (spec §13.2, §13.4). A `:contained` claim a
  `verifies` rule fails is unmet and says why (`why: :contained`; the report line ends
  `contained: a unit inside it is verified, its own text isn't`; the JSON's `why`; the
  golden's `(contained)`). `require: [spec: [:verifies]]` is the one-line policy that every
  claim is verified. Relief only: a container that was unmet no longer is, and nothing
  that was met becomes unmet.
- **`claim_grain: true`, the one switch for claim grain's breaking parts** (#256, #260).
  Until the release that completes claim grain, every part of it that changes what an
  existing project's check reports is read only under `claim_grain: true` in
  `.surfex.exs` (`Surfex.Status.Config.claim_grain?/1`, spec §13.2); that release makes
  it the only reading and refuses the key. What it changes so far: path headings fold by
  default wherever the spec writes ids (`heading_ids:` set and no `fold_paths:`, spec
  §11.1); `fold_paths: false` keeps them units; and completeness counts own text (#261,
  below). Coming under the same key: spec-unit classes (C.2, #257) and unearned
  `implements` (#247).

- **Completeness counts own text, under `claim_grain: true`** (#256, #261). A claim is
  complete only with a validated `verifies` of its own; one inside it no longer completes
  it (spec §20.1). A contained claim misses `contained (<unit>, …)`, naming the verified
  claims inside it, in the text, JSON and `COMPLETENESS.md`; containers, marked tables
  among them, aren't counted. Without the key completeness reads as before. **Upgrade
  step, when the key is set (and for everyone in the release that completes claim
  grain):** scores drop by the contained claims, so `completeness: [min: N]` can fail.
  `mix surfex.completeness --format json` lists each one with the verified claims inside
  it: add the claim to the tag of a test that really checks its prose, name the prose's
  claims (spec §11.1) and migrate them (`mix surfex.migrate`), or class the prose as
  asserting nothing (C.2, #257). Surfex's own spec has 49 contained sections: 79.7% of its
  spec units are complete under the key, against 100% without it, and settling them is
  its own upgrade (#263).

- **Guides for containment** (#256, #262). "Writing specs" says a section's prose is a
  claim: name its claims, verify it, or (with spec-unit classes) class it, and that
  `require: [spec: [:verifies]]` never asks a container for a tag (spec §16).
  `mix surfex.info claims` explains the verdicts and earning, and the status, completeness
  and config pages the new lists, the `contained` reason and `claim_grain: true`.

  Measured read-only over the volunteer projects before release (#145, #262), six relation
  logs including surfex's own: of 3,788 live `implements`, 969 end at a contained claim and
  28 at a container. Under the earn rule 18 of them, in one project, are `not_exercised`
  and 2 more, in another, end at a container no claim inside exercises; every other one
  earns. Completeness under `claim_grain: true` moves only in the three projects that tag
  hints rather than sections (spec units 100% to 79.7%, 56.5% to 46.4%, 79.0% to 60.9%);
  the three that tag sections are unchanged. `require: [section: [:verifies]]` stops
  failing on containers: unmet sections fall from 20 to 15, 68 to 48, 5 to 4 and 159 to
  153, and stay at 75 in the project whose sections need classes (C.2). Folding by
  default under the key changes one measured spec, 1,389 sections to 1,178 (211 path
  headings folded into their id'd sections), and three others by 0 to 3.

- **Spec-unit classes and deferrals: the markers and patterns** (#257, #264). Plan item C.2
  gives spec text the excusal code has. `spec_classes:` in `.surfex.exs` declares the
  project's classes, each a name and a reason, selected by surfex's own marker
  `<!-- surfex: class NAME[: REASON] -->` in a section, by a `files:` or `headings:`
  pattern, or by a project's existing comment through `marker:` (an alias). A unit waiting
  on an issue is deferred, `<!-- surfex: deferred #123[: REASON] -->`, in a section or a
  marked block. Both markers are own-line comments that ex_doc renders as nothing, and they
  sit outside every unit's version, so adding one dangles nothing. The scan records carry
  `class` and `deferred` (spec §11.7). A class marker in a block or rule, an undeclared
  class, two markers in one unit, a deferral without an issue and a marker under a folded
  heading are errors naming the line; `spec_classes:` refuses a glob that matches no spec
  file. Nothing in the status reads them yet: what a class excuses arrives with #265,
  under `claim_grain: true`.

  The one change for an existing spec: an own-line comment a declared `marker:` alias reads
  leaves its section's text, so that section's version changes once.

- **Excused and deferred units in the status, under `claim_grain: true`** (#257, #265).
  The status always lists `excused` (each classed unit, its class, reasons, how it was
  selected and the claims inside it) and `deferred` (each deferred unit, its reference and
  reason), in text as one header line and in JSON. Under `claim_grain: true` it reads
  them (spec §13.6): a classed section with no claim inside is `:excused`, a deferred unit
  `:deferred`, and with claims inside either is a container. A class excuses a section's
  own text, never a named claim inside it: every rule, row, hint, contract, block and
  subsection inside stays a claim. `require:` spec rules and the triangle skip excused and
  deferred units, and an `implements` to one earns nothing (`unverified`). A live
  `verifies` to a classed section, an `implements` to an excused one, or a declaration
  naming a classed section is **contradicted**, and fails. `mix surfex.suggest` proposes no
  `implements` from a classed section's citations and no `verifies` to a classed unit
  (§15.2), and completeness leaves excused and deferred units out of the spec score,
  counting them on lines of their own (§20.2). **Upgrade step, under `claim_grain: true`
  now and for everyone in the release that completes claim grain:** classing a section
  your log relates to contradicts those relations; retire the ones that were narration,
  or don't class the section.

- **Deferrals go stale: `issues:` and `mix surfex.status --issues`** (#257, #266). A
  deferral holds while its issue is open and its unit isn't built (spec §13.7). Under
  `claim_grain: true` the status lists and fails on each **stale deferral**: `built` (the
  unit has its own `verifies` now), `closed` (its issue is closed) or `unresolved` (the
  tracker couldn't say). Issue state is an input, never stored: `issues:` in `.surfex.exs`
  declares the project's own command (`[command: argv, state: key, project: name]`, with
  `{ref}`, `{n}` and `{project}` substituted, run with no shell), `Surfex.Issues.states/3`
  runs it once per reference, and `mix surfex.status --issues` passes the answer to
  `Surfex.Status.derive/4` as `issues:`. A command that exits non-zero stops the task with
  its output. Without `--issues` nothing runs and only `built` is judged. `.surfex.exs`
  takes the new keys `spec_classes` and `issues` (§13.2).

- **Excusals in the record, the guide and the measurement** (#257, #267). `RELATIONS.md`
  gains `excused` and `deferred` tables keyed by unit (and `contradicted` and `stale
  deferrals` when any), with their counts in the header, and `COMPLETENESS.md`'s header
  counts the units excused by class and deferred (spec §13.8). Both appear only where a
  spec has a class or deferral, so other goldens render as before. "Writing specs" gains
  "Text the spec doesn't verify" (§16.1): class prose that asserts nothing, name the real
  claims inside it first, verify tool-checked rules with a check, defer what waits on an
  issue. `mix surfex.info claims`, `status`, `config` and `completeness` say the same.

  Measured read-only over the volunteer projects before release (#145, #267), classes
  added in memory only. In the two relation logs measured with patterns or their own
  unrelated-section lists, `require: [section: [:verifies]]` unmet sections fall from 75
  to 35 and from 48 to 9, and spec completeness under `claim_grain: true` rises from 46.4%
  to 62.5% and from 84.5% to 96.4%. Classing by pattern contradicts existing relations
  where a classed section holds real claims: 5 relations to one decision record in one
  project, 4 to one principles section in another; those are the relations to
  re-home or the sections not to class. Across the specs without a log, an existing
  informative comment read through `marker:` classes 200 sections (31 of them over
  subsections, 185, that stay claims) and changes those 200 sections' versions once, and
  file patterns class 49 to 210 sections per project, none of them over a named rule yet:
  a chapter whose MUSTs aren't named as rules is excused whole, so name them first.

  **Upgrade step, under `claim_grain: true` now and for everyone in the release that
  completes claim grain:** declare `spec_classes:`; class descriptive sections by pattern
  or marker (or point `marker:` at a comment you already write); name the real claims in
  any section you class by pattern; defer what waits on an issue with
  `<!-- surfex: deferred #N -->`; settle each contradicted relation, usually by retiring
  narration; and add `issues:` and `mix surfex.status --issues` where your tracker can be
  asked.

- **Unearned: an `implements` counts for `require: code:` only when it earns, under
  `claim_grain: true`** (#207, #247). B.3's guard against claims written only to own code
  (spec §13.9). The status lists every live `implements` that doesn't earn (§13.5,
  `Surfex.Status.earning/2`) as `unearned`, with its code, spec unit and why
  (`unverified`, `not_exercised`, `nothing_inside`), in text with a count in the header,
  in JSON (`unearned`) and as a `RELATIONS.md` table with a header count. An unearned
  relation meets no `require:` rule: code whose only `implements` are unearned is unmet,
  `why: :unearned`, and where the policy is `require: [code: [:implements]]` every
  unearned relation fails the status, a spare one beside an earning one included.
  Credit never flows up from an enclosing unit: code earns through a verified unit, or a
  verified claim inside it whose test or check exercises the code. Completeness reads code
  the same way (§20.3): code whose `implements` all earn nothing misses `unearned`.
  Without `claim_grain:` nothing changes and no list, count or table appears.

  Measured read-only over the adopters with a relation log before release (#145, #247),
  under `claim_grain: true` with each project's own `require:`: 18 relations unearned in
  one project, all `not_exercised`, against 4 sections (18 code items newly unmet, 17
  incomplete), 2 in another (1 code item unmet), and 0 in the six others.

  **Upgrade step, under `claim_grain: true` now and for everyone in the release that
  completes claim grain:** run `mix surfex.status` and settle each unearned relation by
  its why. `not_exercised`: the code belongs to another claim, or the claim inside that
  covers it has no test reaching it; `mix surfex.migrate --report` shows where it goes.
  `unverified`: add a test or check that verifies the unit, or retire the relation.
  `nothing_inside`: relate the code to a claim, not the empty container. Regenerate
  `RELATIONS.md` (`mix surfex.goldens --write`), which gains an `unearned` count.

- **Surfex checks itself under claim grain** (#256, #263). Its own `.surfex.exs` sets
  `claim_grain: true`, with `completeness: [min: 100]` and `require: code:` unchanged. The
  switch left 58 of its sections `contained` (completeness 95.2%), each settled on its
  own: 57 are now verified by tests that check their own prose, tagged with the section
  beside the hint they already verified (270 `verifies`, each recorded on its test's red
  run or reviewed one by one), and one, a single sentence naming a module over the claims
  below it, is classed `informative` through `spec_classes:`, its one `implements` moved
  to the hint inside with `mix surfex.migrate`. Nothing was renamed or removed from the
  spec. This is the upgrade step of §20.1 done on a spec of 267 claims, as a reference
  for the work it asks.

- **`mix surfex.migrate --report` is the migration's one work list** (#269, #280), as
  #256 promised. Each **contained** section (no `verifies` of its own while a claim inside
  it is verified, spec §13.4) gets a `contained:` line naming the verified claims inside
  it, and with no section named the report covers every contained section, including
  those holding no `implements`, which it used to leave out; the population counts them
  (spec §14.2). `--format json` gives the same report for tools
  (`Surfex.Migrate.json/1`; refused without `--report`). `Surfex.Migrate.report/4` takes
  `Surfex.Status.derive/4`'s options, and the task passes the project's `claim_grain:` and
  classes, so what reads as contained is what the status says.

  Measured read-only over eight adopters with a relation log, under `claim_grain: true`:
  the report now lists 2 to 120 contained sections per project (220 in all), of which 85
  hold no `implements` and were missing from it before; one project's report went from no
  sections to 11. Surfex's own lists none, its contained sections settled under #263.

  **Upgrade step:** none; the text report gains lines, never loses any. A tool reading the
  report's population as two kinds should expect a third key, `contained`.

- **A declared dispatch function reaches the handlers its table lists** (#272, #281). Code
  that runs its handlers through a table (`apply(module, fun, args)` from a map of
  operations) reached no handler from a test driving it, so each handler earned only
  through a unit test calling it or a `--through` review per relation. `dispatch:
  [{MyApp.Ops, :run, 3}]` in `.surfex.exs` declares the dispatcher once (spec §11.10):
  - its module's literal entries, `{Module, :fun}` (every arity defined),
    `{Module, :fun, arity}` and `&Module.fun/arity`, inside module attributes, map
    literals and keyword literals, are its targets, read from source, never traced;
  - a call naming the dispatcher, in a definition or a test, also calls each target and
    names its module, so reach, the triangle, evidence and earning follow;
  - a scanner's `calls/3` answer for a call takes precedence over the table;
  - the status lists each dispatcher with its targets and the entries naming unscanned
    code (text, JSON `dispatch`, and a `dispatch` table and `dispatchers` count in
    `RELATIONS.md`), only where `dispatch:` declares one. A dispatcher whose module lists
    no literal entry is unresolved: reported, never failing. A malformed `dispatch:`, an
    undefined dispatcher, one in a `@moduledoc false` module, or the key without the Elixir
    scanner is refused.

  Measured read-only on one adopter whose S3-style API dispatches 56 handlers through one
  table: the table reads whole (56 targets, none unscanned), and test→handler reach grows
  from 59 to 166 pairs. Its 2 `not_exercised` implements stay: their verifying HTTP tests
  reach the endpoint module, but the endpoint plugs its pipeline (`plug Pipeline`), which
  is no call, so they never reach the dispatcher (proposal #282).

- **Lines a project declares are not claims** (#273, #283). Under claim grain everything in
  a section that isn't a finer unit is its own text, so a provenance line kept a section
  contained for good, and classing the section would excuse any sentence added to it later.
  `not_claims: [~r/^Legacy reference: \S+$/]` in `.surfex.exs` (spec §13.12):
  - each non-blank line of a section's or marked block's own text is matched as written
    against the patterns, and a matched line is left out of what the verdicts (§13.4) and
    completeness (§20) read (`Surfex.Scan.Markdown.claimless?/1`). Versions still cover
    every line, so editing one still dangles;
  - a section left with only matched lines is a container; a sentence no pattern matches
    makes it a claim again. A paragraph naming code is not left out by rule: a project
    that wants that writes a pattern;
  - the scan records what each unit's lines matched (`Surfex.Scan` field `not_claims`),
    and the status lists each pattern with its lines and units, `0` for one matching
    nothing (derive `not_claims`, text, JSON, and a `not claims` table in `RELATIONS.md`),
    only where the key is set. A `not_claims:` that isn't a list of regexes is refused.

  **Upgrade step:** none; without the key nothing changes. Measured read-only on the
  adopter that asked for it: a pattern on its provenance prefix matches 26 lines in 26
  sections, and none becomes a container yet, because each still has other own text (120
  contained before and after). 12 of those lines carry behaviour on the same line as the
  reference, so a pattern on the prefix alone would leave behaviour out: anchor it to the
  whole line (14 lines are the reference alone) and keep the reference on a line of its own.

- **A deferral may cite the spec unit that records the decision** (#274, #284). Some
  deferrals are spec decisions ("deferred past v1", with the reason in a decision table),
  not tracked work, and forcing an issue for them only satisfied the marker.
  `<!-- surfex: deferred UNIT[@VERSION][: REASON] -->` (spec §13.13) cites a spec unit in
  any form a declaration may name one, `unit_refs:` forms included:
  - it is resolved when the spec is scanned (`Surfex.Scan.Markdown.records/4`, given
    `unit_refs:`), and one citing no unit or several raises naming the file and line;
  - `@VERSION` pins the cited unit's 8-hex version. Under `claim_grain: true` the
    deferral is stale as `changed` when the unit's version differs (its decision text was
    edited), `unpinned` with no pin, `gone` without the unit, and `built` as before. The
    report names the version to write and the marker's line; JSON `stale_deferrals` carry
    `pin`, `version` and `line`, and `deferred` carry `cites` and `pin`, for citations only;
  - the scan records `%{ref, reason, cites, pin, line}` (`Surfex.Scan` field `deferred`).
    Issue deferrals are unchanged, and `--issues` asks only issue references.

  A pin rather than staleness on disappearance alone: nothing is stored for a deferral, so
  what its author judged lives in the marker, and only a pin makes an edit to the decision
  text re-open the deferral. No tracker is needed, so it is judged offline and in every CI
  job. A reference that isn't an issue was refused before, so no existing spec reads
  differently.

  **Upgrade step:** none; no adopter writes a deferral marker yet. Measured read-only on
  the adopter that asked, with the marker added to a scratch copy: citing its deferred
  table resolves only once the cited file is in `sources:` (its `.surfex.exs` scans one
  chapter); unpinned it is one stale deferral, pinned none, and an edit to any row of the
  unmarked table makes it `changed`, since the table is its section's own text.

- **`Surfex.Item` gains a `dispatch` field** (#272, #281), for scanner authors: on a
  module item, the dispatch functions declared in it with what each one's table lists
  (spec §4, §11.10). It defaults to `%{}`, so a project scanner's items are unchanged.

- **A deviation holds back the `implements` it says the code doesn't meet** (#255, #279).
  `mix surfex.confirm --evidence` no longer validates an `implements`, dangling or
  proposed, whose spec unit is deviating or holds a deviating unit at any depth (spec
  §13.11): a module that fails one of its section's requirements doesn't implement the
  section, however green its other tests are. Each the evidence would have validated is
  listed as `held back by a deviation: implements code … ↔ spec … (deviates: #119)`; once
  the tag goes and the test passes, the next evidence run validates it. A deviation test's
  failing run still records its `verifies`. `Surfex.Status.derive/4` gives `held` (each
  held unit with its references), which also marks a proposed relation `deviates`, and
  `Surfex.Record.evidence_outcome/4` returns the held list beside the entries. Under
  `claim_grain: true` a section a deviating one sits under is held too, and
  `Surfex.Status.earning/2` answers `{:unearned, :deviates}` for an `implements` to a held
  unit, asked first, so `unearned`, `require: code:` and completeness agree with confirm.
  No new option; `deviations: :fail` is unchanged.

  Measured read-only over the adopters before release: only one tags deviations, and none
  are left at its head. At the commit that tagged them (23 deviating units, 4 references)
  17 proposed `implements` would have been held back (19 under claim grain, plus one
  validated relation now unearned as `deviates`, 11 code items unmet); a later commit
  with 5 deviating units held 3 (4). Those are the relations that project withdrew by hand
  after each evidence run.

  **Upgrade step:** none for a project without deviation tags. With them, expect
  `mix surfex.confirm --evidence` to list held relations instead of recording them;
  stop withdrawing them by hand. Under `claim_grain: true`, an `implements` to a held unit
  is unearned as `deviates` until the fix lands.

### Changed

- **Breaking: claim grain is the only reading, and `claim_grain:` is refused** (#285, for
  #145). Every part of claim grain that shipped behind the transitional key now applies
  to every project, and a `.surfex.exs` that sets `claim_grain:`, `true` or `false`,
  raises: the message names the key, says claim grain is now the only reading, and points
  to this step and `mix surfex.migrate --report` (spec §13.2). A config that only drops
  the key reads as before. For a project that never set it, what changes:
  - **contained sections**: a claim is complete only with its own evidence, so a section
    verified only through a claim inside it misses `contained` in completeness, and
    containers (marked tables among them) are no longer counted (spec §20.1);
  - **earning**: an `implements` that earns nothing is listed as unearned and meets no
    `require: code:` rule; where `require: [code: [:implements]]` is set it fails, and
    code with no earning `implements` is unmet (`why: :unearned`) and misses `unearned`
    in completeness (spec §13.9, §20.3). The text header always counts them;
  - **classes and deferrals** are read: an excused or deferred unit isn't judged by
    `require:` spec rules or counted in completeness, a relation to an excused section is
    contradicted, and a deferral that no longer holds is stale; both fail (spec §13.6,
    §13.7, §13.13, §20.2), and `mix surfex.suggest` proposes nothing from a classed
    section's own text (spec §15.2);
  - **deviations** hold back the sections a deviating unit sits under, for
    `confirm --evidence` and for earning (spec §13.11);
  - **path headings fold** under an id'd heading wherever `heading_ids:` is set and
    `fold_paths:` isn't (spec §11.1).

  Library API: `Surfex.Status.Config.claim_grain?/1` is removed; `Surfex.Status.derive/4`
  no longer reads a `claim_grain:` option and its `policy` no longer holds one;
  `Surfex.Record.evidence_outcome/4` no longer reads `claim_grain:` from its meta;
  `Surfex.Suggest.all/6` no longer takes `classes:`. Each such option is ignored.

  Measured read-only over the 9 projects with a `.surfex.exs` and a relation log, each at
  its committed head, with this checkout's code against their files (nothing written in
  any of them). Before is each project's own config as it stands, after is the same
  config read now:
  - failing projects: 2 before, 4 after. Status failures per project, before → after:
    0 → 0 in five, 0 → 36 and 0 → 3 in two (unearned relations and the code they leave
    unmet), and unchanged in the two that already failed (their failures are proposed
    and dangling relations, read the same either way);
  - unearned `implements`: 18 and 2 in two projects, 0 in seven;
  - contained sections: 2 to 120 per project, 223 in all (listed before too); spec
    completeness falls in four projects, by 3.7 to 18.1 points, and holds in five;
  - none declares spec classes or deferrals yet, so nothing is excused, deferred,
    contradicted or stale.

  **Upgrade step (breaking):** delete `claim_grain:` from `.surfex.exs` if it is there,
  then run `mix surfex.status` and `mix surfex.migrate --report`. Settle each unearned
  relation by its why (the #247 entry above); settle each contained section by tagging it
  on a test that checks its own prose, by naming its claims and migrating
  (`mix surfex.migrate`), or by classing prose that asserts nothing (`spec_classes:`). A
  `completeness: [min: N]` floor can fail until then. Regenerate the goldens
  (`mix surfex.goldens --write`): `RELATIONS.md` gains its `unearned` count and
  `COMPLETENESS.md` its new scores. A library caller drops `claim_grain:` and `classes:`.

### Fixed

- **`mix surfex.suggest` agrees in number** (#269, #280): a settled migration moved to one
  claim reads `(moved to X, which holds it now)`; to several, `which hold it now`.

- **A contract signature ends where its text parses, not at its indentation** (#271,
  #276). B.1's contract fences ended a signature at the first line not indented deeper
  than its head, so a multi-line type whose closing `}`, `)`, `]` or `>>` came back to
  the head's column was cut one line early and reported as a signature that doesn't
  parse. A signature now takes the next lines while its text doesn't parse, whatever
  their indentation, then the lines indented under it, and stops at the next `@spec`,
  `@callback`, `@macrocallback`, `@type`, `@typep` or `@opaque` line or the fence's end
  (spec §11.8). A sketch that never parses, such as `%{id:, …}`, is still an error naming
  its line. Nothing changes for a fence that read before.

## [0.9.1] — 2026-10-14

What surfex writes now reads right. Spec pages published with ex_doc keep their headings
and hide their markers, given the `test:ID` hint form and a heading id on the next line
(#195). Golden cells holding `|` or a backtick render as one cell (#199), and a hand-edited
golden row is reported by the column that changed (#215). `mix surfex.completeness
--summary` prints just the scores for a gate step (#216). One upgrade step, for goldens
with such cells: regenerate them.

### Added

- **Spec forms ex_doc renders** (#195, #228). ex_doc's markdown (EarmarkParser) shows a
  heading's id comment and anchor as heading text, and renders a ```` ```test ID ```` hint,
  whose info string holds a space, as a line of text that swallows the heading after it.
  Two spellings it renders cleanly are now read as well:
  - a test hint whose info string is `test:ID`, ```` ```test:totals-counts ````, read
    exactly as `test ID` is, with the same id and version;
  - a heading's id comment on the line after it, `## Totals` then `<!-- surfex: totals -->`.
    That line is also a block's opening marker, and it still opens a block wherever a
    `<!-- /surfex -->` closes it before the next marker or heading. It is the heading's id
    only where it used to be an error (a block never closed, spanning a heading or opening
    inside itself), so no spec that scanned before changes meaning. A heading with an id
    on both lines is an error.

  Switching a spec to them changes no id and no version: surfex's own spec moved every
  anchor and hint across with its relation log untouched. Spec §11 now says which forms
  each renderer shows, and a test renders each one through ex_doc so it stays true.
- **`mix surfex.completeness --summary`** (#216, #233). It prints the score lines only,
  overall and per kind, and still fails below `completeness: [min: N]` with the same
  message. A gate step that enforces the floor no longer prints every incomplete item,
  which `goldens: [:completeness]` already commits as `COMPLETENESS.md`. Without the flag
  the output is unchanged. `Surfex.Completeness.summary/1` renders the lines.

### Fixed

- **The claim that heading id comments suit ex_doc** (#195). 0.7.0 said an id comment at
  the end of a heading "doesn't render, so it suits ex_doc extras". It renders as heading
  text there and leaks into the anchor link. Put it on the line after the heading.
- **surfex's own published spec and guides** (#195, #228) lost a heading after every test
  hint and showed every anchor as text on hexdocs. They use the forms ex_doc renders.
- **Golden cells holding `|` or a backtick** (#199, #229). `Surfex.Golden` wrapped every
  `:code`, `:atom`, `:locus` and `:version` cell in single backticks with nothing escaped.
  Under GFM, which is how GitLab and GitHub render a golden, a `|` split the cell even
  inside the span (an extra column, the rest of the row shifted), and a backtick closed the
  span early or left it open. The golden stayed byte-stable, so its gate passed; it was
  only wrong when read. Every backticked cell is now a code span that reads back as its
  text: `|` is escaped as `\|`, the delimiter is one backtick longer than the longest
  backtick run in the text, and the text is padded with a space when it starts or ends
  with a backtick, or starts and ends with a space. No API changes. The status golden
  (`RELATIONS.md`) builds its composite cells by the same rule and escapes `|` in their
  free text, so an id that holds a pipe (an operator such as `|>`, a test name) or a
  backtick keeps its row whole, and the gate's drift report names such an item by its
  text. A `{:raw, …}` or plain-string cell is still written verbatim: a caller composing
  one escapes it.

  **Upgrade step:** a golden changes only where a backticked cell holds `|` or a backtick
  (or, in the status golden, a note or reference holds `|`);
  run its `--write` task (`mix surfex.goldens --write` for the status and completeness
  goldens) once after upgrading, and commit what changes. Those rows were rendering wrong.
- **A hand-edited row read as a prose change** (#215, #231). The gate's drift report keyed
  each row by its first cell (`Item`, else the first column) and kept one row per key, so in
  the status golden, where many rows share an `End`, a row was hidden behind its neighbour,
  and editing its state by hand was reported as "No row changed: the prose or a stats line
  did". `Surfex.Gate.drift/2` now tells tables apart by their `##` heading and header, keys
  a row by the cells that identify it (`Item`, else the fewest leading columns that name
  every row once on both sides), compares rows whole, and names each changed cell with its
  old and new text: `excuses: class type · code t:X.t/0 — State :current → :retired`.
  A row with a `Version` column is now compared whole too, so a cell beside the version
  that changed is reported rather than missed. Cells are split as GFM splits them, on each
  `|` not escaped as `\|`. "No row changed" is kept for a change outside every row. No
  golden's bytes change; only the failure message reads differently.
  In the local checkouts of the projects using surfex, 3 of 31 committed goldens have
  rows broken this way (25 rows in all).

## [0.9.0] — 2026-10-14

Status reports what it used to miss. A `verifies` tag the log doesn't record now fails
(**Unrecorded**, #203), and so does a `refines` whose unit moved out of its section
(**Moved**, #218). A known deviation, a test kept red against a tracked issue, has a state
of its own that doesn't fail the gate until you ask (**Deviating**, #214). Tests calling
through brace imports reach their code (#194), and the code of a `@moduledoc false`
module is versioned in what runs it (#219). The status check also grows with the project
in proportion again (#204). A minor release, because what fails and some versions change:
**upgrade steps** under Changed, each with its measured cost.

### Added

- **`Surfex.Scan.resolver/1`** (#204, #220): the spec units indexed once, by full id and by
  bare id. `Surfex.Scan.resolve/2` takes it in place of the scans and resolves exactly as
  they do (unknown, ambiguous, `§`-ids), so code resolving many references builds it once.
- **Known deviations: `@tag deviation: "<ref>"`** (#214, #223). A suite that passed while
  the code deviated from its spec gets each deviation's test written from the spec; it
  fails, so it is skipped with a reference to what will fix the code. surfex had no state
  for that: the requirement's `proposed` relations failed the check until every deviation
  was fixed, and a `verifies` recorded on the red run counted the requirement complete.
  Now the tag (free text, beside the `skip:`; at test, `describe` or module level) makes
  each unit the test declares **deviating**:
  - `mix surfex.status` lists it under **Deviating** with its reference and test. A
    `proposed` relation to it, or to a unit it sits in, is marked `deviates` and doesn't
    fail. `--no-deviations` (`deviations: :fail`) fails on any deviation, for a release.
  - A deviation test that **passed** at its version in the evidence is a **stale
    deviation** and fails: drop the tag and validate. A skipped test never passed, so
    only a run that includes it judges this.
  - A deviation test that runs and fails is listed under Deviating, not under Failed.
    Any other failed test still fails.
  - A deviation tag on a test that declares no spec unit is broken.
  - Completeness: a deviating unit is incomplete, missing `deviates (<ref>)`, whatever its
    basis.
  - `RELATIONS.md` gains a `deviating` group (unit, reference, test): the ledger of known
    deviations. `COMPLETENESS.md` shows `deviates (<ref>)`. The JSON has `deviating`, and
    each relation a `deviates` list.

  `mix surfex.test --deviations` (#224) runs exactly the deviation tests, skips included,
  so their evidence says whether any is stale: run it on demand or in a scheduled job, then
  `mix surfex.status --evidence`. ExUnit includes a skipped test only by its reason, so it
  runs `mix test FILES --only location:FILE:LINE … --include skip:REASON …`
  (`Surfex.Select.deviations/1`, `Surfex.Select.deviation_args/1`), and refuses, before
  running, another test in those files skipped for a deviation test's reason, or a reason
  that isn't a literal. Test records gain `skip`, the reason as that filter matches it.

  `Surfex.Scan` gains `deviation`, a relation status `deviates`, and `Surfex.Status.derive/4`
  `deviating` and the `deviations:` option. Nothing changes for a project without the tag.

- **Uncredited red→green is reported** (#194, #225). A test version that failed and then
  passed against the **same** code versions never discriminates, so `mix surfex.confirm
  --evidence` credited nothing, and nothing said so: the change that made it pass was
  outside what the test reaches (a call the scanner didn't see, a change outside the
  scanned code, or a flaky test). `mix surfex.status --evidence` now lists each such test
  under **Uncredited**, with the code its runs recorded, unless the log records the
  version as discriminated. Information, never a failure. `Surfex.Evidence.uncredited/1`
  finds them, `Surfex.Status.derive/4` returns `uncredited`, and the JSON has `uncredited`.

### Changed

- **A `@moduledoc false` module's code is versioned in what runs it, and reach goes
  through it** (#219, #226). 0.8.0 covered a module's hidden *definitions*; a hidden
  *module* was still skipped outright, so a test driving a Mix task stopped at the helper
  module the task hands its work to, and changing that helper dangled nothing. The Elixir
  scanner now reads every file before it versions anything, and treats each definition of
  a `@moduledoc false` module as hidden code. An item's version covers the hidden modules'
  code it runs, in any module and any file, transitively, stopping at code an item
  versions (a public function, or a shown module's hidden definition): changing the
  public function the helper calls dangles that function alone. The hidden module still
  has no items, `Surfex.SourceScan.module_hash/1` and `defs/1` are unchanged, and a module
  nested in it is still scanned. `Surfex.Item` and code records gain `runs`, the hidden
  modules' code the item runs with its calls: a call naming it reaches what it calls and
  no record for it, and a test importing a hidden module resolves against it.

  **Upgrade step.** Every item running a hidden module's code gets a new version once.
  Measured on eight adopting projects: four have no item running any, and keep every
  version; in the other four, 1 to 11 item versions change, and 11 to 62 tests reach more
  code (none reaches less). Most of the relations that dangle are `tests` relations,
  which `mix surfex.suggest --accept` re-records; after `mix test`, `mix surfex.confirm
  --evidence` re-confirms the `implements` confirmed by evidence (2 or 3 per project).
  What remains, 1 to 5 `implements` validated by review per project, plus a few excuses
  and baselined relations, is a review of the helper code now in the version.

- **A test's declaration with no `verifies` relation fails the check: Unrecorded** (#203,
  #221). A test tagged `@tag verifies: "id"` that resolves to a real spec unit, with no
  `verifies` relation between them in the log, was reported nowhere: the tag read as done
  while the test contributed nothing. It is now **unrecorded**, the other direction of
  undeclared, and fails like it. A tag left on a relation that was **retired** is listed
  under the same heading, "declared, but the relation was retired (note): remove the tag,
  or reinstate it", and fails too. `Surfex.Status.derive/4` returns them as `unrecorded`
  (each with its test, its spec unit and, when retired, the retire's note), the JSON as
  `unrecorded`, and `RELATIONS.md` as an `unrecorded` group and count. No setting: a
  `require:` policy can't express it, and nothing needs one.

  **Upgrade step.** `mix surfex.status` may newly fail. For each test and unit it lists:
  a tag with no relation is the one `mix surfex.suggest` already offers under `verifies`;
  record it and validate it (a failing run, or `mix surfex.validate` after reading both
  ends), or remove the tag if the test doesn't verify that unit. Judge each one; don't
  accept them in bulk. A tag on a retired relation: remove the tag, or reinstate the
  relation if the retirement was wrong. Measured on eight adopting projects: none has a
  tag without a relation, and two have one tag each on a retired relation, so the upgrade
  newly fails 0 to 1 declarations there. One of the two is a module's `@moduletag`
  inherited by a test it doesn't fit. Because it changes what fails, this ships in a minor
  release.

- **A `refines` relation whose unit moved out of its section fails the check: Moved**
  (#218, #222). Moving a marked block unchanged into another section changes neither
  end's version (a section's version leaves its blocks out), so the old `refines`
  relation stayed current, stating a structure the spec no longer has, while `suggest`
  proposed only the new one. Status now re-reads `within` for every live `refines`
  relation: one whose unit no longer sits in what it refines is **moved**, names where the
  unit sits now, and fails. `Surfex.Status.derive/4` returns them as `moved` (`from`,
  `to`, `now`), the JSON as `moved`, and `RELATIONS.md` as a `moved` group and count.
  `Surfex.Suggest.all/5` gains `moved`, which `accept_all/5` retires beside the new
  `refines` relation, so one `mix surfex.suggest --accept` settles the move; a dangling
  `refines` relation whose unit moved, which refresh can't re-establish, is retired the
  same way.

  **Upgrade step.** `mix surfex.status` may newly fail on a block or test hint moved
  between sections since its `refines` relation was recorded. Run `mix surfex.suggest`:
  it lists the relation to where the unit sits now and the old one's retirement;
  `--accept` records both. Both are structural facts read from source, so nothing needs
  judging. Measured on eight adopting projects (784 live `refines` relations, four of
  them using blocks or hints): none has a moved relation, so the upgrade newly fails
  nothing there. Because it changes what fails, this ships in a minor release.

### Fixed

- **`Surfex.Status.derive/4` grows with the project in proportion** (#204, #220). It was
  quadratic in the spec units: each test declaration resolved by filtering every scan,
  and the triangle walked every verified unit's `within` chain for each spec unit (the
  baseline check, every verifies relation for each baselined `implements`). Both are now
  indexed once per derive, and a `derive-linear` test guards the growth. On a project of
  about 2,900 records and 27,500 log entries derive fell from about 3 s to 0.65 s, with an
  identical status. `mix surfex.suggest`, `mix surfex.test` and the baseline resolve
  declarations through one resolver too.

- **A test's calls resolve through brace imports, and credit the imported module** (#194,
  #225). `import Base.{A, B}` imported nothing for surfex, so a test calling `f()` through
  it reached none of `A`'s or `B`'s code: the run recorded no versions for it, and its
  red→green against a change there was lost. Now each member is imported, and `only:` and
  `except:` are honoured in either form. Given the project's code, a local call resolves
  only to a function the imported module defines, and names the module too, as
  `A.f()` would: a test calling a module's functions through an import exercises the
  module, so a section the module implements no longer reports it as a triangle gap. A
  call no scanned imported module defines (ExUnit's `assert` beside `import A`) is no
  longer listed under it; through a module that isn't scanned, nothing changes.
  `Surfex.Scan.ExUnit.records/3` and `tests/3` take the code records for this, and
  `mix surfex.status` and `Surfex.ExUnitFormatter` pass them. Code calls read brace
  imports and `only:`/`except:` too.

  **Upgrade step:** none required, but run `mix surfex.suggest` after upgrading: tests
  calling through imports gain `tests` proposals to the functions and modules they now
  reach, each to be confirmed by evidence or review. Measured read-only on eight adopting projects: in two,
  307 tests reach more code and 12 triangle gaps close; no test reaches less anywhere and
  no gap opens. In six, the calls of 502 tests drop candidates no scanned module defines,
  which reach nothing either way.

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
    doesn't render on a forge (ex_doc does show it as text: put it on the line after the
    heading instead, #195);
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
