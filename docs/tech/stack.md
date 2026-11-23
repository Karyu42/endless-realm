# Endless Realm — Tech Stack Proposal

**Audience:** Chief of Staff, Karyu, ER Gameplay Engineer  
**Date:** 23 Nov 2026 (Europe/Vienna)  
**Status:** Accepted.

**Constraints:** Godot **4.7.2-stable** (4.8 is still beta) plus matching export templates. Client in **typed GDScript** (Godot 4 C# cannot export to web; Android C# is experimental). Targets: Windows / Linux / macOS + Android; no iOS; web export is a nice-to-have. Authoritative Go server; portal opener sets that instance’s level multiplier (0.5–1.5 in v0.1, locked at open); no level cap; endless gear tiers; everything except cosmetics is farmable; no paid cosmetics at first playable.

## Decisions

Confirmed by Karyu, 2026-11-23:

1. **Client:** Godot 4.7.2-stable, typed GDScript, matching export templates. Web export is a nice-to-have (locks WebSocket/WebRTC in, and keeps us off Godot C#).
2. **Server language:** Go.
3. **Auth at first playable:** email + password only.
4. **Level multiplier:** 0.5–1.5 for v0.1 (per [PR #1](https://github.com/Karyu42/endless-realm/pull/1)), **locked once the portal opens**.
5. **Hosting budget:** deferred. First playable runs locally via Docker Compose; a VM is decided later when we need one.
6. **Paid cosmetics:** none at first playable.

**Considered (settled for now):** Rust and headless Godot as server languages (density vs. sim-code reuse); C# / .NET (rejected — fights web export and Android maturity); Discord/Google OAuth at first playable (defer); a paid cosmetic / Prism currency surface at first playable (defer, later-phase in PR #1); picking a paid host/VM now (Hetzner / Fly.io / Railway remain options when a box is needed).

**Engineers can decide (unless Karyu objects):** tick 20 Hz and the units/angle table below; protocol v1 handshake; WebSocket + Protobuf (`godobuf` on the client); JSON `data/` pack; `GameSession` / `WorldSource` client shape; PostgreSQL + transactional vault/idempotent grants; in-process instance rooms first; GUT 9.7.1 CI shape; PCG32 + golden-fixture pattern tests; the anti-cheat basics below.

## Agree first (client + server)

Lock these before implementation. A connect **version handshake** disconnects on mismatch with a clear error; breaking wire changes bump the protocol version.

| Item | Agreement |
|---|---|
| Protocol version | `u16` in the first message both ways; current = `1` |
| Tick rate | **20 Hz** (50 ms) authority. Same rate for client input sampling, `LocalSim`, and server sim. Client **renders at display rate**. |
| World units | Sim and wire: `float` **1.0 = one tile**. Client constant **`TILE_PX = 16`** (16 px source art) defined in one place; art scale is not restated elsewhere. |
| Axes / angles | **Godot 2D convention on the wire and in the sim**, including the Go server — **no sign flips.** +X = 0 rad, **+Y down**, positive angle = **clockwise on screen**. |
| Time | Sim events and pattern spawns use **tick index** (`u32`), not milliseconds. |
| Numeric precision | **float64** for all sim math (GDScript floats are 64-bit). **float32 only on the wire.** |

## Headline stack

- **Client:** Godot 4.7.2-stable, typed GDScript, matching export templates. Autoload `GameSession` owns a `WorldSource`: `LocalSim` (offline, in-process, steps at 20 Hz) and `NetClient` (input frames out; snapshots/events in; prediction + reconciliation for self; interpolation buffers for others). Gameplay/render nodes only read entity state and emit input intents; they interpolate between 20 Hz ticks, and evaluate bullets analytically at render time. Sim (movement, pattern evaluation, damage, loot, XP) lives in plain classes, not Nodes. Tests: **GUT 9.7.1**; CI runs `godot --headless --import` first and fails if tests did not actually run.
- **Server:** Go (single static binary). **Do not use Godot’s high-level MultiplayerAPI** (that would only apply if the server were headless Godot, which it is not).
- **Transport:** WebSocket first (desktop + Android + web). Leave a transport interface so desktop can add UDP/QUIC later. Do not use raw ENet as the only path (no web).
- **Wire:** Protobuf. Client codec: **godobuf** (codegen from the same `.proto` files as Go), with **fixture round-trip tests** against the Go codec. Shared *game data* (items, enemies, patterns, XP) is versioned JSON in `data/`, loaded by both sides — not compiled shared code.
- **Tick / netcode:** 20 Hz authoritative sim. Client sends `(move, aim, fire_held, seq)` each tick. Bullets are deterministic **closed-form** patterns — server broadcasts pattern *spawns*, not per-bullet state. Hits, loot, and XP are server-only.
- **Instances:** Opening a portal creates an instance and **locks** the opener’s level multiplier in **[0.5, 1.5]** server-side (HP/damage, loot, XP, currencies).
- **Accounts / DB / ops:** Email + password and session tokens; PostgreSQL with transactional vault/currency ops; first playable is **one-command Docker Compose** locally.

## Server language / runtime

**Pick:** Go — fast to ship accounts, instances, and persistence; great concurrency; one small binary; easy Compose. Fits `WorldSource` / `NetClient` (the client is not coupled to a Godot server). Sim logic is ported in plain classes + shared JSON data; drift is managed by golden-fixture tests.

**Considered:** Rust (Tokio) for CPU density, steeper path to a first playable; headless Godot (typed GDScript) for sim-code reuse, but heavier per instance and weaker MMO ops, with the server tied to the engine/export-template version (MultiplayerAPI would only be in play under this option). Revisit headless Godot only if sim drift becomes painful. C# / .NET skipped unless we drop web and move the client to C#.

## Transport, protocol, shared data

**Pick:** WebSocket + Protobuf. Godot 4 has `WebSocketPeer` on desktop, Android, and web. Schema in `proto/`; generate Go structs and a **godobuf** GDScript codec from the same files. Round-trip fixtures must encode/decode identically on Go and GDScript.

**Considered:** a small hand-written binary codec if godobuf is a poor fit for 4.7.2 (still fixture-tested against Go); WebRTC data channels (UDP-like, NAT traversal, works on web, more ops); QUIC/UDP for desktop + WebSocket fallback (later, not a start). Raw ENet/UDP is not the only transport (no web export); fine as a later desktop path.

**Shared data:** items, enemies, bullet patterns, loot tables, and the XP curve live in versioned JSON under `data/` with a JSON Schema. Both Godot and the Go server load the same files. No shared compiled library in v1. YAML is an alt if designers prefer it; JSON is easier to validate in CI.

## Tick rate, netcode, bandwidth, hit validation

- Fixed **20 Hz** authority. Client **renders at display rate**. `LocalSim` also steps at 20 Hz. Render nodes interpolate between ticks; bullets are **evaluated analytically at render time**. Alt: 30 Hz authority if instances stay tiny and melee needs to feel snappier — engineer can try 20 and bump.
- Client samples input at the sim tick, stamped with `seq`. Server is authoritative for positions, damage, loot, XP.
- **Own movement:** prediction + reconciliation against server snapshots.
- **Others:** interpolate from `NetClient` buffers (~100 ms interpolation delay).
- **Projectiles:** never replicate each bullet. Server emits `PatternSpawn { id, pattern_id, seed, spawn_tick, origin, params, source_id }`. Positions are a **closed-form** `f(spawn_tick, t, params)`, not integrated frame-by-frame. Both sides use **PCG32** with a **fixed seeding rule** — not Godot `RandomNumberGenerator` and not Go `math/rand`. Shared **golden-fixture tests:** the same pattern JSON + seed must yield the same positions at tick N in Go and GDScript within an epsilon. Client is visual; **only the server applies hits**.
- **Hit validation:** server tests collisions with **swept or sub-stepped** checks **between ticks** so fast bullets cannot tunnel through a player. Use a short **position history** (≈100–200 ms rewind) so latency does not make grazing impossible. Reject hits that miss the pattern math, ignore client-reported damage, cap input rate, and sanity-check speed/teleports against move stats. No trust of client loot or XP.
- **Interest:** a portal instance is a small room — broadcast the instance. Nexus/hub should use area-of-interest if it grows past a handful of players.

**Bandwidth (order of magnitude):** inputs ≈ 20–30 bytes × 20 Hz ≈ 0.5 KB/s up. Down: ~N players × ~32 bytes/tick plus occasional pattern spawns (not bullet streams). An 8-player instance is a few KB/s. Per-bullet replication would explode in a bullet-hell.

## Instances, portals, level multiplier

**Pick:** Hub (nexus) + instanced dungeons.

1. Player requests `OpenPortal` with a **level multiplier in [0.5, 1.5]** (v0.1, per PR #1). The server authenticates, rate-limits, and **locks** `multiplier` (and an instance seed) on a new instance record. The opener cannot change it after start.
2. A gateway or instance manager places the instance on a worker (in-process rooms first; separate processes when a box is busy). Players join through the portal; the instance has a max party size and a TTL.
3. **Multiplier is applied only server-side** to enemy HP and damage, loot table rolls / drop quantity, XP, and farmable currency grants. The client may display the multiplier; it must not compute rewards. Gear tier rolls use the same locked value.
4. The instance is ephemeral. Persistence happens when loot/currency/XP is granted to a character (transactional). On crash or expiry, unlooted ground drops are gone unless we later add a short recovery window.

**Considered:** one process per instance from day one (simpler isolation, worse density); sharding the hub across workers early (not needed until nexus is crowded).

## Accounts, persistence, anti-dupe, anti-cheat

**Accounts:** email + password only at first playable, hashed (Argon2id), opaque session tokens. Android uses the same account (no device-only progress that can be copied). **Considered:** Discord/Google OAuth, later — not in the first playable. No paid-cosmetics / payment surface at first playable.

**DB:** PostgreSQL for accounts, characters, vault, inventory, currencies, and audit/grant logs. Redis optional later for sessions and presence (not required for v1). **Considered:** SQLite for local-only prototypes — not the production economy store.

**Atomic currency / vault / anti-dupe:** every item has a server-issued id. Vault deposit/withdraw, trades, and currency debits/credits run in a **single Postgres transaction** with row locks (`SELECT … FOR UPDATE`). Loot and reward grants carry an **idempotency key** (instance id + drop id, or grant id) so a retry cannot duplicate items or currency. The client never says “give me this item”; it says “I loot entity X” and the server decides. Disconnect mid-move must roll back or complete, never fork.

**Anti-cheat basics (economy integrity first):** authoritative combat and rewards; movement speed caps; input flood limits; pattern-math hit checks (swept/sub-stepped); portal-open and vault-op rate limits; append-only grant/spend log for later anomaly review. Deeper heuristic anti-cheat can wait.

## Hosting and local dev

**First playable:** `docker compose up` (or `make dev`) starts Postgres and the game server and prints the Godot connect URL (`ws://localhost:…`). One command. Godot stays on the host and points at that URL. **No VM until we need one;** hosting budget is deferred.

**CI:** client — Godot 4.7.2-stable, `godot --headless --import`, then GUT 9.7.1, and fail if tests did not actually run. Shared pattern golden fixtures run on both Go and GDScript. Protobuf round-trip fixtures run against both codecs. Server — `go test` plus a compose integration job.

**Later (when a host is needed):** one small VM (Hetzner / Fly.io / equivalent) running the Go binary + TLS, plus managed Postgres. Scale path: thin gateway in front of instance workers; Postgres remains the source of truth; add Redis for presence; autoscale workers by live instance count. No Kubernetes until a single box is actually full.

**Considered:** Railway/Render for even less ops (costlier at scale); a Godot-only VPS only if we had picked headless Godot.

