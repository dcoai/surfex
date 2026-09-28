# Writing specs Surfex can use

Surfex can only relate what it can see. It sees a specification as a list of sections,
each with an id and a version, and it sees code as a list of public items, each with an
id and a version. Everything it reports, which relations still hold and which need
looking at, is worked out from those two lists and the log of what someone confirmed.

So how a spec is written decides how useful Surfex is. A spec with one big section per
topic dangles every relation of that topic on any edit, until people stop reading what
they confirm. A spec whose sections match the code's pieces dangles exactly the
relations an edit touched. This guide is about writing the second kind.

## 1. What Surfex sees

The markdown scanner (`spec.md` §11) turns every heading into a section:

- **The id** is the file and the path of headings down to it:
  `spec.md#Messaging/Sending`.
- **The version** is a hash of the section's **own body**: not its heading, not its
  subsections, with runs of whitespace collapsed.
- **Fenced code blocks** are part of the body, and a `#` line inside one is not a heading.

What that means for each kind of edit:

| Edit | The section's id | Its version | Its relations |
|---|---|---|---|
| Reword a sentence | same | changes | dangle |
| Reflow a paragraph, add blank lines | same | same | current |
| Edit a subsection | same | same | current (the subsection's dangle) |
| Rename its heading | changes | same | orphaned, and the section is new |
| Rename a heading above it | changes | same | orphaned, and the section is new |

A relation **dangles** when either end's version moved since someone confirmed it, and
it stays dangling until someone reads both ends and confirms it again. Dangling is the
signal, so the aim is that a relation dangles when, and only when, the text it depends on
changed.

## 2. Size sections to what changes together

**One requirement, or one small group of requirements that always change together, per
section.** A section is the smallest thing a relation can point at. Two requirements in
one section share a version, so editing either dangles the relations of both.

Split a section when:
- it describes more than one public function, and they could change independently;
- it mixes a rule with its rationale, and the rationale gets edited more often than the
  rule (move the rationale to its own section, or to the parent's body);
- people confirm its relations without reading, because it dangles on every edit.

Don't split when:
- the pieces are one rule stated in several sentences (split them and every edit
  dangles several sections instead of one);
- the result is a heading per sentence. Each section should still read as a unit.

A parent section's body is its own. Put the overview there and the requirements in the
subsections, and editing the overview dangles nothing that relates to a requirement.

## 3. Keep headings stable

A section's id is its heading path, so a renamed heading orphans every relation of the
section, and of every section below it. The version survives the rename (the heading
isn't hashed), which is how a reader can tell a move from a rewrite. The relations
don't follow on their own.

- **Name sections; don't summarise them.** "Sending" survives rewording, "Messages are
  queued, never sent synchronously" doesn't.
- **Don't put numbers you'll renumber in headings.** Inserting "3. Framing" before
  "3. Limits" renames every heading after it.
- **When you do rename, re-relate in the same change.** `mix surfex.relate` the new id to
  each of the old one's partners, then `mix surfex.retire` the orphans. `mix surfex.history`
  on the old id lists what it was related to.

## 4. Name the code in the section that describes it

Write the names of what implements a section in that section, in backticks:
`` `Wren.send/3` ``, `` `Wren.Queue` ``. `mix surfex.suggest` reads those citations and proposes
the `implements` relation between the section and each item it names, so a spec that
names its code relates itself.

- Use the full name: `Wren.send/3`, not "send". A bare `Wren.send` names every arity.
- Name the code where it is **described**, not everywhere it is mentioned. A citation in
  an overview relates the overview.
- A name inside a fenced code block is an example, not a claim, and is not suggested.

## 5. State requirements as checkable claims

A requirement someone can check says what is **returned**, what is **rejected**, and what
**stays unchanged**:

- Instead of "sending should be robust", write "`Wren.send/3` returns `{:error, :too_long}`
  for a message over `Wren.max_len/0` bytes, and queues nothing".
- Instead of "the queue is ordered", write "`Wren.recv/1` returns messages in the order
  `Wren.send/3` queued them".

A checkable claim can be reviewed against the code, and a test can be written from it,
by a person or an agent, without guessing what was meant. A claim that can't be checked
can't dangle usefully either: nobody can tell whether a code change still satisfies it.

## 6. Give examples and invariants

Where a requirement has concrete behaviour, show it:

| message | result |
|---|---|
| `""` | `{:error, :empty}` |
| 512 bytes | `:ok` |
| 513 bytes | `{:error, :too_long}` |

or `iex>` lines. An example is the easiest part of a spec to test, and the hardest to
misread.

Where a requirement is a rule over all inputs, state it as an **invariant**: "every
message received was sent, and none is received twice". An invariant is written to be a
property test, which checks it over many generated inputs instead of a few chosen ones.

## 7. Test-first, with Surfex

The order that makes it hardest to get the code wrong is spec, then test, then code. The
test is written from the spec's words, before any code exists to copy.

1. **Write the section.** It's new: `mix surfex.status` lists it under "New".
2. **Write the test** from the section's claims and examples. Run it: it fails (red),
   because the code doesn't exist.
3. **Write the code** until the test passes (green).
4. **Record the relation.** `mix surfex.suggest --accept` relates the section to the code
   it names, at their current versions. Or name the pair yourself:
   `mix surfex.relate "spec.md#Messaging/Sending" Wren.send/3 --type implements`.
5. **Check:** `mix surfex.status` is current.

When the spec changes later, its relations dangle. Update the test to the new words
first, see it fail, then change the code, then `mix surfex.confirm` the section.

## 8. Working with an LLM

`mix surfex.status --format json` is an agent's work list: every relation needing
attention, which end changed, where both ends are, and every new section and item.

- **An agent may relate:** `suggest --accept` and `relate` record relations that don't
  exist yet, and are cheap to retire if wrong.
- **Confirming a dangling relation is a claim that someone read both ends.** An agent that
  confirms should have read the section and the code in the same turn, and say so in
  `--note`. `confirm` takes named ids only, never everything at once, for this reason.
- **Give the agent the section, not just the file.** The JSON report's locations point at
  the lines of each end.
- Ask for the test before the code (§7), in a separate step, so the test is written
  from the spec rather than from the code.

## 9. A worked example

Wren is a small, made-up messaging library. Here is its spec written in one section:

```markdown wren-before
# Messaging

`Wren.send/3` queues a message for a peer and `Wren.recv/1` takes the next one, in the
order they were sent. A message is at most 512 bytes: `Wren.send/3` returns
`{:error, :too_long}` for a longer one and queues nothing. `Wren.max_len/0` returns the
limit. `Wren.Queue` holds the messages.
```

`mix surfex.suggest --accept` relates that one section to all four names it cites. Then
the limit changes to 1024 bytes, which is a one-word edit. **All four relations dangle**,
including the ones for `Wren.recv/1` and `Wren.Queue`, which the edit didn't touch.
Whoever confirms them has to reread the whole section to find out that three of them are
fine.

The same spec, sized to what changes together:

```markdown wren-after
# Messaging

`Wren.Queue` holds the messages a peer has been sent and not yet taken.

## Sending

`Wren.send/3` queues a message for a peer.

## Receiving

`Wren.recv/1` takes the next message, in the order they were sent.

## Limits

A message is at most 512 bytes. `Wren.send/3` returns `{:error, :too_long}` for a longer
one and queues nothing. `Wren.max_len/0` returns the limit.
```

Now the same edit dangles **only the two relations of "Limits"**: `Wren.max_len/0`, and
`Wren.send/3`, whose behaviour on long messages is exactly what changed. `Wren.recv/1`
and `Wren.Queue` stay current. Reflowing any of these paragraphs dangles nothing, and
renaming "Limits" to "Size limits" keeps its version but orphans its two relations,
which is the rename §3 warns about.

These claims are checked: Surfex's own tests scan both versions above, make these
edits, and assert exactly these outcomes.

## 10. Checklist

- [ ] Each section holds one requirement, or requirements that change together.
- [ ] Overviews and rationale are in a parent's body, apart from the requirements.
- [ ] Headings are names, without numbers that will be renumbered.
- [ ] Each section names, in backticks and in full, the code that implements it.
- [ ] Each requirement says what is returned, rejected, or left unchanged.
- [ ] Concrete behaviour has examples, and rules over all inputs are stated as invariants.
- [ ] `mix surfex.suggest` proposes the relations you expect, and no others.
- [ ] `mix surfex.status` lists no section as new that should relate to something.
