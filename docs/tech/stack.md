# Endless Realm — Tech Stack Proposal

**Audience:** Chief of Staff, Karyu, ER Gameplay Engineer  
**Date:** 23 Nov 2026 (Europe/Vienna)  
**Status:** Accepted (23 Nov 2026). Amendment 2026-11-23 (player-hosted lobbies) — **Status: Proposed — pending Karyu (via Chief of Staff).**

**Constraints:** Godot **4.7.2-stable** (4.8 is still beta) plus matching export templates. Client in **typed GDScript** (Godot 4 C# cannot export to web; Android C# is experimental). Targets: Windows / Linux / macOS + Android; no iOS; web export is a nice-to-have. **Decided:** no official servers for now; solo is offline (in-process sim, no network, no tracking); multiplayer is player-hosted lobbies (host-set max player count, default 50). Portal opener sets that instance’s level multiplier (0.5–1.5 in v0.1, locked at open). **Proposed (pending Karyu):** the authoritative sim is the Godot game itself (listen server or `--headless` dedicated host), not a Go gameplay server. No level cap; endless gear tiers; everything except cosmetics is farmable; no paid cosmetics at first playable.

## Decisions

Confirmed by Karyu, 2026-11-23:

1. **Client:** Godot 4.7.2-stable, typed GDScript, matching export templates. Web export is a nice-to-have (locks WebSocket/WebRTC in, and keeps us off Godot C#).
2. **Server language:** Go. **Proposed amendment:** move the authoritative sim to Godot (see [Amendment 2026-11-23](#amendment-2026-11-23-player-hosted-lobbies)). Pending Karyu (via Chief of Staff).
3. **Auth at first playable:** email + password only. **Proposed amendment:** superseded for v0.1 under character option 3a (host-local saves). Alternative 3b would keep a central account / signing service.
4. **Level multiplier:** 0.5–1.5 for v0.1 (per [PR #1](https://github.com/Karyu42/endless-realm/pull/1)), **locked once the portal opens**.
5. **Hosting:** **Updated, decided 2026-11-23 (via Chief of Staff).** No official servers for now. Solo is offline. Multiplayer is player-hosted lobbies. Official-server budget stays deferred. First playable is no longer “local Docker Compose plus a later VM.” v0.1 discovery is LAN broadcast plus join by code/link or direct IP (directory and relay deferred).
6. **Paid cosmetics:** none at first playable.

**Also decided by Karyu, 2026-11-23** (relayed by Chief of Staff):

- Multiplayer = player-hosted lobbies. The host sets the max player count, **default 50**.
- A lobby browser shows the level multiplier of open portals. If more than 5 portals are open, show at least the 2 lowest and the 2 highest.
- Enemy scaling is dynamic by players in range and uses the **peak** count during an encounter (it does not drop when players leave). Numbers come from the Game Designer’s hosting amendment to `docs/design/vision.md` — this doc does not invent them. Early lean from that work: **HP only scales; loot is personal.**
- Offline-played characters are flagged. Lobbies can refuse them.
- **Discovery v0.1:** LAN broadcast discovery plus join by code/link or direct IP. The host tries UPnP port mapping; otherwise the host forwards the port manually. A directory service (Cloudflare Workers free tier, €0, ~$5/mo if outgrown) and relay / NAT punch are deferred.

**Proposed (pending Karyu, via Chief of Staff):** authoritative Godot host (listen server or `--headless`), one shared GDScript sim, wire protocol unchanged, Go gameplay server becomes a reference/test harness, character option 3a (host-owned saves; imports carry `played_offline`). Also proposed after the Gameplay Engineer’s review of `b1396a7`: an Android listen-host cap, a shared `InputIntent` path for the host player, and a 50-player Android render smoke beside the headless load-test gate. Details in the amendment below.

**Considered (settled for now, except where the amendment reopens them):** Rust and headless Godot as server languages (density vs. sim-code reuse — headless Godot is the proposed path in the amendment); C# / .NET (rejected — fights web export and Android maturity); Discord/Google OAuth at first playable (defer); a paid cosmetic / Prism currency surface at first playable (defer, later-phase in PR #1); picking a paid host/VM now (official servers are deferred; a Cloudflare Workers directory remains an option if the deferred directory is taken up).

**Engineers can decide (unless Karyu objects):** tick 20 Hz and the units/angle table below; protocol v1 handshake; WebSocket + Protobuf (`godobuf` on the client); JSON `data/` pack; `GameSession` / `WorldSource` client shape; GUT 9.7.1 CI shape; PCG32 + golden-fixture pattern tests; the anti-cheat basics below. **Proposed-superseded under 3a:** PostgreSQL + transactional vault/idempotent grants as the v0.1 store; in-process instance rooms remain the starting point (they now live in the Godot host).

## Amendment 2026-11-23: player-hosted lobbies

**Status: Proposed — pending Karyu (via Chief of Staff).**

Karyu decided the hosting model (no official servers, offline solo, player-hosted lobbies). The Gameplay Engineer proposed that the host be the Godot game itself, sharing one GDScript sim with solo. This amendment records the decided hosting model and drafts the stack changes for that Godot-host option. The Gameplay Engineer reviewed head `b1396a7` with no blockers and asked for three non-blocking additions (mobile hosting, a shared `InputIntent` path, and an Android render smoke), included below as Proposed. **Do not merge until Karyu answers, via Chief of Staff.**

### Decided (record as decided)

- **No official servers** for now.
- **Solo** is offline: the shared sim runs in-process, with no network and no tracking.
- **Multiplayer** is player-hosted lobbies. The host sets max player count, default 50.
- **Lobby browser:** show each open portal’s level multiplier. If more than 5 portals are open, show at least the 2 lowest and the 2 highest.
- **Enemy scaling:** dynamic by players in range, using the **peak** count during an encounter (the count does not drop when players leave). Do not invent coefficients or the definition of “in range” here. Those, and which stats scale, belong in the Game Designer’s hosting amendment to `docs/design/vision.md`. Early lean from that work: HP only scales; loot is personal.
- **Offline-played** characters are flagged; a lobby can refuse them.
- **Discovery v0.1:** LAN broadcast discovery + join by code/link or direct IP. Host tries UPnP port mapping, else manual port forward. Directory service (Cloudflare Workers free tier, €0, ~$5/mo if outgrown) and relay / NAT punch are deferred.

### Proposed (pending Karyu)

- **Authoritative sim moves from Go to Godot.** The host is the game itself, as a listen server inside the host’s client or as the same export run `--headless` as a dedicated host. Solo and hosted play share **one** GDScript sim (`LocalSim` + rules in plain `RefCounted` classes, no Node or rendering dependencies). The sim stays deterministic; golden fixtures become regression tests.
- **Mobile hosting:** Android can join any lobby. An Android phone listen host defaults to a max of **8** players (a host-side setting; the final ceiling is set by the load test). Karyu’s default of 50 applies to desktop / `--headless` hosts, which are recommended for big lobbies. Phone NAT / UPnP is unreliable, so join by code or direct IP may fail on mobile hosts.
- **Host input path:** the listen-server host’s own player sends input through the same `InputIntent` path into the sim as remote players, with zero latency and no special-case code, so solo, host, and remote share one path.
- **Wire protocol unchanged:** Protobuf (`godobuf`) over WebSocket, 20 Hz tick, closed-form `PatternSpawn` bullets (PCG32), client prediction / reconciliation, interpolation for others. The host uses `WebSocketPeer` / `TCPServer` or `WebSocketMultiplayerPeer` as **transport only** — no MultiplayerAPI RPCs for game state. `proto/v1` remains the source of truth.
- **Go:** the existing Go gameplay server (PRs #3, #6, portal PR #12) becomes a reference and test harness. Its bot client may remain as a load / smoke tool against Godot hosts. Go is reserved for optional later services (directory, relay, account sync). **CI follow-up for QA (not in this PR):** required checks `server-build-test` and `integration-smoke` will need to run against a headless Godot host, and the load-test gate should add a 50-player render smoke on the Android APK. Do not change workflows here.
- **Risk + mitigation (load-test gate):** GDScript sim performance at 50 players / 20 Hz is unproven, and client render cost at 50 players is a separate risk (needs pooled or MultiMesh bullet rendering). Gate on both a **50-bot load test against a headless host** (sim CPU) and a **50-player render smoke on the Android APK** (client render) before committing content. The Android listen-host ceiling is also set by the load test (proposed default 8).
- **Characters / persistence (recommended option 3a):** characters live on the lobby that created them (host save). Characters brought from elsewhere, including offline / solo ones, are **imports** carrying a `played_offline` flag. A host setting allows or refuses imports. With no official authority, a client-side flag is not tamper-proof; enforcement is the host owning its own saves. **Alternative 3b:** a central signing / account service that signs saves and the flag. That is trustworthy across lobbies, but it needs always-on official infrastructure and an ops / hosting cost (3a needs neither). Email / password sign-in and PostgreSQL are **superseded for v0.1 under 3a** (the host saves locally, e.g. SQLite or files).
- **Hosting / local dev:** Docker Compose PostgreSQL is no longer needed under 3a. Note as a follow-up; do not change compose in this PR.

### Decision log

| Date | Item | Status | Source |
|---|---|---|---|
| 2026-11-23 | Client: Godot 4.7.2-stable, typed GDScript; web export nice-to-have | Accepted | Karyu |
| 2026-11-23 | Server language: Go gameplay server | Accepted; **proposed superseded** by a Godot host | Karyu; amendment pending Karyu via CoS |
| 2026-11-23 | Auth: email + password; PostgreSQL persistence | Accepted; **proposed superseded** for v0.1 under option 3a | Karyu; amendment pending Karyu via CoS |
| 2026-11-23 | Level multiplier 0.5–1.5, locked at portal open; no paid cosmetics at first playable | Accepted | Karyu |
| 2026-11-23 | No official servers; solo offline (in-process, no network, no tracking); player-hosted lobbies, host-set max (default 50) | Decided | Karyu, relayed by Chief of Staff |
| 2026-11-23 | Lobby browser shows open portals’ multipliers; if >5 open, at least the 2 lowest and 2 highest | Decided | Karyu, relayed by Chief of Staff |
| 2026-11-23 | Enemy scaling: peak players in range during an encounter (does not drop when players leave). Numbers from the Game Designer’s `vision.md` hosting work; early lean: HP only scales, loot personal | Decided (rule); numbers stay with design | Karyu, relayed by Chief of Staff; Game Designer |
| 2026-11-23 | Offline-played characters flagged; lobbies can refuse them | Decided | Karyu, relayed by Chief of Staff |
| 2026-11-23 | Discovery v0.1: LAN broadcast + join by code/link or direct IP; UPnP then manual port forward. Directory (Cloudflare Workers free tier, €0, ~$5/mo if outgrown) and relay / NAT punch deferred | Decided | Karyu, relayed by Chief of Staff |
| 2026-11-23 | Authoritative sim in Godot (listen server or `--headless`); one shared GDScript sim; wire protocol unchanged; Go becomes a reference / test harness | **Proposed** | Gameplay Engineer proposal; pending Karyu via Chief of Staff |
| 2026-11-23 | Character option 3a: host-owned saves; imports carry `played_offline`; host allows/refuses imports. 3b (central signing) noted with cost | **Proposed** (3a recommended) | Pending Karyu via Chief of Staff |
| 2026-11-23 | Mobile hosting: Android can join any lobby; phone listen host defaults to 8 (host-side setting; ceiling from the load test). Karyu’s default of 50 applies to desktop / `--headless` hosts (recommended for big lobbies). Phone NAT / UPnP may make join-code / direct IP fail | **Proposed** | Gameplay Engineer review of `b1396a7`; pending Karyu via Chief of Staff |
| 2026-11-23 | Listen-server host’s own player uses the same `InputIntent` path into the sim as remotes (zero latency, no special-case code); solo, host, and remote share one path | **Proposed** | Gameplay Engineer review of `b1396a7`; pending Karyu via Chief of Staff |
| 2026-11-23 | Load-test gate: 50-bot headless host test (sim CPU) plus 50-player render smoke on the Android APK (client render; pooled / MultiMesh bullets). CI and Compose follow-ups for QA (no workflow or compose changes in this PR) | **Proposed** / follow-up | Gameplay Engineer review of `b1396a7`; pending Karyu; QA follow-up |

## Agree first (client + server)

Lock these before implementation. A connect **version handshake** disconnects on mismatch with a clear error; breaking wire changes bump the protocol version.

| Item | Agreement |
|---|---|
| Protocol version | `u16` in the first message both ways; current = `1`. **`proto/v1` is the source of truth** (unchanged under the Godot-host proposal). |
| Tick rate | **20 Hz** (50 ms) authority. Same rate for client input sampling, `LocalSim`, and the host sim. Client **renders at display rate**. |
| World units | Sim and wire: `float` **1.0 = one tile**. Client constant **`TILE_PX = 16`** (16 px source art) defined in one place; art scale is not restated elsewhere. |
| Axes / angles | **Godot 2D convention on the wire and in the sim**, including the host and the Go reference harness — **no sign flips.** +X = 0 rad, **+Y down**, positive angle = **clockwise on screen**. |
| Time | Sim events and pattern spawns use **tick index** (`u32`), not milliseconds. |
| Numeric precision | **float64** for all sim math (GDScript floats are 64-bit). **float32 only on the wire.** |

## Headline stack

- **Client:** Godot 4.7.2-stable, typed GDScript, matching export templates. Autoload `GameSession` owns a `WorldSource`: `LocalSim` (offline, in-process, steps at 20 Hz — this is **solo**) and `NetClient` (input frames out; snapshots/events in; prediction + reconciliation for self; interpolation buffers for others). Gameplay/render nodes only read entity state and emit input intents; they interpolate between 20 Hz ticks, and evaluate bullets analytically at render time. Sim (movement, pattern evaluation, damage, loot, XP) lives in plain `RefCounted` classes, not Nodes. Tests: **GUT 9.7.1**; CI runs `godot --headless --import` first and fails if tests did not actually run.
- **Host (proposed):** the same Godot export, either as a **listen server** inside the host’s client or run `--headless` as a dedicated host. It runs the same `LocalSim` / rules classes authoritatively and speaks the existing wire protocol. The listen-server host’s own player sends `InputIntent`s into the sim on the same path as remote players (zero latency, no special-case code). **Do not use Godot’s high-level MultiplayerAPI for game state** (no RPCs). Transport may use `WebSocketPeer` / `TCPServer` or `WebSocketMultiplayerPeer` as a socket only. Android can join any lobby; a phone listen host defaults to a max of 8 (host-side setting; ceiling from the load test). Karyu’s default of 50 applies to desktop / `--headless` hosts, recommended for big lobbies. Until this amendment is accepted, the in-repo Go gameplay server remains the current implementation and, after acceptance, a reference / test harness.
- **Transport:** WebSocket first (desktop + Android + web). Leave a transport interface so desktop can add UDP/QUIC later. Do not use raw ENet as the only path (no web).
- **Wire:** Protobuf. Client (and proposed host) codec: **godobuf** (codegen from the same `.proto` files), with **fixture round-trip tests**. Shared *game data* (items, enemies, patterns, XP) is versioned JSON in `data/`, loaded by the Godot sim and by the Go harness — not compiled shared code. `proto/v1` stays the source of truth.
- **Tick / netcode:** 20 Hz authoritative sim. Client sends `(move, aim, fire_held, seq)` each tick. Bullets are deterministic **closed-form** patterns — the host broadcasts pattern *spawns*, not per-bullet state. Hits, loot, and XP are authority-only (the host, under the proposal).
- **Instances:** Opening a portal creates an instance and **locks** the opener’s level multiplier in **[0.5, 1.5]** on the host (HP/damage, loot, XP, currencies). A lobby’s max player count is host-set; Karyu’s default is 50 (desktop / `--headless`). **Proposed:** an Android phone listen host defaults to 8. The lobby browser shows open portals’ multipliers as decided above.
- **Accounts / persistence (proposed 3a):** host-local character saves (e.g. SQLite or files). Imports, including solo / offline characters, carry `played_offline`; the host may allow or refuse them. Email + password and PostgreSQL are superseded for v0.1 under 3a.

## Server language / runtime

**Pick (accepted 2026-11-23):** Go — fast to ship accounts, instances, and persistence; great concurrency; one small binary; easy Compose. Fits `WorldSource` / `NetClient` (the client is not coupled to a Godot server). Sim logic is ported in plain classes + shared JSON data; drift is managed by golden-fixture tests.

**Proposed amendment (pending Karyu):** move the authoritative sim to Godot so solo and hosted play cannot drift. The host is the game itself (listen server or `--headless` dedicated host). One GDScript implementation: `LocalSim` plus rules in plain `RefCounted` classes, no Node or rendering dependencies, deterministic. Golden fixtures become regression tests (the Go harness may still run them).

The existing Go gameplay server (PRs #3, #6, and portal PR #12) becomes a **reference and test harness**. Its bot client may remain a load / smoke tool against Godot hosts. Go is reserved for optional later services (lobby directory, relay / NAT punch, account sync).

**Risk:** GDScript sim performance at 50 players and 20 Hz is unproven, and rendering 50 players of bullet-hell on a client (especially Android) is a separate cost — it needs pooled or MultiMesh bullet rendering. **Mitigation:** gate on a **50-bot load test against a headless host** (sim CPU) and a **50-player render smoke on the Android APK** before committing content. The proposed Android listen-host default of 8 is a starting cap; the load test sets the final ceiling.

**Considered:** the accepted Go gameplay server (this amendment proposes retiring it from the live path, not deleting the code); Rust (Tokio) for CPU density; headless Godot, now the proposed path. C# / .NET skipped unless we drop web and move the client to C#.

## Transport, protocol, shared data

**Pick:** WebSocket + Protobuf. Godot 4 has `WebSocketPeer` on desktop, Android, and web (and can listen with `TCPServer` or `WebSocketMultiplayerPeer` as transport only). Schema in `proto/`; **`proto/v1` is the source of truth.** Generate a **godobuf** GDScript codec from the same files (and Go structs for the reference harness). Round-trip fixtures must encode/decode identically.

**Considered:** a small hand-written binary codec if godobuf is a poor fit for 4.7.2 (still fixture-tested); WebRTC data channels (UDP-like, NAT traversal, works on web, more ops); QUIC/UDP for desktop + WebSocket fallback (later, not a start). Raw ENet/UDP is not the only transport (no web export); fine as a later desktop path. Godot MultiplayerAPI RPCs are not used for game state.

**Shared data:** items, enemies, bullet patterns, loot tables, and the XP curve live in versioned JSON under `data/` with a JSON Schema. The Godot sim and the Go harness load the same files. No shared compiled library in v1. YAML is an alt if designers prefer it; JSON is easier to validate in CI.

## Tick rate, netcode, bandwidth, hit validation

- Fixed **20 Hz** authority. Client **renders at display rate**. `LocalSim` also steps at 20 Hz (solo and, under the proposal, the host). Render nodes interpolate between ticks; bullets are **evaluated analytically at render time**. Alt: 30 Hz authority if instances stay tiny and melee needs to feel snappier — engineer can try 20 and bump.
- Client samples input at the sim tick, stamped with `seq`. The host (or today’s Go server) is authoritative for positions, damage, loot, XP. **Proposed:** the listen-server host’s own player sends that input through the same `InputIntent` path into the sim as remote players, with zero latency and no special-case code, so solo, host, and remote all exercise one path.
- **Own movement:** prediction + reconciliation against authority snapshots.
- **Others:** interpolate from `NetClient` buffers (~100 ms interpolation delay).
- **Projectiles:** never replicate each bullet. The authority emits `PatternSpawn { id, pattern_id, seed, spawn_tick, origin, params, source_id }`. Positions are a **closed-form** `f(spawn_tick, t, params)`, not integrated frame-by-frame. Both sides use **PCG32** with a **fixed seeding rule** — not Godot `RandomNumberGenerator` and not Go `math/rand`. Shared **golden-fixture tests:** the same pattern JSON + seed must yield the same positions at tick N within an epsilon (regression tests on the GDScript sim; the Go harness may keep a copy). Client is visual; **only the authority applies hits**.
- **Hit validation:** the authority tests collisions with **swept or sub-stepped** checks **between ticks** so fast bullets cannot tunnel through a player. Use a short **position history** (≈100–200 ms rewind) so latency does not make grazing impossible. Reject hits that miss the pattern math, ignore client-reported damage, cap input rate, and sanity-check speed/teleports against move stats. No trust of client loot or XP.
- **Interest:** a portal instance is a small room — broadcast the instance. A lobby at the default cap of 50, or a crowded nexus/hub, should use area-of-interest if it grows past a handful of players.

**Bandwidth (order of magnitude):** inputs ≈ 20–30 bytes × 20 Hz ≈ 0.5 KB/s up. Down: ~N players × ~32 bytes/tick plus occasional pattern spawns (not bullet streams). An 8-player instance is a few KB/s; a 50-player lobby is still modest if bullets stay closed-form. Per-bullet replication would explode in a bullet-hell.

## Instances, portals, level multiplier

**Pick:** Hub (nexus) + instanced dungeons, now inside a **player-hosted lobby** (no official servers). The lobby’s max player count is host-set. Karyu’s **default is 50**, which under the proposal applies to desktop / `--headless` hosts (recommended for big lobbies). **Proposed:** an Android phone listen host defaults to **8** (host-side setting; the load test sets the final ceiling).

1. Player requests `OpenPortal` with a **level multiplier in [0.5, 1.5]** (v0.1, per PR #1). The host authenticates (under 3a: against the lobby’s own saves), rate-limits, and **locks** `multiplier` (and an instance seed) on a new instance record. The opener cannot change it after start.
2. The instance runs in-process on the host first. Players join through the portal; an instance may still have a party size and a TTL (those numbers stay with design / the portal rules — this doc does not invent them). The **lobby browser** lists open portals and their multipliers; if more than 5 portals are open, it shows at least the 2 lowest and the 2 highest.
3. **Multiplier is applied only by the authority** to enemy HP and damage, loot table rolls / drop quantity, XP, and farmable currency grants. The client may display the multiplier; it must not compute rewards. Gear tier rolls use the same locked value.
4. **Enemy scaling (decided):** scale dynamically by **players in range**, using the **peak** count during an encounter. The count does not drop when players leave. Do not invent coefficients or “in range” here — use the Game Designer’s hosting amendment to `docs/design/vision.md`. Early lean from that work: HP only scales; loot is personal.
5. The instance is ephemeral. Persistence happens when loot/currency/XP is granted to a character (under proposed 3a: in the host save). On crash or expiry, unlooted ground drops are gone unless we later add a short recovery window.

**Considered:** one process per instance from day one (simpler isolation, worse density); sharding the hub across workers early (not needed until a lobby or nexus is crowded); official hosted instances (deferred).

## Accounts, persistence, anti-dupe, anti-cheat

**Accounts (accepted 2026-11-23):** email + password only at first playable, hashed (Argon2id), opaque session tokens. Android uses the same account (no device-only progress that can be copied). **Considered:** Discord/Google OAuth, later — not in the first playable. No paid-cosmetics / payment surface at first playable.

**Proposed option 3a (recommended, pending Karyu):** there is no official account service in v0.1. Characters **live on the lobby that created them** (host save, e.g. SQLite or files). Characters brought from elsewhere, including solo / offline ones, are **imports** and carry a `played_offline` flag. The host has a setting to allow or refuse imports — that is how “lobbies can refuse offline-played characters” is enforced. **With no official authority, a client-side flag is not tamper-proof; enforcement is the host owning its own saves.** Email / password sign-in and PostgreSQL are superseded for v0.1 under 3a.

**Alternative 3b (not proposed for v0.1):** a central signing / account service that signs character saves and the `played_offline` flag, so a host can trust the flag on imports. This needs always-on official infrastructure and an ops / hosting cost (a small VM or managed auth), unlike 3a, which needs none, and unlike the deferred directory (Cloudflare Workers free tier, €0, ~$5/mo if outgrown).

**DB (accepted; proposed-superseded under 3a):** PostgreSQL for accounts, characters, vault, inventory, currencies, and audit/grant logs. Redis optional later for sessions and presence (not required for v1). SQLite or files become the v0.1 host-save store under 3a. PostgreSQL remains the right store if 3b or official servers return.

**Atomic currency / vault / anti-dupe:** every item has an authority-issued id. Under official Postgres, vault deposit/withdraw, trades, and currency debits/credits run in a **single Postgres transaction** with row locks (`SELECT … FOR UPDATE`). Under 3a the same invariants apply inside the host save (one writer, idempotent grants). Loot and reward grants carry an **idempotency key** (instance id + drop id, or grant id) so a retry cannot duplicate items or currency. The client never says “give me this item”; it says “I loot entity X” and the authority decides. Disconnect mid-move must roll back or complete, never fork. Under 3a this integrity is **host-trusted**, not globally enforceable.

**Anti-cheat basics (economy integrity first):** authoritative combat and rewards; movement speed caps; input flood limits; pattern-math hit checks (swept/sub-stepped); portal-open and vault-op rate limits; append-only grant/spend log for later anomaly review. Deeper heuristic anti-cheat can wait. Under 3a the host is trusted; a determined host or a forged import can still cheat, which is the cost of no official authority.

## Hosting and local dev

**Decided:** no official servers for now. Solo runs the sim in-process with no network and no tracking. Multiplayer is a player-hosted lobby (listen server or, under the proposal, the same export `--headless`). The host sets max player count; Karyu’s default is 50.

**Mobile hosting (proposed):** Android can join any lobby. An Android phone listen host defaults to a max of 8 players (host-side setting; the final ceiling is set by the load test). Desktop or `--headless` hosts are recommended for big lobbies and keep the default of 50. Phone NAT / UPnP is unreliable, so join by code or direct IP may fail on mobile hosts; LAN discovery still works on the same network.

**Discovery v0.1 (decided):** LAN broadcast discovery plus join by code/link or direct IP. The host tries UPnP port mapping; if that fails, the host forwards the port manually. A lobby directory (Cloudflare Workers free tier, €0, ~$5/mo if outgrown) and relay / NAT punch are deferred. Under the mobile-hosting proposal, do not rely on UPnP or a join code reaching a phone host from off-network.

**Local dev today:** `docker compose up` (or `make dev`) still starts Postgres and the Go gameplay server and prints the Godot connect URL (`ws://localhost:…`), until the amendment is accepted and follow-up work lands.

**Local dev (proposed under 3a):** run the Godot client as a listen server, or the same export `--headless`, and point other clients at `ws://` on the host’s IP (or join via LAN discovery / code). Docker Compose PostgreSQL is no longer needed under 3a; dropping or relaxing that path is a **follow-up** (do not change compose in this PR).

**CI:** client — Godot 4.7.2-stable, `godot --headless --import`, then GUT 9.7.1, and fail if tests did not actually run. Shared pattern golden fixtures run on the GDScript sim (and may still run on the Go harness). Protobuf round-trip fixtures run against the codecs. **Follow-up for QA, not in this PR:** required checks `server-build-test` and `integration-smoke` will need to target a headless Godot host rather than only the Go gameplay server, and the load-test gate should include the 50-bot headless host test plus a 50-player render smoke on the Android APK. Do not change workflows here.

**Later (if official infrastructure is needed):** a deferred lobby directory on Cloudflare Workers as above; a relay or NAT punch; or, under 3b, a signing / account service. A small VM (Hetzner / Fly.io / equivalent) remains an option if official servers return. No Kubernetes until a single box is actually full.

**Considered:** Railway/Render for even less ops (costlier at scale); official Go or Godot dedicated servers (deferred by Karyu’s hosting decision).

