# Claims: units smaller than a section

A section often holds several claims. Name each one, and it becomes a spec unit of its own
(role `:rule`): its own id, its own version, its own relations. Rewording one claim then
dangles only that claim's relations, not the whole section's. No id ever comes from
position, so inserting a claim moves nothing else.

**A paragraph or a list item**: an id comment on its own line directly before it.

```
<!-- surfex: retired-unreachable -->
**A retired schema's objects are unreachable by construction.** Nothing resolves to them.

- plain item

<!-- surfex: no-override -->
- Anonymous requests never honour an override.
```

An id comment starting the item or paragraph (`- <!-- surfex: ID --> text`) is read too,
but ex_doc shows it as text (or swallows the next heading), so prefer the comment on its
own line. Before a list item that isn't the list's first, the comment needs a blank line
above it.

**A list of rules**: mark the list, and write each item's id as its text already does.

```
<!-- surfex: rules tenancy -->
1. §Tenancy.1 A tenant reads only its own rows.
2. §Tenancy.2 A tenant's id is never reused.
```

`.surfex.exs` says how ids are written: `rule_ids: :section_sign` (`§ID`),
`:section_number`, a regex with `(?<id>…)` such as `~r/^(?<id>P\d+)/`, or a list of them.
An item with no id is an error naming its line.

**A module's signatures**: a contract fence, one unit per function, `spec.md#feed/2`.

````
<!-- surfex: contract module: MyApp.Feed -->
```elixir
@spec feed(t, item) :: t
@callback init(term) :: {:ok, t}
```
````

In a subject section (`subjects:`) the marker needs no `module:`. Changing one signature
dangles only that function's relations.

**Citing a unit in the project's own form**: ids are per file, and a project often cites
them across files as `§03.4` or `spec/05 §4.3`. List the forms in `.surfex.exs`, each a
regex naming the `id` and the `file` (its path, with or without `.md`) or the `chapter`
(the number the file's name starts with):

```
unit_refs: [~r/^§(?<chapter>\d\d)\.(?<id>[\w.]+)$/]
```

Then `@tag verifies: "§03.4"`, `mix surfex.test §03.4` and `mix surfex.validate TEST §03.4`
all name `spec/03-wire-format.md#4`.

**Sub-headings as structure**: with `fold_paths: true`, a heading with no id inside one
that has an id (`### run/2` under `## §Engine.13`) is part of that unit: its text counts in
the id'd section's version, and its hints sit in that section. Give a sub-heading an id
when it should be a unit of its own. Off by default; under `claim_grain: true` it is the
default wherever `heading_ids:` is set (`fold_paths: false` opts out).

**One claim per row**: a table row whose key reads as a list (`1001, 1005`, `a / b`,
`a and b`) is probably two claims in one row; the status lists it under "List-shaped keys"
as a warning. Split the row.

**Not a claim**: bold. A bold-lead sentence without an id comment is its section's text.

A claim's version is its text and nested lines, without the list marker or id comment, so
renumbering a list changes nothing. A test verifies a claim by its id
(`@tag verifies: "no-override"`), and `require: [rule: [:verifies]]` asks that every claim
be verified. Spec §11.1 has the details.

**What verified means** (spec §13.4). A unit's own text is its body without the claims
inside it. A **claim** has some (a section or block with prose of its own, and every hint,
rule, row and contract); a **container** has none (a heading over subsections, a section
whose body is only named claims, a marked table). The status gives each unit a verdict:

| Verdict | When | What it needs |
|---|---|---|
| verified | a claim with a current `verifies` of its own | nothing |
| contained | a claim with none of its own, but a claim inside it is verified | its own evidence: its prose isn't verified |
| unverified | a claim with no evidence, own or inside | its own evidence |
| through claims | a container | nothing: its claims answer for themselves |

No credit moves up (a section's tag says nothing of the claims inside it) or into a
section's own prose (a verified hint says nothing of the paragraphs around it). The status
lists **Contained** claims and each `verifies` **on a container** (it verifies nothing:
move the tag to what it checks). Neither fails on its own. A contained section is settled
by tagging it on a test that really checks its prose, by naming its prose's claims and
migrating them (the guide "Migrating to claim grain"), or by classing prose that asserts
nothing.

**Spec text that asserts nothing is classed** (spec §11.7, §13.6). `spec_classes:` in
`.surfex.exs` declares classes with reasons; a section is classed by
`<!-- surfex: class NAME[: REASON] -->` on its own line, by a `files:` or `headings:`
pattern, or by the project's own comment through `marker:`. A unit not built yet is
deferred by its issue, `<!-- surfex: deferred #123[: REASON] -->`. Under
`claim_grain: true` a classed section with no claim inside is **excused** and a deferred
one **deferred**: neither is judged by `require:` spec rules nor counted in completeness.
A class excuses the section's own text, never a claim named inside it. A `verifies` or
`implements` to an excused section is **contradicted** and fails (retire it, or drop the
class), and a deferral is **stale** once its unit has a test of its own or, under
`mix surfex.status --issues`, its issue is closed.

**Code earns through the claim that exercises it** (spec §13.5). An `implements` to a
verified unit earns; one to a container or a contained section earns when a verified
claim inside it has a test (or a check) that exercises the code. Otherwise it is
unearned: `unverified`, `not_exercised` or `nothing_inside` (`Surfex.Status.earning/2`).

**Code relates to the claim it realises.** With `claim_implements: true` in `.surfex.exs`
(off by default until claim grain is released), `mix surfex.suggest` proposes
`implements` between each claim and the code its verifying tests call directly (their
own calls, private helpers, and resolved routes, events and messages), and prints one
`reached … through X: N more items` line where a called function reaches more: name the
ones that realise the claim with `mix surfex.relate`. A claim with no verifying test gets
nothing, and a section gets no proposals of its own (spec §15.1).
