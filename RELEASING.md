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

Releases are public at <https://github.com/dcoai/surfex>. They get there as **snapshots**,
not as history. GitLab (`origin`) stays the source of truth: CI, issues, merge requests
and every commit. GitHub (`github`) gets one commit per release.

Why not push the branch: pushing publishes everything reachable, and this repository's
history holds material that was never surfex's to publish (a fixture captured from a
private project, since removed). A snapshot commit's tree is exactly the release tag's
tree, and its parent is the previous release on GitHub, so nothing else from GitLab's
history is reachable there.

The tool is `~/Projects/claude-tools/publish_snapshot.exs` (project-agnostic;
`--help` has the model). After a release is tagged:

```sh
git remote add github git@github.com:dcoai/surfex.git     # once per clone

elixir ~/Projects/claude-tools/publish_snapshot.exs vX.Y.Z --remote github --forbid 'h[o]ma' --dry-run
elixir ~/Projects/claude-tools/publish_snapshot.exs vX.Y.Z --remote github --forbid 'h[o]ma'
```

It refuses, before pushing anything, when:
- the tag's pipeline isn't green
- GitHub already has the tag
- GitHub's `main` wasn't made by the tool
- a `--forbid` pattern matches any path or file in the release

`--forbid 'h[o]ma'` is the same guard as `test/surfex/published_content_test.exs`,
applied to the tree about to be published. It is written so as not to contain the word it
forbids, since this file is published too.

A GitHub tag has the same name and message as its GitLab tag, but points at the snapshot
commit. Its message ends with `Snapshot-Of: vX.Y.Z <sha>`, naming the GitLab commit it
was made from.

## What stays a human decision

- **When to release**, and whether it is a minor.
- **The changelog's content.** The tool closes a section; it never writes one.
- **Publishing to GitHub**, which is a separate step, run after the tag (above).
- **Publishing to Hex.** Not yet. When it happens, it is `mix hex.publish` from a checkout
  of the GitHub tag, whose `mix.exs` carries the links Hex requires.

## A release, end to end

A patch on the 0.2 line (the number is derived):

```sh
elixir ~/Projects/claude-tools/release.exs                # dry run
elixir ~/Projects/claude-tools/release.exs --prepare      # then MR, merge
elixir ~/Projects/claude-tools/release.exs --tag          # on main, at the merge commit
elixir ~/Projects/claude-tools/release.exs --post-bump    # then MR
elixir ~/Projects/claude-tools/publish_snapshot.exs vX.Y.Z --remote github --forbid 'h[o]ma'
```
