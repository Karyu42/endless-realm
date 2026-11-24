# Godot host load test (50 players at 20 Hz)

Status: early spike for stack decision 2b (player-hosted lobbies run by the
Godot game itself, one GDScript sim shared with solo, Go kept as a test
harness). Question: can a GDScript host hold 50 players at 20 Hz?

**Answer on this box: yes.** At 50 clients the host tick is 10.2 ms p50 and
16.5 ms p99 against a 50 ms budget, with 0 skipped ticks over 60 s and about
22% of one core. That is roughly 3x headroom at p99. 100 clients (test-only
override) still hold 20 Hz (28.1 ms p99).

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
  - Enemies are a **stand-in** (`HostStandinBulletField`) with 20
    emitters, each firing a 12-bullet ring every 12 ticks at 6 tiles/s with a
    2.5 s life. The real enemy/pattern rules are in `client/src/core`;
    switching the host to run them is a follow-up.
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
# 100 is test-only: the script supplies --loadtest-unsafe-max-players 100.
make loadtest-godot LOADTEST_CLIENTS=100 LOADTEST_DURATION=60
python3 tools/loadtest/godot_host_loadtest.py --clients 50 --emitters 40 --duration 30
# Open overworld entrances (practice door + 6), then the per-viewer worst case
# where every client has a distinct admitted set (needs 2^entrances >= clients).
python3 tools/loadtest/godot_host_loadtest.py --clients 50 --entrances 6
python3 tools/loadtest/godot_host_loadtest.py --clients 50 --entrances 6 --distinct-admitted
```

`viewer_snapshot_bytes_avg` / `_max` are the Snapshot bytes actually sent per
viewer (the instance's shared part plus that viewer's own fields);
`snapshot_bytes_*` is the shared overworld Snapshot only.

Results land in `loadtest-results/results.{json,md}` (git-ignored), with the
raw host and bot output in `loadtest-results/{host,bot}-<clients>.log`.
The script exits nonzero if the host never prints `HOST_READY` (it exits first,
or `--ready-timeout`, default 60 s, passes), the bot fails, any ticks are
skipped, or tick p99 exceeds 40 ms. Override the fail gates explicitly with
`--max-skipped-ticks` / `--max-p99-ms` (Make: `LOADTEST_MAX_SKIPPED_TICKS` /
`LOADTEST_MAX_P99_MS`).

## Limits

Real lobbies use `--max-players N` or `ER_MAX_PLAYERS=N`, integer 1–50,
default 50. The flag wins over the environment, even when the environment
value is invalid; the host exits 2 only if the value it actually uses is
invalid. Values are never clamped. A full lobby replies `Error INSTANCE_FULL` and
closes the extra connection. The 100-client run is **test-only**: the script
passes `--loadtest-unsafe-max-players 100` (which prints a warning). Never use
this override for real lobbies. The host keeps `max_players + 8` connection
slots (handshakes / spectator slack).

Connection limits are named constants in `LobbyHost`: a per-tick incoming
message budget, dropping excess and closing sustained excess, a rate limit
on Error replies, a five-second Hello timeout, and a total connection cap.
GUT tests cover each, including keeping observer snapshots flowing. Tests
inject a fake clock into the host for deadlines and timeouts; no wall clock
is read by the sim.

## Box

**Not a gaming PC and not a phone.** It is a shared cloud VM: 8 vCPU,
`Intel(R) Xeon(R) Processor` (model name only), 15.6 GiB RAM, Linux 6.12,
Godot 4.7.2.stable.official, Go 1.27.4. Load average before the runs was
about 0.4–1.2. Other agents share the box, so expect some noise in max
values. The host is single-threaded GDScript, so "CPU %" is percent of one
core.

## Results (2026-11-23)

Main curve: 60 s per point, 20 emitters. The 50 and 100 rows were re-run with the player cap and connection limits in place; the 8 and 25 rows are from the previous head (same sim and codec).

| clients | live bullets (avg) | tick p50 / p95 / p99 / max (ms) | net-in / sim / encode / send p50 (ms) | achieved Hz | skipped ticks | snapshot B/client/s (wire stub) | projected full-state B/client/s | host CPU % (of one core) | host RSS MiB (max) | bot ok |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | 942 | 3.11 / 4.79 / 5.34 / 11.90 | 0.84 / 1.33 / 0.85 / 0.09 | 20.02 | 0 | 1,202 | 4,708 | 7.1 | 130.1 | yes |
| 25 | 890 | 5.87 / 8.89 / 9.95 / 30.49 | 2.19 / 1.56 / 1.89 / 0.23 | 20.02 | 0 | 3,571 | 12,842 | 13.1 | 130.3 | yes |
| 50 | 821 | 10.22 / 14.69 / 16.48 / 20.94 | 4.39 / 2.12 / 3.20 / 0.48 | 20.01 | 0 | 7,034 | 24,812 | 22.2 | 131.7 | yes |
| 100 (test-only override) | 704 | 18.01 / 25.71 / 28.11 / 47.60 | 7.63 / 3.13 / 6.11 / 1.03 | 20.01 | 0 | 13,955 | 48,738 | 37.6 | 132.0 | yes |

Headroom point: 30 s, from the previous head.

| clients | emitters | live bullets (avg) | tick p50 / p95 / p99 / max (ms) | net-in / sim / encode / send p50 (ms) | achieved Hz | skipped ticks | projected full-state B/client/s | host CPU % | host RSS MiB |
|---|---|---|---|---|---|---|---|---|---|
| 50 | 40 | 1598 | 11.42 / 15.57 / 17.84 / 44.18 | 4.37 / 3.13 / 3.35 / 0.49 | 20.03 | 0 | 25,574 | 23.5 | 130.1 |

Notes:
- **Bullet count:** fewer live bullets at higher player counts is expected,
  because more of them hit someone and are removed.
- **Max outliers:** the 30–46 ms max values are isolated spikes. No tick ran late and none were skipped. They are likely
  scheduler or allocation noise on a shared VM.
- **Host upload:** at 50 players, the projected full state is about 25 KB/s
  per client, so about 1.25 MB/s (about 10 Mbit/s) total. That is fine on a
  LAN, but it matters for a home-upload host and for 100 players. Interest
  management and delta snapshots are the lever.

## Hotspots

At 50 clients the tick is about 75% codec:
- **Input decode (net-in), 4.3 ms:** godobuf costs about 85 µs per decoded
  InputFrame, and 50 arrive per tick. It was about 65 µs before the #12
  portal messages grew the ClientMessage oneof, because godobuf's generic
  parser scales with the schema.
- **Snapshot encode, 3.3 ms:** this covers the stub plus the projected full
  state.

The sim itself (50 LocalSims + about 800 swept bullets) is only 1.9 ms, and
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
- **Real enemies and rules:** the host still uses the stand-in field, not
  the shared enemy/pattern rules. No group HP scaling or rewind yet.
- **Real networks:** real network latency, loss, and TCP head-of-line
  blocking. Everything here ran on loopback.
- **godobuf names:** proto/v1 avoids names that clash in generated GDScript
  (no `instance_id` field, no `Error` message), so the generated codec is
  used unmodified.
- **Codegen check:** `make proto` / proto-codegen-check does not regenerate
  the GDScript codecs yet. Regenerate them with
  `tools/proto/gen-gdscript-proto.sh` (pinned godobuf v0.7.0,
  sha256-checked).
