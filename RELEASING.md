# Releasing Surfex

How a release is cut, and why the steps are shaped the way they are.

This is a maintainer document. It is deliberately **not** in the package's `files:`, not in
the docs, and not linked from `README.md`. The README ships in the package and renders as
the docs front page, so a link to a file that does not ship would be broken in the
published docs.

The tool is `~/Projects/claude-tools/release.exs`, and `release.exs --help` carries the
model in full. It is project-agnostic; nothing in it is specific to Surfex. ExTLA's
`RELEASING.md` is the reference write-up, with the worked examples.

## Two kinds of release

**Minor** (`v0.2.0`, `v0.3.0`) is a judgement call: the public surface moved. New public
API, or a contract that tightened so that a call which succeeded before can now fail,
makes a release a minor however small the diff. It is always explicit: `--minor`.

**Patch** (`v0.2.7`) is not a judgement call. The number is the commit count since the
minor line's `.0` tag, so nobody has to remember the last one and two people cannot pick
the same one:

```
git describe --match 'v[0-9]*.[0-9]*.0' --long   →   v0.2.0-17-gabc1234   →   v0.2.17
```

Only `.0` tags are counted from. Plain `git describe` counts from the *last* tag, which
would reset at every patch tag and number the next one backwards. So **opening a minor line
means tagging its `.0`**, even when nothing is released from that commit.

The numbers are monotonic and unique, but not dense: merge commits count, so numbers skip.

## The lifecycle

Between releases `mix.exs` reads `X.Y.Z-dev`, and the changelog collects entries under
`[Unreleased]`. A work item that changes behaviour adds its entry there.

| Step | What it does | Lands how |
|---|---|---|
| `release.exs` | dry run: the version and every gate. Acts on nothing | — |
| `release.exs --prepare` | writes the version into `mix.exs`, closes `[Unreleased]` as `[X.Y.Z] - date`, commits | MR |
| `release.exs --tag` | annotated tag on the merged commit, push, GitLab release | direct |
| `release.exs --post-bump` | `mix.exs` → the next `-dev`, reopens `[Unreleased]` | MR |

Add `--minor` to the dry run, `--prepare` and `--tag` when opening a minor line.

`--prepare` and `--tag` are separate because the tag must point at a commit that *carries*
the version, and a protected `main` cannot take that commit directly: commit, merge,
then tag the merge commit.

The gates, all reported together by the dry run: a clean tree, a patch number that is not
zero (a minor is explicit), a tag that does not exist yet, **a green pipeline for HEAD**,
a non-empty changelog entry, and `@version` in `mix.exs`.

## Publishing to GitHub

Releases are public at <https://github.com/dcoai/surfex>, with their **history**: every
commit from v0.2.8 on, replayed from a cut. GitLab (`origin`) stays the source of truth:
CI, issues, merge requests and work between releases. GitHub (`github`) moves only at a
release.

Why a cut: the history before v0.2.8 holds material that was never surfex's to publish (a
fixture captured from a private project, since removed). GitHub's first commit is a snapshot
of v0.2.8, and every later commit is replayed onto it with its own tree, message, author and
dates. The replay is deterministic, so each release replays the same prefix and is a plain
fast-forward; GitHub's commit ids differ from GitLab's, nothing else does.

The tool is `~/Projects/claude-tools/publish_history.exs` (project-agnostic; `--help` has
the model). After the release is tagged and the tag's pipeline is green:

```sh
git remote add github git@github.com:dcoai/surfex.git     # once per clone

elixir ~/Projects/claude-tools/publish_history.exs vX.Y.Z --remote github \
  --cut v0.2.8=b9900a5 --forbid 'test/fixtures/h[o]ma_reference' --dry-run
elixir ~/Projects/claude-tools/publish_history.exs vX.Y.Z --remote github \
  --cut v0.2.8=b9900a5 --forbid 'test/fixtures/h[o]ma_reference' --yes
```

It refuses, before pushing anything, when:
- the tag's newest pipeline isn't green
- GitHub already has the tag
- GitHub's `main` isn't an ancestor of the replayed tag (not a fast-forward)
- a `--forbid` pattern matches a path, an added or removed line, or a message of any commit
  about to be published

`--forbid` is a regex, checked against history, not a tree: a file added and later deleted
is published too. The pattern names the private fixture's path, written so as not to contain
the word `test/surfex/published_content_test.exs` forbids, since this file is published too.

`publish_snapshot.exs` published releases up to 0.6.2 as one snapshot commit each. Its chain
was replaced on 2026-10-11; it would refuse or diverge now, so don't use it.

## Publishing to Hex

surfex is on Hex as `surfex`. A version is published from a **clone of the GitHub tag**, never
from the working checkout: after `--post-bump` that one's `mix.exs` reads `-dev`, and the tag
is what users can see the package was built from.

```sh
git clone --branch vX.Y.Z git@github.com:dcoai/surfex.git ~/Projects/surfex-vX.Y.Z
cd ~/Projects/surfex-vX.Y.Z
mix deps.get
mix hex.build            # optional: check the version and the file list
mix hex.publish          # the maintainer, with their Hex key
```

The package's `files:` in `mix.exs` decide what ships. This file, the tests and the relation
log don't.

## What stays a human decision

- **When to release**, and whether it is a minor.
- **The changelog's content.** The tool closes a section; it never writes one. The
  release's intro paragraph (what the release is about, and what upgrading asks of a
  project) is written by hand. It replaces the `-dev` paragraph under `[Unreleased]`
  before `--prepare`, and with the entries it becomes the tag's message.
- **Publishing**, to GitHub and to Hex: each is a separate step, after the tag (above).
- **The notices** to surfex's users (below).

## Before a release: no unit re-versions by accident

Every relation a project records holds its two ends' versions, so a release that versions
the same spec text or code differently dangles every relation to it on the upgrade (spec
§23.3). Status counts don't show it, since a project's own upkeep re-records the relations
and hides it: #305 re-versioned every marked table, unnoticed until the 0.11.0 pre-release
check (#338). So before every release, compare every unit's version under the last tag and
under the release candidate, for every project that uses surfex:

```sh
git worktree add /tmp/surfex-last vX.Y.Z && (cd /tmp/surfex-last && mix deps.get)   # the last release
elixir ~/Projects/claude-tools/surfex_unit_versions.exs /tmp/surfex-last . --discover ~/Projects
git worktree remove /tmp/surfex-last
```

It is read-only on every project, prints `NAME: re-versioned N, gone G, new A` per project,
and exits 1 on any difference. A difference is either one this release means, named in the
CHANGELOG with an upgrade step (and the literal in `test/surfex/unit_versions_test.exs`
recomputed under the release), or a bug to fix before releasing.

## A release, end to end

In order. `LAST` is the previous release's tag, `X.Y.Z` the one being made.

1. **No unit re-versions by accident** (above):
   `surfex_unit_versions.exs` against `LAST`, read every difference.
2. **The changelog's intro**, on a release branch (`release-X.Y.Z`): replace the `-dev`
   paragraph under `[Unreleased]` with the release's intro and its upgrade notes. Commit.
3. **Push the branch and wait for its pipeline.** `--prepare` checks the pipeline of HEAD
   by sha, and a commit nobody pushed has none.
4. **The dry run, then prepare** (add `--minor` to both for a minor):
   ```sh
   elixir ~/Projects/claude-tools/release.exs              # says vX.Y.Z; every gate listed
   elixir ~/Projects/claude-tools/release.exs --prepare    # mix.exs + [X.Y.Z] - date, committed
   ```
   Push, open the MR, let it go green, merge.
5. **Tag main's merge commit**, once main's pipeline for it is green:
   ```sh
   git checkout main && git pull
   elixir ~/Projects/claude-tools/release.exs --tag --version X.Y.Z     # a patch
   elixir ~/Projects/claude-tools/release.exs --tag --minor             # a minor (X.Y.0)
   ```
   `--tag` asks for confirmation on stdin (a tag is permanent); `--yes` skips it.
6. **Wait for the tag's pipeline**, then publish to GitHub: `publish_history.exs`, the dry
   run first, then `--yes` (above).
7. **Reopen development** on a branch, then MR and merge:
   ```sh
   elixir ~/Projects/claude-tools/release.exs --post-bump --version X.Y.Z   # → X.Y.(Z+1)-dev
   ```
8. **Publish to Hex** from the tag's clone (above).
9. **Send the notices** (below).

**Pin a patch's version after `--prepare`.** The patch number is a commit count, and the
prepare commit plus its merge commit add two. Run bare, `--tag` computes a number two higher
than the one prepared, and refuses because the changelog has no section for it.
`--version X.Y.Z` tags what was prepared, and `--post-bump` needs it to name the next `-dev`.
A minor needs no pin: `--minor` always means the next `.0`.

## After a release: notices

Each project that uses surfex hears of a release in its own issue tracker, not on surfex's:
a note only on a surfex issue reaches nobody. List the users fresh each time, never from the
last notice:
- every local checkout whose `mix.exs` names `:surfex`, or that has `.surfex.exs` or
  `.surfex/`, leaving out surfex's own clones and worktrees;
- every project in the GitLab group, subgroups included (`include_subgroups=true`), whose
  `main` names `:surfex` in `mix.exs` or has a `.surfex.exs`: this finds projects with no
  local checkout. A project keeping `mix.exs` below its root is missed by both; keep those
  from the previous list.

Skip a project that has already taken the release. Each notice says what the release changes
for that project, measured where it can be (its `mix surfex.status` under the new version),
and links the CHANGELOG section.

## When a release pipeline fails

Don't publish past a failure. Retry the job once: a flake passes on the retry, and a real
failure fails again the same way. A failure that reproduces is fixed before the release,
through the usual change process.

The flakes seen on release pipelines so far, and what settled them:
- the evidence-check linearity guards (#268): reductions counted garbage collection under
  load. Settled by `Surfex.Test.Work.reductions/1`, which measures in a fresh process sized
  so no collection runs;
- `DeviationHoldsTest` (#310): two recordings a second apart got different ids. Settled by
  passing the same `at:` to both;
- the suite's own-log guard (#341): a CI run once saw the committed log change during the
  suite. Not reproduced; the guard now fails the run and names the file, so a repeat says
  where to look.

A new one goes the same way: reproduce it, find the cause, file it.
