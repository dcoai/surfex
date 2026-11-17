# Failures: each test's history, without reruns

A flaky test isn't proven fixed by running the suite many times: a green streak on a
quiet machine says little about a loaded one. Surfex keeps the runs where each test's
result **flipped**, and says what differed at each one.

- With `Surfex.ExUnitFormatter` in `test/test_helper.exs` and a `.surfex/` log, every
  `mix test` appends one line per flipped test to `.surfex/transitions.log`. It's committed
  and union-merged like the log. A stable suite writes nothing, and a test that stays red
  writes one line.
- A line holds the test's version, both results, the commit, and what **changed** since
  the run with the opposite result: the test, or which code. A pass→fail line also holds the
  failure: its kind, first line, place, seed and a stable digest. A fail→pass line holds how
  many failed runs it ended.

Read the history:

```
mix surfex.failures                        # every test that ever failed
mix surfex.failures "test:MyApp.CartTest: totals"
mix surfex.failures --json                 # for a tool or an agent
```

Each flip's class:
- `nondeterministic`: the test and all the code it reaches were at the same versions on
  both sides, shown with no rerun. Either it's a flake, or something no version holds
  changed: a file the test reads, the environment, or code the scanner doesn't reach.
- `code changed`: the named code differed. A pass→fail is a regression, a fail→pass a fix.
- `test changed`: the test itself differed.
- `recurred`: the same failure (by digest) came back after a fail→pass that changed code.
  The fix didn't hold.
- `new` / `unknown`: there was nothing to compare against (the evidence went with a clean
  build).

CI can't commit, so a CI job writes its flips to an artifact. Set the variable and keep the
file:

```yaml
test:
  variables:
    SURFEX_TRANSITIONS_OUT: ci-transitions.log
  script:
    - mix test
  artifacts:
    when: always
    paths: [ci-transitions.log]
```

Then read a job's file into the report with `mix surfex.failures --merge
ci-transitions.log`. To keep it, add it to the history with `mix surfex.failures --ingest
ci-transitions.log`, which appends only the lines not already there, and commit.

The classes are evidence for a judgement, not verdicts. Record yours, so the next look
starts from it:

```
mix surfex.failures --judge "test:MyApp.CartTest: totals" \
  --note "flake: shared ETS table; fixed by a table per test, regression test added"
```

A flake fix then needs:
- its root cause;
- the fix at that cause;
- a regression test that went red before the fix and green after;
- one normal run.

If it comes back, its next pass→fail is classed `recurred`. Surfex never reads or writes
an issue tracker for this: open or reopen issues from the report yourself.
