# 02 — Wire format

## 1. Common header — 8 bytes

| Off | Field | Meaning |
|---|---|---|
| 0 | `kind` | the packet type |
| 1 | len | payload length |
| 4 | **seq** | sequence number |

## 2. Packet types

| Type | Value | Direction |
|---|---|---|
| PING | `0x01` | either |
| PONG | `0x02` | either |

## 3. PING — 24 bytes

| Off | Field | Meaning |
|---|---|---|
| 0 | common | the common header |
| 8 | stamp | send time |
| 12 | `ack.id` | a piggybacked acknowledgement |
| 20 | window | the sender's receive window |

The `window` in a PING is the header field, not the parameter.
