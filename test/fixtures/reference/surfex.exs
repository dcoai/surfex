# The relation log's config for the invented Wren reference (items.exs) and its spec
# (sources/): data only. It exercises every feature of reading citations and excusing
# code, so test/surfex/reference_test.exs guards Cite, Suggest, Coverage and Status end to
# end over one small, complete project.
wire = "spec/02-wire.md"

[
  scanner: WrenScanner,
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
