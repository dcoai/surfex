# The items a scanner of an invented reference implementation, "Wren", would report: a tiny
# packet protocol written in C. Plain data, so the trace is tested without any scanner.
#
# Every item is here for a reason, noted beside it. Hashes are fixed strings: this fixture
# tests citation and coverage, not hashing.
item = fn kind, name, file, extra -> Map.merge(%{kind: kind, name: name, file: file, hash: "#{kind}"}, Map.new(extra)) end

[
  # Structures: the spec's subject matter, never excused.
  item.(:wire_struct, "wren_hdr", "wren.h", hash: "a1000001"),
  item.(:wire_struct, "wren_ping_hdr", "wren.h", hash: "a1000002"),
  item.(:wire_struct, "wren_ack", "wren.h", hash: "a1000003"),

  # Fields. `common` and `ack` are typed as other structs, so member paths walk through them.
  item.(:wire_field, "kind", "wren.h", parent: "wren_hdr", detail: "u8", hash: "b1000001"),
  item.(:wire_field, "len", "wren.h", parent: "wren_hdr", detail: "u16", hash: "b1000002"),
  item.(:wire_field, "seq", "wren.h", parent: "wren_hdr", detail: "u32", hash: "b1000003"),
  item.(:wire_field, "common", "wren.h", parent: "wren_ping_hdr", type: "wren_hdr", detail: "struct wren_hdr", hash: "b1000004"),
  item.(:wire_field, "stamp", "wren.h", parent: "wren_ping_hdr", detail: "u32", hash: "b1000005"),
  item.(:wire_field, "ack", "wren.h", parent: "wren_ping_hdr", type: "wren_ack", detail: "struct wren_ack", hash: "b1000006"),
  item.(:wire_field, "window", "wren.h", parent: "wren_ping_hdr", detail: "u16", hash: "b1000007"),
  item.(:wire_field, "id", "wren.h", parent: "wren_ack", detail: "u64", hash: "b1000008"),
  # Uncited, but its parent is cited: excused as a member of a documented structure.
  item.(:wire_field, "port", "wren.h", parent: "wren_ack", detail: "u16", hash: "b1000009"),

  # Packet types, cited from a table's Type column without backticks.
  item.(:packet_type, "PING", "wren.h", value: "0x01", hash: "c1000001"),
  item.(:packet_type, "PONG", "wren.h", value: "0x02", hash: "c1000002"),

  # Constants: one cited from inside a longer span, one excused as internal.
  item.(:const, "WREN_MAX_LEN", "wren.h", value: "1400", hash: "d1000001"),
  item.(:impl_const, "WREN_BUCKETS", "wren_impl.h", value: "64", hash: "d1000002"),

  # A parameter sharing its name with a field: inside §3 the field wins, elsewhere this.
  item.(:param, "window", "wren_params.c", value: "64", hash: "e1000001"),

  # Functions: two cited, one excused by class, one a GAP.
  item.(:function, "wren_send", "wren.c", hash: "f1000001"),
  item.(:function, "wren_recv", "wren.c", hash: "f1000002"),
  item.(:function, "wren_lock", "wren.c", hash: "f1000003"),
  item.(:function, "wren_orphan", "wren.c", hash: "f1000004"),

  # Two items sharing one key: a citation of it is ambiguous, never guessed.
  item.(:function, "wren_twin", "wren.c", hash: "f1000005"),
  item.(:impl_const, "wren_twin", "wren_impl.h", hash: "f1000006"),

  # The reference's own prose: tracked for drift, excused from coverage.
  item.(:prose, "protocol.md#Overview", "protocol.md", value: "Overview", hash: "g1000001")
]
