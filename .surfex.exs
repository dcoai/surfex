# Surfex traces its own specification against its own code: `mix surfex.goldens`.
[
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
