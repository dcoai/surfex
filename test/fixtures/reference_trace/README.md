# reference_trace fixture

A whole trace over an invented reference implementation, "Wren", a tiny packet protocol
in C, and its spec. It belongs to surfex and exists to exercise every feature a trace has,
failure paths included.

| file | what it is |
|---|---|
| `items.exs` | the items a scanner of Wren would report, as data (each commented with why it is there) |
| `sources/` | Wren's spec: subject sections, Field and Type tables, prose citations of every status, a member path, a code block |
| `trace.exs` | the trace, data only |
| `expected.md` | the golden it must render, reviewed line by line when recorded |

`test/surfex/reference_trace_test.exs` compares the render with `expected.md`, and asserts
each feature separately so that a regression names what broke.

**Changing it** is deliberate: edit the fixture, render it again, review every changed
line of `expected.md` against what the change should do, and commit both together.
