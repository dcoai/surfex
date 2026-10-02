# Working as an agent

Surfex keeps a project's specification, its tests and its code aligned, and makes doing
that work, not waving it through, the only way to pass. It is a mix tool: **run `mix
surfex.info`** for the directory of topics and commands, and `mix surfex.info TOPIC` for
one. Both come from the installed version, so they are always current.

**Read first.**
- `mix surfex.status --format json`: the work list. Each relation needing attention, its
  state, its recorded and current hashes, which end changed, and where each end is.
- `mix surfex.completeness --format json`: each item not covered, and what it lacks.
- `mix surfex.history ID`: how a relation got here.

**Rules.**
- One relation at a time. Read both ends, judge the relation, record it with a note that
  says what you checked. `confirm` and `validate` take one relation on purpose.
- Never script confirmations, loop over the work list, or bulk-accept to go green. A
  passing status reached that way is false.
- Never confirm `implements` by hand; it needs evidence or a review.
- A failing test comes before the code. Record `verifies` on the failing run.
- To change a test, make the new version fail first, or review it.
- If the spec is what's wrong, mark it (`mix surfex.mark`); don't bend the test.
- Found work beyond the task goes to the project's process: `mix surfex.draft`.
- Don't hand-edit `.surfex/`. On a merge conflict in a golden, regenerate it
  (`mix surfex.goldens --write`).

**Notes** are the record a reviewer reads: name the claim, the assertion that checks it,
or why a reword didn't change behaviour.
