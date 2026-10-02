# Marks: the spec itself is wrong

When the tests reflect the spec and the code passes them, but the result is wrong, the
spec needs to change. Don't bend the test; mark the unit:

```
mix surfex.mark spec.md#totals --needs-update --note "totals ignore the customer's discount"
```

- A mark records the unit's current version. It stays **open** while the unit is at that
  version, and is **resolved** when the spec changes. It is **orphaned** if the unit goes.
- Status lists open and orphaned marks in every report; `--no-marks` fails on them.
- Withdraw one that was wrong: `mix surfex.mark spec.md#totals --withdraw --note N`.
- `mix surfex.draft spec.md#totals` writes the marked unit up as a change draft for the
  project's process (`mix surfex.info drafts`).
