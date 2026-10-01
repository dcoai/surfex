# Surfex

Surfex keeps a project's specification, its tests and its code in step. It scans the
three (spec sections, test cases, code items, each at a content hash) and keeps an
append-only log of the relations between them, each recorded at the versions it was
confirmed at and with the basis that validated it. When an end changes, its relations
dangle; `mix surfex.status` says exactly what needs attention and why.

Code is never taken on anyone's word: a relation is validated by evidence (a test that
went red, then green), a review, or a judgement. Run `mix surfex.status` first.

## Topics

Read one with `mix surfex.info TOPIC`.

mix surfex.info model         spec, tests, code; relations, their states and bases
mix surfex.info process       spec → failing test → green code, and what each change needs
mix surfex.info agent         rules for an agent: what to read, what never to script
mix surfex.info status        reading the status report and choosing what to fix
mix surfex.info recording     relate, retire, move, resolve, history: writing the log
mix surfex.info validation    evidence, review and judgement; when each applies
mix surfex.info marks         a spec unit that is itself wrong: mark and withdraw
mix surfex.info adoption      adopting an established suite: trust or re-evaluate
mix surfex.info completeness  the coverage score and what each item lacks
mix surfex.info drafts        handing found work to the project's change process
mix surfex.info goldens       committed, drift-checked reports (RELATIONS.md)
mix surfex.info config        every .surfex.exs key

## Commands

Ids: a spec unit is `spec.md#anchor` or `spec.md#Heading/Path`; code is `Mod`,
`Mod.fun/2`; a test is `test:Mod: describe: test name`.

Read the state:
mix surfex.status [--format json] [--validated] [--evidence]   every relation needing attention
mix surfex.completeness [--format json]   coverage by validated relations, and what's missing
mix surfex.history ID   every relation an id has had, from the log alone
mix surfex.info [TOPIC]   this directory, or a topic's page

Record relations:
mix surfex.suggest [--accept --note N]   relations the spec and test tags already state
mix surfex.relate FROM TO --type T [--planned] --note N   one relation, by hand
mix surfex.retire FROM TO --type T --note N   two things no longer relate
mix surfex.move OLD NEW --note N   carry a renamed id's relations across
mix surfex.resolve FROM TO --type T --pick TIP   settle a conflicted relation

Validate relations:
mix surfex.confirm --evidence   every relation the recorded test runs validate
mix surfex.validate TEST SPEC_UNIT --note N   a review: this test validates this unit
mix surfex.confirm FROM TO --type T --note N   a judgement (never for implements)
mix surfex.baseline --note N   adopt a trusted suite, once (adoption: :trust)

Spec problems and found work:
mix surfex.mark SPEC_UNIT --needs-update --note N   the spec itself is wrong (--withdraw)
mix surfex.draft [SPEC_UNIT] [--format json] [--file]   write up found work as change drafts

The log and committed reports:
mix surfex.log --init | --verify | --break | --rechain   create and maintain .surfex/
mix surfex.goldens [--write]   check (or regenerate) RELATIONS.md and other goldens

## Where things are

- `.surfex.exs`: the project's config (`mix surfex.info config`).
- `.surfex/`: the relation log, committed, merged by git's union merge.
- `_build/surfex/evidence.jsonl`: test results at exact versions, never committed.
- `spec.md` (in the surfex package): the full specification of the tool.
