# Endless Realm — Tech Stack Proposal

**Audience:** Chief of Staff, Karyu, ER Gameplay Engineer  
**Date:** 23 Nov 2026 (Europe/Vienna)  
**Status:** Proposal. No server code until the stack is agreed.

**Repo snapshot:** This repo was README-only on `main` (`4cfbdd0`, 23 Nov 2026 17:56 Europe/Vienna) when this was drafted: no engine, languages, design docs, issues, or PRs. Client direction is from the ER Gameplay Engineer and the CoS Godot 4 default.

**Constraints:** Godot **4.7.2-stable** (4.8 is still beta) plus matching export templates. Client in **typed GDScript** (Godot 4 C# cannot export to web; Android C# is experimental). Targets: Windows / Linux / macOS + Android; no iOS; web export is a nice-to-have. Authoritative server; portal opener sets that instance’s level multiplier; no level cap; endless gear tiers; everything except cosmetics is farmable.

## Agree first (client + server)

Lock these before implementation. A connect **version handshake** disconnects on mismatch with a clear error; breaking wire changes bump the protocol version.

| Item | Recommendation |
|---|---|
| Protocol version | `u16` in the first message both ways; current = `1` |
| Tick rate | **20 Hz** (50 ms). Same rate for client input sampling and server sim. |
| World units | `float32`; **1.0 = one tile** |
| Angles | Sim and wire: **radians** (`float32`, 0 = +X, CCW). Data JSON may use degrees and convert at load. |
| Time | Sim events and pattern spawns use **tick index** (`u32`), not milliseconds |

## Headline recommendation

- **Client:** Godot 4.7.2-stable, typed GDScript, matching export templates. Autoload `GameSession` owns a `WorldSource`: `LocalSim` (offline, in-process) and `NetClient` (input frames out; snapshots/events in; prediction + reconciliation for self; interpolation buffers for others). Gameplay/render nodes only read entity state and emit input intents. Sim (movement, pattern evaluation, damage, loot, XP) lives in plain classes, not Nodes. Tests: **GUT 9.7.1**; CI runs `godot --headless --import` first and fails if tests did not actually run.
- **Server:** Go (single static binary). Rust is the performance alternative. Headless Godot (GDScript) is the sim-reuse alternative — see below. Do **not** pick C# just to share code (fights web export and Android maturity). **Do not use Godot’s high-level MultiplayerAPI** unless the server is a headless Godot instance.
- **Transport:** WebSocket first (desktop + Android + web). Leave a transport interface so desktop can add UDP/QUIC later. Do not use raw ENet as the only path (no web).
- **Wire:** Protobuf. Shared *game data* (items, enemies, patterns, XP) is versioned JSON in `data/`, loaded by both sides — not compiled shared code.
- **Tick / netcode:** 20 Hz authoritative sim. Client sends `(move, aim, fire_held, seq)` each tick. Bullets are deterministic patterns from `(seed, spawn_tick, params)` — server broadcasts pattern *spawns*, not per-bullet state. Hits, loot, and XP are server-only.
- **Instances:** Opening a portal creates an instance and **locks** the opener’s level multiplier server-side (HP/damage, loot, XP, currencies).
- **Accounts / DB / ops:** Email + password and session tokens to start; PostgreSQL with transactional vault/currency ops; Docker Compose one-command local dev; one cheap VM + managed Postgres to ship.

## Server language / runtime

| | **Recommended: Go** | Alt A: Rust (Tokio) | Alt B: Headless Godot (typed GDScript) |
|---|---|---|---|
| Why | Fast to ship accounts, instances, persistence; great concurrency; one small binary; easy Docker/cheap VPS. Fits `WorldSource`/`NetClient` — the client is not coupled to a Godot server. | Best CPU density for busy instances; memory-safe. Steeper path to a first playable. | **Sim-code reuse:** the same plain classes `LocalSim` uses can run on a headless Godot server. MultiplayerAPI is only in play in this option. |
| Cost | Sim logic is ported (plain classes + shared JSON data). Drift is managed by tests against the same fixtures. | Slower iteration for lobby/auth/DB work. | Heavier per instance; weaker MMO ops (many rooms, Postgres-heavy economy, slim hosting). Server is tied to the engine/export-template version. |

Go stays the recommendation: `WorldSource` already isolates the client from the server runtime, and JSON data defs plus fixture tests are enough shared truth for v1. Revisit Alt B only if sim drift becomes painful. **Skip C# / .NET** unless we drop web and move the client to C#.

**Owner can decide language.** Go is the default unless Karyu prefers Rust (or, later, headless Godot).

## Transport, protocol, shared data

**Recommended:** WebSocket + Protobuf. Godot 4 has `WebSocketPeer` on desktop, Android, and web. Schema in `proto/`; generate Go structs and a small GDScript codec.

**Alts:** (1) WebRTC data channels — UDP-like, NAT traversal, works on web; more operational complexity. (2) QUIC/UDP for desktop + WebSocket fallback — better latency later; do not start here.

**Not recommended as the only transport:** raw ENet/UDP (no web export). Fine as a later desktop path.

**Shared data:** items, enemies, bullet patterns, loot tables, and the XP curve live in versioned JSON under `data/` with a JSON Schema. Both Godot and the Go server load the same files. No shared compiled library in v1. Optional later: codegen from the schema. YAML is an alt if designers prefer it; JSON is easier to validate in CI.

## Tick rate, netcode, bandwidth, hit validation

- Fixed **20 Hz** server tick. Alt: 30 Hz if instances stay tiny and melee needs to feel snappier — **engineer can try 20 and bump**.
- Client samples input at the same tick, stamped with `seq`. Server is authoritative for positions, damage, loot, XP.
- **Own movement:** prediction + reconciliation against server snapshots.
- **Others:** interpolate from `NetClient` buffers (~100 ms interpolation delay).
- **Projectiles:** never replicate each bullet. Server emits `PatternSpawn { id, pattern_id, seed, spawn_tick, origin, params, source_id }`. Both sides advance the same deterministic pattern function from data defs. Client is visual; **only the server applies hits**.
- **Interest:** a portal instance is a small room — broadcast the instance. Nexus/hub should use area-of-interest if it grows past a handful of players.

**Bandwidth (order of magnitude):** inputs ≈ 20–30 bytes × 20 Hz ≈ 0.5 KB/s up. Down: ~N players × ~32 bytes/tick plus occasional pattern spawns (not bullet streams). An 8-player instance is a few KB/s. Per-bullet replication would explode in a bullet-hell.

**Hit validation:** server steps compact pattern state each tick and tests collisions against a short **position history** (≈100–200 ms rewind) so latency does not make grazing impossible. Reject hits that miss the pattern math, ignore client-reported damage, cap input rate, and sanity-check speed/teleports against move stats. No trust of client loot or XP.

## Instances, portals, level multiplier

**Recommended:** Hub (nexus) + instanced dungeons.

1. Player requests `OpenPortal` with a **level multiplier**. The server authenticates, rate-limits, and **locks** `multiplier` (and an instance seed) on a new instance record. The opener cannot change it after start. Bounds (min/max, preset vs. free-form) are a **Karyu / Game Designer** decision.
2. A gateway or instance manager places the instance on a worker (in-process rooms first; separate processes when a box is busy). Players join through the portal; the instance has a max party size and a TTL.
3. **Multiplier is applied only server-side** to enemy HP and damage, loot table rolls / drop quantity, XP, and farmable currency grants. The client may display the multiplier; it must not compute rewards. Gear tier rolls use the same locked value.
4. The instance is ephemeral. Persistence happens when loot/currency/XP is granted to a character (transactional). On crash or expiry, unlooted ground drops are gone unless we later add a short recovery window.

**Alts:** one process per instance from day one (simpler isolation, worse density); or shard the hub across workers early (not needed until nexus is crowded).

## Accounts, persistence, anti-dupe, anti-cheat

**Accounts (recommended):** email + password, hashed (Argon2id), opaque session tokens. Alt: Discord/Google OAuth now or later — **Karyu decides** whether third-party login is required at first playable. Android uses the same account (no device-only progress that can be copied).

**DB (recommended):** PostgreSQL for accounts, characters, vault, inventory, currencies, and audit/grant logs. Redis optional later for sessions and presence (not required for v1). **Alt:** SQLite for local-only prototypes — not the production economy store.

**Atomic currency / vault / anti-dupe:** every item has a server-issued id. Vault deposit/withdraw, trades, and currency debits/credits run in a **single Postgres transaction** with row locks (`SELECT … FOR UPDATE`). Loot and reward grants carry an **idempotency key** (instance id + drop id, or grant id) so a retry cannot duplicate items or currency. The client never says “give me this item”; it says “I loot entity X” and the server decides. Disconnect mid-move must roll back or complete, never fork.

**Anti-cheat basics (economy integrity first):** authoritative combat and rewards; movement speed caps; input flood limits; pattern-math hit checks; portal-open and vault-op rate limits; append-only grant/spend log for later anomaly review. Deeper heuristic anti-cheat can wait.

## Hosting and local dev

**Local (recommended):** `docker compose up` (or `make dev`) starts Postgres and the game server and prints the Godot connect URL (`ws://localhost:…`). One command. Godot stays on the host and points at that URL.

**CI:** client — Godot 4.7.2-stable, `godot --headless --import`, then GUT 9.7.1, and fail if tests did not actually run. Server — `go test` plus a compose integration job.

**Hosting, cheap start:** one small VM (Hetzner / Fly.io / equivalent) running the Go binary + TLS, plus **managed Postgres**. Enough for closed testing.

**Scale path:** thin gateway (auth, lobby, portal open, instance assignment) in front of instance workers; Postgres remains the source of truth; add Redis for presence; autoscale workers by live instance count. No Kubernetes until a single box is actually full.

**Alt hosts:** Railway/Render for even less ops (costlier at scale); a Godot-only VPS only if we pick Alt B.

## What Karyu needs to decide vs. what we can just make

**Karyu (and Game Designer where noted):**

1. Confirm **Godot 4.7.2-stable** (typed GDScript, matching export templates) and that **web export stays a nice-to-have** (locks WebSocket/WebRTC in, and keeps us off Godot C#).
2. **Server language:** accept Go, or prefer Rust (headless Godot only if sim-code reuse outweighs ops/density).
3. **Auth at first playable:** email+password only, or also Discord/Google.
4. **Level multiplier:** allowed range, presets vs. free value, and confirm it is immutable after the portal opens (Game Designer).
5. **Hosting preference / monthly budget** (a single cheap VM is the default).
6. Whether **paid cosmetics** exist at first playable (affects account/payment surface; not required to start the sim).

**Engineers can decide (unless Karyu objects):** tick 20 Hz and the units table above; protocol v1 handshake; WebSocket + Protobuf; JSON `data/` pack; `GameSession` / `WorldSource` client shape; PostgreSQL + transactional vault/idempotent grants; in-process instance rooms first; Docker Compose one-command dev; GUT 9.7.1 CI shape; the anti-cheat basics above. No server build until this stack is agreed.

