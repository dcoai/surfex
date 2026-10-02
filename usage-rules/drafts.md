# Handing off found work

Surfex finds work that isn't yours to do mid-task: marks, unmet ids, triangle gaps.
`mix surfex.draft` writes each up as a change draft for the project's own process.

```
mix surfex.draft                    # every open mark, unmet id and gap
mix surfex.draft spec.md#totals     # that unit's marks, or a draft to change it
mix surfex.draft --format json      # for tools
mix surfex.draft --file             # open each in the tracker, via process:
```

`process:` in `.surfex.exs` is `:print` (default) or `{:command, argv}`, where argv may
use `{title}` and `{body}`, e.g.
`{:command, ["glab", "issue", "create", "--title", "{title}", "--description", "{body}"]}`.
Without `--file`, nothing leaves the terminal.
