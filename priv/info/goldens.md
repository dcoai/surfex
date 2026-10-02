# Goldens

A golden is a committed, readable report that CI checks for drift.

- `goldens: [:status, :completeness]` in `.surfex.exs`: `RELATIONS.md` (every relation and
  its state) and `COMPLETENESS.md`.
- `mix surfex.goldens` checks them and fails on drift; `--write` regenerates.
- Rows name ids and states, never hashes, times or line numbers, so a row changes only
  when its relation does.
- On a merge conflict in a golden, never hand-merge: take both sides' sources and run
  `mix surfex.goldens --write`.
