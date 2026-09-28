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

**When a heading per requirement is too many headings, mark the requirement instead.**
A marked block is a unit of its own, inside its section:

````markdown wren-block
## Limits {#limits}

Messages are bounded so a slow peer can't exhaust memory.

<!-- surfex: max-len -->
A message is at most 512 bytes. `Wren.send/3` returns `{:error, :too_long}` for a
longer one and queues nothing.
<!-- /surfex -->
````

The block has its own id (`spec.md#max-len`) and its own version, and the section's
version leaves it out. Rewording the rationale dangles the section's relations and not
the block's, and editing the limit dangles the block's alone. The markers are HTML
comments, so the spec renders as ordinary prose. `mix surfex.suggest` relates a
citation inside a block to the block, and proposes that the block `refines` its
section.

## 3. Keep headings stable

A section's id is its heading path, so a renamed heading orphans every relation of the
section, and of every section below it. The version survives the rename (the heading
isn't hashed), which is how Surfex tells a move from a rewrite.

**Give sections that others relate to an anchor**: `## Limits {#limits}`. The id is then
`spec.md#limits`, whatever the heading says and wherever the section moves. Anchors are
lowercase letters, digits and `-`, unique in their file.

- **Name sections; don't summarise them.** "Sending" survives rewording, "Messages are
  queued, never sent synchronously" doesn't.
- **Don't put numbers you'll renumber in headings.** Inserting "3. Framing" before
  "3. Limits" renames every heading after it.
- **When you do rename, move the relations in the same change.** `mix surfex.suggest`
  sees the same version under a new id and proposes the move, and `--accept` records
  it. That covers a renamed heading, and adding an anchor to a section that had none.
  When the text changed as well, name the move yourself:
  `mix surfex.move "spec.md#Messaging/Limits" spec.md#limits`. A move carries the
  recorded versions across, so it never confirms anything. A relation whose text
  changed dangles until you confirm it. `mix surfex.history` on the old id lists what it
  was related to.

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

**Say how to test it, where that isn't obvious**, in a test hint: a fenced block whose
info string is `test` and an id.

````markdown wren-hint
```test max-len-test
given a 513-byte message
when it is sent
then {:error, :too_long}, and nothing is queued
```
````

A hint is visible to readers, and it is a unit of its own, with its own version, left
out of the version of the section or block around it. Editing how a requirement is
tested therefore doesn't dangle the code that implements it. Write what to check (the
cases, the boundaries, what must stay unchanged) rather than test code, unless a test
is the clearest statement of the requirement. A `test` block with no id is an
ordinary code block.

## 7. Test-first, with Surfex

The order that makes it hardest to get the code wrong is spec, then test, then code. The
test is written from the spec's words, before any code exists to copy. Surfex records
each step, so the order is visible afterwards, and the three relations between a
requirement, its tests and its code are checked together.

Turn on test scanning in `.surfex.exs`, and require every test hint to be verified:

```elixir
tests: ["test/**/*_test.exs"],
require: [code: [:implements], test_hint: [:verifies]]
```

1. **Write the requirement and its test hint, and plan the code.**

   ````markdown
   ## Sending {#sending}

   `Wren.send/3` queues a message for a peer.

   ```test sending-queues
   given an empty queue, when a message is sent, recv/1 returns it
   ```
   ````

   `mix surfex.relate --planned spec.md#sending Wren.send/3 --type implements` records
   that `Wren.send/3` will implement it, although it doesn't exist yet: the relation is
   **planned**, and the section is **unimplemented**. The hint is **unmet**, because no
   test verifies it yet, so the check fails until one does.
2. **Write the test from the hint**, and say so with a tag:

   ```elixir
   @tag verifies: "sending-queues"
   test "a sent message can be received" do
     ...
   end
   ```

   Run it: it fails (red), because the code doesn't exist.
   `mix surfex.suggest --accept` records that the test `verifies` the hint. The hint is
   met, and the **triangle** shows what's still open: the test calls `Wren.send/3`, and
   nothing implements the section yet.
3. **Write the code** until the test passes (green). The planned relation now
   **dangles** on the code's end: the code exists, and nobody has yet said it matches.
4. **Let the evidence confirm it.** With `Surfex.ExUnitFormatter` in `test_helper.exs`,
   each `mix test` records every test's result at its exact version. The red run and the
   green one are the evidence:

   ```sh
   mix surfex.suggest --accept      # the test `tests` the code it calls
   mix surfex.confirm --evidence    # confirmed: red, then green against the new code
   ```

   The test went red against the old code and green against the new, unchanged itself, so
   the `tests` relation is confirmed. So is `implements`, because the test `verifies` the
   section's hint. No one had to confirm the code by hand. Whether the test expresses the
   requirement stays a judgement: `verifies` is only ever confirmed by name.
5. **Check:** `mix surfex.status` is current, and the triangle is closed: the section is
   implemented by `Wren.send/3`, verified by the test, and the test exercises
   `Wren.send/3`. A release pipeline runs `mix surfex.status --no-planned`, which also
   fails on anything planned and not built. A project that wants every open side of the
   triangle to fail the check sets `triangle: :fail`.

`mix test --only verifies:sending-queues` runs exactly the tests of that requirement.

When the code changes later, a green run re-confirms it:

```sh
mix test && mix surfex.confirm --evidence
```

When the spec changes, its relations dangle and need a judgement:
1. Update the test to the new words first. That makes it a new test version, which must
   fail and pass again.
2. `mix surfex.confirm` its `verifies` relation by name.
3. Let the evidence confirm the rest.

A test is versioned like code (its body, its helpers, its setups, its table of cases), so
a test weakened to pass dangles its relations too. In CI, `mix surfex.status --verify
--evidence` checks every confirmation by evidence against CI's own run, and records
nothing.

## 8. Code the spec doesn't describe

Not every public function belongs in a spec: GenServer callbacks, generated accessors,
process wiring. Don't write sections to cover them, and don't loosen the check either.
**Excuse them by class**, in `.surfex.exs`:

```elixir
classes: [{"process plumbing", "OTP callbacks; the behaviour is the spec's subject"}],
rules: [%{class: "process plumbing", kinds: [:function], name: ~r/^handle_(call|cast|info)\//}],
require: [code: [:implements, :excuses]]
```

`mix surfex.suggest --accept` relates each matching item that nothing implements to its
class, with an `excuses` relation. Every public item is then either described or
deliberately excused, and both are on record. An excuse is held to account like any
other relation:

- Rewording the class's reason, or changing its rules, dangles every excuse of the class,
  so someone confirms each item still belongs.
- An item whose code changes dangles its excuse too: is it still plumbing?
- An excuse the rules no longer support is **stale** and fails the check: the item was
  renamed out of the pattern, another class's rule now matches it first, or a section now
  implements it.

Write rules by **class, never by item**. A new helper falls into its class and stays quiet,
while a new entry point matches no rule and needs a section, which is the direction that
matters. Prefer a section whenever the code has behaviour a reader of the spec should
know about. A class is for code whose only story is "it wires things together".

## 9. Working with an LLM

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

## 10. A worked example

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
which is the rename §3 warns about, until `mix surfex.suggest` sees the same version
under the new id and proposes moving them.

These claims are checked: Surfex's own tests scan both versions above, make these
edits, and assert exactly these outcomes.

## 11. Checklist

- [ ] Each section holds one requirement, or requirements that change together, or marks
      each requirement as a block.
- [ ] Overviews and rationale are in a parent's body, apart from the requirements.
- [ ] Headings are names, without numbers that will be renumbered, and sections others
      relate to have anchors.
- [ ] Each section names, in backticks and in full, the code that implements it.
- [ ] Each requirement says what is returned, rejected, or left unchanged.
- [ ] Concrete behaviour has examples, and rules over all inputs are stated as invariants.
- [ ] Where how to test a requirement isn't obvious, a test hint says so.
- [ ] Code the spec shouldn't describe is excused by a class, never item by item.
- [ ] `mix surfex.suggest` proposes the relations you expect, and no others.
- [ ] `mix surfex.status` lists no section as new that should relate to something.
