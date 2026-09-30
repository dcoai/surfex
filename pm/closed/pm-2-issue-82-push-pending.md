---
id: pm-2
title: "#82 completeness report: push, MR and review pending (GitLab unreachable)"
labels: [Review]
created: 2026-09-30
gitlab_issue: 82
gitlab_synced: true
closed: true
---

## To do when GitLab is back

1. Push `issue-82-completeness` and open the MR ("Closes #82: completeness report and
   score"). Let the pipeline run; merge only on green (`/complete-review`).
2. Post the completion summary below on #82 and move it `In-Progress` → `Review`.
3. When merged, close #74 ("All work items completed and merged (#82)"), then check the
   milestone "Validated by process": if nothing is open, close it.
4. File pm-1 as a GitLab `Proposal` issue and record its number there.

## Completion summary for #82

**Built by the process:** spec §20 first (hints `completeness-rules`, `completeness-score`),
then 9 tests, all red, with their `verifies` recorded on that failing run; then the code,
and the code relations were validated by the red run and the green one.

**Changes:**
- `Surfex.Completeness`: `report/1`, `text/1`, `json/1`, `golden/2`, `below?/2`.
  - A spec unit is complete when a validated test verifies it (or a unit inside it) and
    any code for it is validated; a unit no code implements needs its test alone.
  - A test is complete when it verifies and exercises code, or verifies only code-less
    units.
  - Code is complete when validated and exercised, or excused.
  - Each incomplete item names what it lacks; heading-only sections aren't counted
    (`Surfex.Scan.Markdown.empty?/1`).
- `mix surfex.completeness [--format text|json]`; `completeness: [min: N]`
  (`Config.completeness!/1`) makes `mix surfex.status` fail below it.
- `:completeness` and `{:completeness, output}` in `goldens:`. The `:status` golden now
  derives through `Config.status/4` too.
- §1.2 states the two repository rules its policy tests guard (published text is prose;
  the suite can't race itself).
- Untagged tests are now tagged to what they check and reviewed: class excuses (§15),
  stale excuses (§13.1), traces (§9), purpose (§1.1), the evidence walkthrough (§17).

**Naming, deliberately changed from #74:** `completeness`, not `coverage`. §7's Coverage
and `derive/4`'s `coverage:` option already mean class verdicts; a second meaning would
be ambiguous.

**Surfex's own score:** 100.0% (596/596) — spec units 101/101, tests 335/335, code
160/160. `.surfex.exs` now holds it there: `completeness: [min: 100]` and a
`COMPLETENESS.md` golden.

**Surfaced, filed as pm-1 (GitLab was unreachable):** the test scanner ignores aliases
declared inside a test or describe body, so calls through them go unrecorded. Found
twice (#81, #82); hoisting the alias worked around it both times.

**Checks:** 353 tests pass; the CI sequence with `--validated` passes; both goldens are
current.

### 2026-09-30 — Offline

- GitLab (API and git remote) timed out from the moment pm-1 was filed; the commit is on
  the local branch `issue-82-completeness`, push-pending.

### 2026-09-30 — Synced

- pm-1 filed as #87; the summary posted on #82, moved to Review; the branch pushed
  and the MR opened. Merging follows the pipeline.
