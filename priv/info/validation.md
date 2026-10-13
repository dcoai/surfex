# Validation

A relation is validated by its basis. Which bases make it current:

| Type | Validated by |
|---|---|
| `implements` | evidence or a review only, never by hand |
| `verifies` | evidence of the failing run, a review, or a judgement |
| `excuses`, `depends_on` | a judgement |
| `tests`, `refines` | nothing: structural facts read from the source |

**Evidence**: `mix test && mix surfex.confirm --evidence`. It records every relation the
test runs show: `verifies` on a test's failing run; `tests` and `implements` once a test
has gone red against one version of the code and green against another (or is
baselined under adoption, `mix surfex.info adoption`).

**Review**: `mix surfex.validate TEST SPEC_UNIT --note N`. Read the unit's claims and the
test; judge whether the test checks them (cases, boundaries, what must not change); fix
the test where it falls short. It needs the `verifies` relation and green evidence at the
current test and code versions. The unit may be a section whose hint the test already
verifies: the review then records the section's `implements` for the code the test
exercises. The note says which assertion checks which claim.

**Code behind an entry point**: a test reaches what it calls and, transitively, what that
code calls, as the source states it. So a unit may cite the function doing the work while
its test drives the public entry point: evidence and a review credit the cited function's
`implements`, and the triangle counts it exercised. Reach never makes a relation: `tests`
names what the test calls itself. Code reached only at run time (messages, dispatch by
name) isn't reached by reading the source, with one exception: a function calling its own
module's behaviour (`GenServer.call`) reaches the module's hidden `@impl` callbacks, and
a call to a hidden definition (a Mix task's `run/1`) goes on through what it calls. Hidden
definitions are versioned in their module, and in the public functions that run them, so
changing a callback dangles both. A review's note speaks for what was read, so
`validate` credits reached code only when you name it: `--code ID`, after reading it.

**Many at once**: `--file PATH` on `confirm` or `validate` records a file of relations in one
run, one per line, tab-separated, each line ending with its own note (`FROM TO TYPE NOTE`,
or `TEST UNIT NOTE`). The notes must be distinct; write each line after judging that
relation.

**Evidence from CI**: `--merge PATH` (once per file) on `confirm --evidence`, `validate`,
`relate` and `suggest --accept` reads CI jobs' evidence files beside the local run, so a
test excluded locally (it needs a service you don't run) counts from CI's run.

**Docstrings aren't covered.** A function's version leaves out its `@doc`, so a docstring
that states a contract can drift from the spec unnoticed. Read them together.

**Judgement**: `mix surfex.confirm FROM TO --type T --note N`. For a spec reworded with
no change in behaviour (`verifies`), or an excuse. It refuses `implements`.

`--validated` on status fails on current `implements`/`verifies` relations without one of
these (unvalidated: recorded before validation existed, or a baseline no longer trusted).
