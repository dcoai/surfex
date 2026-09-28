# Surfex holds its own specification to its own code, two ways:
#
#   * the relation log (.surfex/): which spec sections and which functions were confirmed
#     to belong together, at which versions. `mix surfex.status` is the check, and every
#     public module and function must implement some section (require:).
#   * the v0.2 trace (SPEC_TRACE.md), deprecated, kept alongside until it is removed.
#
# `mix surfex.goldens` gates both goldens: SPEC_TRACE.md and RELATIONS.md.
[
  goldens: [:trace, :status],
  require: [code: [:implements]],
  sources: ["spec.md"],
  file_labels: [{~r/^spec\.md$/, "spec"}],
  purpose: "Every public module and function of Surfex, and the spec section that covers it.",
  prose: [
    """
    A row per public module and function in `lib/`. `Cited by` names the sections of
    `spec.md` that cite it. A GAP is code the spec does not describe, and the gate fails
    on any; a citation of something that does not exist fails it too.
    """
  ]
]
