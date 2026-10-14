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
