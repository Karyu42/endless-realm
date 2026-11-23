# Godot host load test (50 players at 20 Hz)

Status: early spike for stack decision 2b (player-hosted lobbies run by the
Godot game itself, one GDScript sim shared with solo, Go kept as a test
harness). Question: can a GDScript host hold 50 players at 20 Hz?

**Answer on this box: yes.** At 50 clients the host tick is 9.2 ms p50 and
14.7 ms p99 against a 50 ms budget, with 0 skipped ticks over 60 s and about
20% of one core. That is roughly 3.4x headroom at p99. 100 clients still hold
20 Hz (24 ms p99).

## What runs

- **Host:** `client/src/net/host/` (`LobbyHost`, entry `host_main.gd`).
  `TCPServer` + `WebSocketPeer` (no MultiplayerAPI or RPCs) speaking
  `proto/v1` through godobuf v0.7.0 (`client/src/net/proto/protocol_v1_pb.gd`):
  Hello → Welcome (or Reject), InputFrame in, Snapshot out every tick.
  Deadline-based 20 Hz tick (`start + n * 50 ms`), catch-up capped at 5
  ticks, the rest counted as skipped ticks.
  ```
  godot --headless --path client -s res://src/net/host/host_main.gd -- --host --port 8090
  ```
- **Sim per tick:**
  - Each player is driven by the real `LocalSim` (movement, bounds, the
    Tempo fire rule and player shots), stepped through `InputIntent` like
    solo. Player shots are tested against the enemies.
  - Enemies are a **stand-in** (`HostStandinBulletField`), because main has
    no enemies or patterns yet (PR #16 adds the real ones). It has 20
    emitters, each firing a 12-bullet ring every 12 ticks at 6 tiles/s with a
    2.5 s life.
  - Bullets are closed-form: each ring is rebuilt from (seed, emitter,
    spawn_tick) with seeded PCG32 (Godot's `RandomNumberGenerator`).
  - There are about 800–940 live bullets, each hit-checked every tick with
    swept segment-vs-circle tests against all players (uniform grid with
    2-tile cells).
  - There is no lag-compensation rewind yet.
- **Snapshots:**
  - The wire Snapshot is the proto/v1 stub (tick + id/applied_seq per player)
    that the bot validates.
  - Because a real snapshot will carry positions and spawn events, the host
    also encodes a **projected full-state snapshot** every tick
    (`loadtest_state.proto`: per player id/seq/x/y/aim/hp, plus new
    PatternSpawn and player-shot events). Its encode time is included in the
    tick time, and its size is reported as "projected full-state" bytes.
  - It is not sent.
  - Everyone gets everything (no interest management).
- **Clients:**
  - The Go bot `server/cmd/bot` runs with `-input=wander`: each client walks
    a slowly turning heading, aims sideways and holds fire, 20 inputs/s.
  - The bot also checks that ticks advance and that `applied_seq` catches up.
  - The bot runs on the same box.
- **Measurement** (`tools/loadtest/godot_host_loadtest.py`):
  - Tick time and the phase split are measured by the host
    (`Time.get_ticks_usec`).
  - Stats cover only ticks while all N clients are connected.
  - CPU % and RSS come from the host's `/proc` over the steady window,
    after a 5 s warm-up.
  - Bytes are protobuf payload per client; WebSocket framing adds 2–4 B per
    message.

Run it:

```
make loadtest-godot                                   # 8, 25, 50 clients, 60 s each
make loadtest-godot LOADTEST_CLIENTS=100 LOADTEST_DURATION=30
python3 tools/loadtest/godot_host_loadtest.py --clients 50 --emitters 40 --duration 30
```

Results land in `loadtest-results/results.{json,md}` (git-ignored).

## Box

**Not a gaming PC and not a phone.** It is a shared cloud VM: 8 vCPU,
`Intel(R) Xeon(R) Processor` (model name only), 15.6 GiB RAM, Linux 6.12,
Godot 4.7.2.stable.official, Go 1.27.4. Load average before the runs was
about 0.3–0.6. Other agents share the box, so expect some noise in max
values. The host is single-threaded GDScript, so "CPU %" is percent of one
core.

## Results (2026-11-23)

Main curve: 60 s per point, 20 emitters.

| clients | live bullets (avg) | tick p50 / p95 / p99 / max (ms) | net-in / sim / encode / send p50 (ms) | achieved Hz | skipped ticks | snapshot B/client/s (wire stub) | projected full-state B/client/s | host CPU % (of one core) | host RSS MiB (max) | bot ok |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | 941 | 2.91 / 4.33 / 5.27 / 40.09 | 0.72 / 1.29 / 0.80 / 0.08 | 20.02 | 0 | 1,202 | 5,058 | 6.7 | 122.1 | yes |
| 25 | 893 | 5.26 / 7.74 / 9.11 / 10.35 | 1.70 / 1.48 / 1.84 / 0.20 | 20.01 | 0 | 3,571 | 13,939 | 11.5 | 122.2 | yes |
| 50 | 802 | 9.17 / 12.70 / 14.71 / 42.73 | 3.37 / 1.80 / 3.40 / 0.51 | 20.01 | 0 | 7,030 | 27,002 | 19.5 | 121.7 | yes |

Headroom points: 30 s each.

| clients | emitters | live bullets (avg) | tick p50 / p95 / p99 / max (ms) | net-in / sim / encode / send p50 (ms) | achieved Hz | skipped ticks | projected full-state B/client/s | host CPU % | host RSS MiB |
|---|---|---|---|---|---|---|---|---|---|
| 100 | 20 | 685 | 16.35 / 20.73 / 24.06 / 29.28 | 6.06 / 2.52 / 6.64 / 0.99 | 20.03 | 0 | 53,005 | 32.2 | 122.5 |
| 50 | 40 | 1608 | 10.79 / 13.86 / 16.71 / 20.79 | 3.67 / 3.02 / 3.48 / 0.48 | 20.03 | 0 | 27,743 | 22.2 | 122.4 |

Notes:
- **Bullet count:** fewer live bullets at higher player counts is expected,
  because more of them hit someone and are removed.
- **Max outliers:** the single 40 ms max values (at 8 and 50 clients) are
  isolated spikes. No tick ran late and none were skipped. They are likely
  scheduler or allocation noise on a shared VM.
- **Host upload:** at 50 players, the projected full state is about 27 KB/s
  per client, so about 1.35 MB/s (about 11 Mbit/s) total. That is fine on a
  LAN, but it matters for a home-upload host and for 100 players. Interest
  management and delta snapshots are the lever.

## Hotspots

At 50 clients the tick is about 75% codec:
- **Input decode (net-in), 3.4 ms:** godobuf costs about 65 µs per decoded
  InputFrame, and 50 arrive per tick.
- **Snapshot encode, 3.4 ms:** this covers the stub plus the projected full
  state.

The sim itself (50 LocalSims + about 800 swept bullets) is only 1.8 ms, and
doubling bullets to about 1,600 adds about 1.2 ms. If a heavier real sim or a
weaker host (a phone) needs room, the first levers are in this order:
1. A hand-written fixed-layout InputFrame decoder, or decoding only the
   newest input per client per tick.
2. Encoding the shared part of the snapshot once with a cheaper writer
   (`StreamPeerBuffer`) instead of godobuf's generic packer.
3. Interest management.

## Not covered yet

- **Phone and listen-server hosting:** a host on a phone, and a listen
  server rendering at the same time. The stack proposal caps phone hosts at
  8 and needs its own APK test.
- **Real enemies and rules:** the real enemy/pattern rules (PR #16), group
  HP scaling, and lag-compensation rewind.
- **Real networks:** real network latency, loss, and TCP head-of-line
  blocking. Everything here ran on loopback.
- **Codegen check:** `make proto` / proto-codegen-check does not regenerate
  the GDScript codecs yet. Regenerate them with
  `tools/loadtest/gen-gdscript-proto.sh` (pinned godobuf v0.7.0,
  sha256-checked).
