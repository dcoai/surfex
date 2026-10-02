# The model

**Ends.** Surfex scans four kinds of thing, each with an id and a content hash (its
version):
- `spec`: a markdown section (`spec.md#anchor`, or `spec.md#Heading/Path`), a fenced
  block, or a test hint (```` ```test hint-id ```` in the spec: a claim a test must verify).
- `code`: a module or function (`MyApp.Cart`, `MyApp.Cart.add/2`).
- `test`: one test case (`test:MyApp.CartTest: totals: an empty cart totals nothing`).
  A `describe` group is not an end; each test in it is.
- `class`: a kind of code the spec deliberately doesn't describe (`classes:` in config).

**Relations** have a type and two ends:
- `implements` code → spec · `verifies` test → spec · `tests` test → code (the test calls
  it) · `refines` spec → spec (a unit inside a section) · `depends_on` · `excuses` class → code.

**The log** (`.surfex/`) records each relation as entries, each at its ends' hashes, with
who, when, the commit and a note. The **tip** is the entry no later entry names as its
parent; it is the judgement in force. Nothing is edited or deleted; `mix surfex.log
--verify` detects tampering.

**States**, derived from the tip against the current scan:
- `current`: both ends at the recorded hashes.
- `dangling`: an end changed since; the report names which.
- `orphaned`: an end is no longer scanned (removed or renamed: see `move`).
- `planned`: recorded before its end existed (`relate --planned`).
- `conflicted`: two tips recorded without seeing each other (parallel branches).
- `retired`: put to rest.

**Basis**, how the tip was validated: `evidence` (test runs), `review` (a test judged
against the unit and run green), `judgement` (named by hand with a note; never for
implements), `baseline` (an adopted, trusted suite), `proposed` (a claim nothing has
validated: a citation, a tag before its failing run). A current `implements` or `verifies`
without a validating basis is **unvalidated**.

**Flags** reported beside states: new (in no relation), unmet (`require:` says it must
relate), broken (a tag naming no spec unit), broken citation (the spec names code that
doesn't exist), unproven (evidence doesn't bear a confirmation out), undeclared (a test no
longer tags the unit it verifies), triangle gaps (a unit, its tests and its code don't meet),
impacted (a `depends_on` end isn't current; information only), marks (`mix surfex.info marks`).
