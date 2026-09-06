# zancudo

[![CI](https://github.com/nico-alvz/zancudo/actions/workflows/ci.yml/badge.svg)](https://github.com/nico-alvz/zancudo/actions/workflows/ci.yml)

An ultra-high-performance, strict-security **MQTT broker written in Zig**,
wire-compatible with **MQTT v3.1.1 and v5.0**.

It is engineered to remove the structural ceilings a Mosquitto-style C broker
runs into: hidden allocations, a single global subscription table, and a
readiness loop that cannot use the newest kernel I/O interfaces.

## Architecture

| Concern | Approach | Where |
| --- | --- | --- |
| Per-session memory | An **arena allocator per connection**; the whole region is freed in one call on disconnect. Zero hidden allocations on the data path. | `src/net/connection.zig`, `src/core/session.zig` |
| Async I/O | A **kernel event-loop reactor**: `io_uring` on modern Linux (via `IORING_OP_POLL_ADD`), automatic **`epoll`** fallback, **`kqueue`** on BSD/macOS. | `src/io/reactor.zig`, `src/io/linux.zig`, `src/io/kqueue.zig` |
| Network → router hand-off | A **bounded lock-free MPMC queue** (Vyukov algorithm). No mutex on the data path. | `src/core/lockfree.zig` |
| Topic routing | A **cache-oriented radix tree** keyed by topic *level*; exact children in a contiguous segment-sorted array (binary search), dedicated `+` / `#` slots. Reserved-topic (`$SYS`) rules enforced. | `src/core/radix_tree.zig` |
| Protocol constants / parsing | `comptime` enums, fixed-header masks, property table, and a `comptime` varint length function. | `src/protocol/mqtt.zig`, `src/protocol/varint.zig` |
| Packet decoding | A single bounds-checked `Reader` choke point; every network length is checked against `src/security/limits.zig` before a byte is copied. Returns structured errors, never panics. | `src/protocol/reader.zig`, `src/protocol/decoder.zig` |
| Persistence | A lightweight **`mmap` write-ahead log** (append-only, CRC-per-record) for retained messages and QoS 1/2 session state. | `src/persist/wal.zig` |
| Resilience | **Local-first mesh** scaffold: shard ownership by first topic level, `ownsLocally()` gate, hooks for gossip + automatic shard re-homing on node death. Single-node today. | `src/cluster/mesh.zig` |
| Fuzzing | Harness targeting frame decoding: no out-of-bounds read, no panic, decoder/encoder round-trip agreement. | `fuzz/fuzz_decoder.zig` |

## Directory layout

```
build.zig            build graph (build / run / test / fuzz + -Dsanitize, -Dio-backend)
build.zig.zon        package manifest
src/
  main.zig           entry point, CLI, signal handling
  config.zig         configuration + arg parser
  broker.zig         reactor loop, connection table, MQTT <-> router commands
  protocol/
    mqtt.zig         comptime protocol constants (v3.1.1 + v5.0)
    varint.zig       remaining-length variable byte integer
    reader.zig       bounds-checked cursor (the trusted parsing choke point)
    decoder.zig      frame splitting + CONNECT / PUBLISH / SUBSCRIBE parsers
    encoder.zig      CONNACK / SUBACK / PUBACK... / PUBLISH encoders
  io/
    reactor.zig      backend-agnostic readiness interface
    linux.zig        io_uring (+ epoll fallback)
    kqueue.zig       BSD / macOS backend
  net/
    listener.zig     non-blocking TCP listener (REUSEPORT, TCP_NODELAY)
    connection.zig   per-connection arena, rx reassembly, tx queue
  core/
    lockfree.zig     bounded lock-free queue
    radix_tree.zig   topic radix tree with + / # matching
    session.zig      session state, subscriptions, inflight window
    router.zig       single-threaded central router
  persist/
    wal.zig          mmap append-only write-ahead log
  cluster/
    mesh.zig         local-first mesh layer (scaffold)
  security/
    limits.zig       hard, comptime buffer limits enforced by the decoder
tests/               unit + integration tests (zig build test)
fuzz/                fuzz harness (zig build fuzz)
```

## Build & run

Requires **Zig 0.14.x**.

```sh
zig build                 # compile the broker
zig build run -- --port 1883
zig build test            # unit + integration tests
zig build fuzz            # build the frame-decoder fuzz harness
```

### Security-oriented build options

```sh
zig build -Dsanitize=true            # UBSan trap handler + ASan for linked C
zig build -Doptimize=ReleaseSafe     # keep all safety checks in an optimized build
zig build -Dio-backend=epoll         # force a reactor backend (auto|io_uring|epoll|kqueue)
```

Zig code is checked against undefined behaviour by default in `Debug` and
`ReleaseSafe`; the decoder is written so that malformed input is always a
returned error, never a trap.

## Status

Implemented and tested: protocol constants, varint, bounds-checked reader,
frame decoder/encoder, radix tree (with the OASIS wildcard examples), lock-free
queue (incl. a concurrent producer test), session bookkeeping, the WAL, and the
router fan-out. The reactor loop and broker wiring compile and run as a
single-threaded server. Mesh gossip/transport and full QoS 2 flow persistence
are marked `TODO` in-source.

## License

MIT — see [LICENSE](LICENSE).
