# Recording relations

Every write appends an entry to `.surfex/` at both ends' current hashes, with a note.
Create the log once with `mix surfex.log --init` (it also sets git's union merge).

- `mix surfex.suggest` lists relations the source already states: a spec section citing
  code by name (`implements`), test tags (`verifies`), what each test calls (`tests`),
  units inside sections (`refines`), and moves (a renamed heading, anchor, test module or
  describe at the same version). `--accept --note N` records them. Accepting validates
  nothing: an `implements` from a citation is `proposed` until evidence or a review.
- `mix surfex.relate FROM TO --type T --note N`: one relation by hand, `proposed`.
  `--planned` records an end that doesn't exist yet (the code you're about to write).
- `mix surfex.retire FROM TO --type T --note N`: the relation no longer holds. On a pair
  never related it declines a suggestion (the note is required), and suggest skips it.
- `mix surfex.move OLD NEW --note N`: an id was renamed; carries every relation, keeping
  each basis. Anchored headings (`## Totals {#totals}`) keep their id across renames. A
  test moved to a renamed module, describe or file brings its red→green and baseline
  records when its version is unchanged; the task lists any it leaves behind.
- `mix surfex.resolve FROM TO --type T --pick TIP`: two branches recorded the same relation
  without seeing each other; pick the tip (by id prefix) to keep.
- `mix surfex.history ID`: every relation an id has had.

Types: `implements`, `verifies`, `tests`, `refines`, `depends_on`, `excuses`.
Ids: `spec.md#anchor` or `spec.md#Heading/Path`, a bare hint id, `Mod`, `Mod.fun/2`,
`test:Mod: describe: name`.

Validating is separate: `mix surfex.info validation`.
