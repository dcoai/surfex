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

**Not a claim**: bold. A bold-lead sentence without an id comment is its section's text.

A claim's version is its text and nested lines, without the list marker or id comment, so
renumbering a list changes nothing. A test verifies a claim by its id
(`@tag verifies: "no-override"`), and `require: [rule: [:verifies]]` asks that every claim
be verified. Spec §11.1 has the details.
