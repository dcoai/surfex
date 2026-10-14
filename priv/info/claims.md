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
when it should be a unit of its own. Off by default until 0.8.

**One claim per row**: a table row whose key reads as a list (`1001, 1005`, `a / b`,
`a and b`) is probably two claims in one row; the status lists it under "List-shaped keys"
as a warning. Split the row.

**Not a claim**: bold. A bold-lead sentence without an id comment is its section's text.

A claim's version is its text and nested lines, without the list marker or id comment, so
renumbering a list changes nothing. A test verifies a claim by its id
(`@tag verifies: "no-override"`), and `require: [rule: [:verifies]]` asks that every claim
be verified. Spec §11.1 has the details.

**Code relates to the claim it realises.** With `claim_implements: true` in `.surfex.exs`
(off by default until claim grain is released), `mix surfex.suggest` proposes
`implements` between each claim and the code its verifying tests call directly (their
own calls, private helpers, and resolved routes, events and messages), and prints one
`reached … through X: N more items` line where a called function reaches more: name the
ones that realise the claim with `mix surfex.relate`. A claim with no verifying test gets
nothing, and a section gets no proposals of its own (spec §15.1).
