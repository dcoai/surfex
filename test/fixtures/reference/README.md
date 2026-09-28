# reference fixture

An invented reference implementation, "Wren", a tiny packet protocol in C, and its spec.
It belongs to surfex and exists to exercise every feature of reading a spec's citations and
excusing code, failure paths included.

| file | what it is |
|---|---|
| `items.exs` | the items a scanner of Wren would report, as data (each commented with why it is there) |
| `sources/` | Wren's spec: subject sections, Field and Type tables, prose citations of every status, a member path, a code block |
| `surfex.exs` | the relation log's config, data only |

`test/surfex/reference_test.exs` asserts each feature separately, so that a regression
names what broke: every citation status, the relations `mix surfex.suggest` proposes
(including excusals by class), and what `mix surfex.status` then reports as unmet and as
broken citations.
