# A data-only Surfex.Trace over the invented Wren reference (items.exs) and its spec
# (sources/). It exercises every feature a trace has, so its rendered golden (expected.md)
# guards Cite, Coverage and Trace end to end.
wire = "spec/02-wire.md"

[
  # ── The trace ─────────────────────────────────────────────────────────────
  scanner: WrenScanner,
  output: "REFERENCE_TRACE.md",
  purpose: "Every item the Wren reference declares, and the spec that covers it.",
  task: "wren.trace",
  gate: "wren-trace-drift",
  item_noun: "reference items",
  locus_prefix: "ref",
  not_catalogued: [{"static helpers", "one translation unit's detail, not the protocol"}],
  groups: [
    wire_struct: "Structures",
    wire_field: "Fields",
    packet_type: "Packet types",
    const: "Constants",
    param: "Parameters",
    function: "Functions"
  ],
  prose: [
    "A row per item the reference declares; `Cited by` is sections, a class, or GAP.",
    {:not_catalogued, "Knowingly not catalogued"},
    {:known_external, "Cited but outside the reference"},
    {:classes, "Why a row may read `— <class>`"},
    {:documented_absences, "Naming what the reference does not have"}
  ],

  # ── The profile ───────────────────────────────────────────────────────────
  sources: ["spec/**/*.md", "notes/**/*.md"],
  shape: ~r/^(wren|WREN)_[A-Za-z0-9_.]*$|^wren\.[ch]$/,
  known_shape: ~r/^[A-Z_][A-Z0-9_]{3,}$/,
  normalise: [{~r/^struct\s+/, ""}, {~r/\(\)$/, ""}],
  subjects: [
    %{file: wire, heading: ~r/^1\.\s/, items: ["wren_hdr"]},
    %{file: wire, heading: ~r/^3\.\s/, items: ["wren_ping_hdr"]}
  ],
  table_columns: ["Field", "Type"],
  file_targets: [:item_files],
  file_labels: [{~r{^spec/(\d+).*$}, "spec/\\1"}],
  known_external: %{"wrend" => "the relay daemon, outside the reference"},
  documented_absences: %{{"wren_retry", "notes/retry.md"} => "the note is about its absence"},
  classes: [
    {"reference prose", "tracked for drift, not coverage"},
    {"members of a documented structure", "covered by the structure's row"},
    {"internal constants", "the reference's own factoring"},
    {"locking", "concurrency with no wire consequence"}
  ],
  rules: [
    %{class: "reference prose", kinds: [:prose]},
    %{class: "members of a documented structure", kinds: [:wire_field], parent_cited: true},
    %{class: "internal constants", kinds: [:impl_const]},
    %{class: "locking", kinds: [:function], name: ~r/_lock$/}
  ],
  never_excused: [:wire_struct, :packet_type, :param]
]
