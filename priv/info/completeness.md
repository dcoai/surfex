# Completeness

`mix surfex.completeness [--format json]` scores how much is covered by validated
relations, per kind and overall, and lists each incomplete item with what it lacks.

- A **spec unit** is complete when a validated test verifies it (or a unit inside it) and
  any code implementing it is validated. A heading-only section isn't counted.
- A **test** is complete when it verifies a unit and exercises code (or verifies only
  units no code implements).
- **Code** is complete when validated and exercised by a test, or excused by a class.
- A unit a test declares the code deviates from (`@tag deviation: "#119"`) is never
  complete: it lists `deviates (#119)` until the fix lands and the tag comes off.

A spec unit counts only with its **own** evidence (claim grain): a section
whose hint is verified but whose prose no test claims lists `contained (<hint>, …)`, and
units with no text of their own (containers, marked tables) aren't counted
(`mix surfex.info claims`). Code is described only by an `implements` that earns: code
whose implements all earn nothing lists `unearned`. Units excused by a spec class and
deferred units are left out of the score and counted on lines of their own
(`excused by class: N spec units`, `deferred: N spec units (#12, …)`).

`completeness: [min: N]` in `.surfex.exs` makes `mix surfex.status` fail below N percent,
and `mix surfex.completeness` too. To gate the floor without the work list, run
`mix surfex.completeness --summary`: the score lines only, failing below N as before.
`goldens: [:completeness]` commits the report as `COMPLETENESS.md`.

The JSON form is the work list: kind, id, what it lacks, location. Work it one item at a
time through the process.
