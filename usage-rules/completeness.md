# Completeness

`mix surfex.completeness [--format json]` scores how much is covered by validated
relations, per kind and overall, and lists each incomplete item with what it lacks.

- A **spec unit** is complete when a validated test verifies it (or a unit inside it) and
  any code implementing it is validated. A heading-only section isn't counted.
- A **test** is complete when it verifies a unit and exercises code (or verifies only
  units no code implements).
- **Code** is complete when validated and exercised by a test, or excused by a class.

`completeness: [min: N]` in `.surfex.exs` makes `mix surfex.status` fail below N percent.
`goldens: [:completeness]` commits the report as `COMPLETENESS.md`.

The JSON form is the work list: kind, id, what it lacks, location. Work it one item at a
time through the process.
