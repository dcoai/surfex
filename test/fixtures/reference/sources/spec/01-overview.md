# 01 — Overview

Wren moves small messages between two peers. `wren.h` declares the whole interface.

## 1. Sending and receiving

`wren_send` queues a message and `wren_recv()` takes the next one. A message is at most
`ioctl(fd, WREN_MAX_LEN)` bytes, and `struct wren_ack` acknowledges one.

The `window` parameter defaults to 64.

```c
wren_send(sock, buf, len);
```

## 2. Not yet

`wren_send_all` is planned. `wren_twin` names two things. Messages are relayed by `wrend`,
which runs outside the reference. `:ok` and `mix test` are prose, not claims about Wren.
