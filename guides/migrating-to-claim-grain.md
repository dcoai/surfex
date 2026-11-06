# Migrating to claim grain

A relation log started at **section grain** has its `implements` on sections: code relates
to the heading whose text mentions it. That works until a section grows. Every edit of a
section's text re-versions the section, and every relation on it dangles at once: one
changed sentence can ask for dozens of re-reviews of relations whose claims didn't change.

At **claim grain**, code relates to the claim it realises: a row of a table, a test hint, a
marked block, a named rule or paragraph, a contract signature (spec §11.1). An edit then
dangles the relations of the claim it touched, and no others.

`mix surfex.migrate` moves a section's relations to its claims (spec §14.1). It works one
section at a time, as work touches a section. Nothing is migrated wholesale.

## 0. Claim grain is how surfex reads

Surfex reads every spec at claim grain; there is no switch. A `.surfex.exs` that still
sets `claim_grain:`, the key claim grain shipped behind, is refused: delete the line. For
a project that never set it, the check changes in five ways (spec §13.2):

- **Contained sections**: a section verified only through a claim inside it is
  `contained`. Completeness counts it incomplete until a test checks its own prose, its
  claims are named, or it is classed; containers aren't counted at all (spec §20.1).
- **Earning**: an `implements` counts for `require: code:` only when it earns, through a
  verified unit or a verified claim inside it whose test exercises the code. The rest are
  **unearned** and fail where `require: [code: [:implements]]` is set (spec §13.9).
- **Classes and deferrals** are read: an excused or deferred unit isn't judged or
  counted, a relation to an excused section is contradicted, and a deferral that no
  longer holds is stale (spec §13.6, §13.7).
- **Deviations** hold back the sections they sit under too (spec §13.11).
- **Path headings fold** under an id'd heading wherever `heading_ids:` is set
  (`fold_paths: false` keeps them units, spec §11.1).

Run `mix surfex.status` and `mix surfex.migrate --report` (below) to see what each of
these means for your spec.

## What upgrading costs

This section is for a project taking 0.10 or later from an earlier release. The numbers come
from projects that made the move. Read `mix surfex.migrate --report` before budgeting: it
predicts the work.

**The dangle wave is the work.** Tagging a test is the cheap part. Naming one rule takes its
text out of its section's own text, so the section's version changes and every relation on it
dangles. One project's pass over three sections took roughly 90 deliberate calls for 18
relations: 9 rules named, 4 tests written, 8 tagged, 14 `verifies` on 14 red runs, 18
migrations, 10 reviews, 19 retires, 9 structural relations and 2 corrected notes. Nobody should
budget that as "a tagging pass". The report's dangle-width column says how wide each section
is, so start there.

**A completeness floor can fail at once, with no quick way back to green.** With
`completeness: [min: N]`, the score can drop below N on the upgrade, and each contained section
is settled by a spec edit, which starts its own dangle wave. Don't settle them all in the
upgrade's merge request. Set the floor to the measured score with a comment saying why, then
raise it as sections settle.

A floor set before the sections were classed is a commitment to work nobody has sized yet.
Surfex's own floor shows it: `min: 100` was set on 2026-09-30, its 58 contained sections were
classed on 2026-10-14, and settling them was a separate pass.

**The first `mix surfex.suggest` offers a wave of relations.** Projects saw about 160, 220 and
427 reach-derived `tests` relations. They are new facts about what the tests call, not drift.

**How much reach grows depends on the project's shape.** It follows routes, a process's own
callbacks, helpers under `test/support`, and what `dispatch:` declares: a table, a registry, or
a module passed as a value. A project with none of these sees no change.
One project with no router, dispatcher or DSL stayed at 49 triangle gaps before and after.

**Excuses of process wiring dangle.** Hidden definitions are versioned now, so the code behind
`start_link`, `children` and a Mix task's `run/1` moves the version of what runs it. Every class
excuse on such code dangles, so expect them under classes like `mix task` or `process wiring`,
and re-confirm each against its class. One project expected 18 dangling type excuses and got 20
class excuses instead.

**A deviation can fail `require: code:`.** A module whose only `implements` is to a section
holding a deviation is unearned, so a pending deviation becomes a gate failure on the day of
the upgrade (spec §13.11). Fix the deviation first, or give the module an `implements` to a claim
outside the deviating section.

**Every suite that pins surfex has to move.** In a poncho, each sibling can pin surfex and run
`Surfex.ExUnitFormatter` with `surfex_root:` pointing at the root. Bump every `mix.exs` that
depends on it (`grep -r ':surfex' */mix.exs`), and run every suite that writes the root's
evidence, not just the root's.

**A retired release fails `mix hex.audit`.** If surfex retires the release a project is locked
to, the audit fails in CI whatever the reason for the retirement. Upgrade, or acknowledge it in
the audit step.

**A section kept contained by a caption or a rationale.** A classed section with claims inside
reads as a container: its claims answer for themselves and its own text is excused (spec
§13.6). So name every real claim, then class what's left.

## 1. See what migration buys

```sh
mix surfex.migrate --report
```

The report starts with the **population**: the sections holding section-grain `implements`,
split into those whose claims are already units (tables, hints, blocks, rules, contracts),
which migrate today, and **prose** sections, whose claims need naming first. Then each
section, worst first:

```text
spec.md#billing (claims are units): 81 relations now → 24 after; implements 57: 51 single · 6 several · 0 none
  MyApp.Billing.base_time/2: 81 now → 6 after (single)
  …
```

- **relations now → after**: what one edit of the section's text dangles today, and once
  every code item with a candidate claim has moved.
- **marking**: a prose section has no claim a relation could move to. Naming its claims,
  the first marker or id comment, re-versions the section and dangles everything on it
  once. The report counts that cost, since it is paid even for relations that don't move.
- each code item's **dangle width**: the relations a change to the text stating its claim
  dangles, now and after.

Measured over projects that already had their claims as units, what an edit of a section
can dangle fell from 1,128 relations to 413; the widest section went from 81 to 24, and its
widest item from 81 to 6. Projects whose sections are all prose owe the marking first:
there, the report is the list of where to name claims.

The report is the whole work list (spec §14.2). A **contained** section, one with no test
of its own while a claim inside it is verified, gets a line naming those claims:

```text
spec.md#totals (claims are units): 4 relations now → 4 after; implements 0: 0 single · 0 several · 0 none
  contained: spec.md#totals-empty verified inside, its own text isn't
```

Contained sections are listed even when they hold no `implements`: there is no code to
move, but completeness counts them incomplete until a test checks
their own prose, their claims are named, or they are classed (spec §20.1). `mix
surfex.migrate --report --format json` gives the same report for tools.

## 2. Look at one section's proposals

```sh
mix surfex.migrate spec.md#billing
```

For each code item related to the section, the claims inside it that could own the code:

- a row whose key **names** it (`Mod.fun/2`, or `Mod.fun`, which names every arity);
- a claim whose verifying test **calls** it;
- failing both, a claim whose test **reaches** it, through the item named.

Arities of one definition (default arguments) are one proposal. The listing has four kinds:

```text
none      MyApp.Billing.round/1: no claim inside spec.md#billing names it or has a test calling or reaching it: …
several   MyApp.Billing.total/1 → spec.md#billing-sum (called by its test …); spec.md#billing-tax (…): …
single    MyApp.Billing.base_time/2 → spec.md#rates/MyApp.Billing.base_time (its key MyApp.Billing.base_time names it)
migrating MyApp.Billing.rate/1 → spec.md#rates/MyApp.Billing.rate: validate the claim's relation …
```

**none** comes first: it is the spec work the migration surfaces. The code realises a
claim nobody wrote down yet (write it: a row, a hint, a named paragraph), or it doesn't
belong to the section at all. **several** is a judgement: read the claims and the code.

## 3. Record it, and stay green

```sh
mix surfex.migrate spec.md#billing --accept --note "billing moves to its rows"
```

Each single proposal is recorded as an `implements` to its claim, **proposed**, carrying
`migrates` (the section it moves from). A proposed relation normally fails the check;
one that migrates doesn't, while the section still holds its own. So a section can move
over as many commits as it takes, with the check green throughout.

Read the list first: a single proposal only means one claim's test reaches the code, and that
can be wrong. `--skip ID`, once per item, records the others and leaves that one on its
section, which stays green until you decide. A test tagged to the section still meets it
through code that has moved to a claim inside it (spec §13.1).

For several, or for none once its claim exists, record your choice:

```sh
mix surfex.migrate spec.md#billing --code MyApp.Billing.total/1 --to spec.md#billing-sum
```

## 4. Validate the claims; the section lets go

Validate each claim relation the way any `implements` is validated: by evidence (a red run
then a green one, `mix surfex.confirm --evidence`), or by a review:

```sh
mix surfex.validate "MyApp.BillingTest: base time per rate" spec.md#rates/MyApp.Billing.base_time \
  --note "asserts the base time for each rate, the row's claim"
```

When a review credits several arities of one definition, `validate` says so: write the
note for the definition (spec §18.4).

Once every claim relation of a code item is validated, the pair is **settled**, and the
section's relation is retired with a note naming the claims, by the next `--accept` or by
`mix surfex.suggest --accept`. A section never loses a relation before its claim holds one.

**Moving a test's tag.** When a test stops declaring a unit, `mix surfex.suggest --accept` retires
the relation only if it is still proposed. A validated one stays and the status fails as
**Undeclared**, because a tag can go by mistake and a retired relation doesn't come back on its
own. Restore the tag, or read the list and run `mix surfex.suggest --accept --retire-undeclared`.
Two `@tag verifies:` lines above one test keep only the last: the status lists the first as
**Inert**, so use one list.

## A library's API as contracts

A contract signature is the finest claim a spec makes: one function. A library whose
public API is described in prose can state it as contract fences instead (spec §11.1),
one unit per `@spec`, related to its function. A changed signature or a reworded `@doc`
then dangles that one relation and no other (spec §13.18), and `mix surfex.validate`
settles it once a review finds the two still agree. The library guide shows the form, and
surfex's own spec §23.2 is a worked example.

## A baseline carries

A project that adopted its suite with a baseline (`adoption: :trust`, `mix surfex.baseline`,
see the adoption guide) doesn't redo that trust. A section relation resting on the baseline
moves to a claim whose verifying test is the same baselined test, at the version trusted,
exercising the same code: the claim relation keeps basis `baseline`, holds at once, and the
section's relation retires in the same `--accept`.

## Importing your own tags

A project that already records what its tests verify in a tag of its own can have surfex
read it, rather than rewriting every tag:

```elixir
declares: [verifies: [{:tag, :validates, strip: ~r/@[0-9a-f]+$/}]]
```

`@tag validates: ["Engine.15.2@abc123"]` then declares `Engine.15.2`, resolved as any
declaration (through `unit_refs:` in the project's citation form), suggested by
`mix surfex.suggest` and confirmed by evidence (spec §11.6). `mix test --only` can't select
by such ids; `mix surfex.test UNIT` does.
