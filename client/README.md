# Endless Realm — client

Godot **4.7.2-stable** project (typed GDScript) for the offline practice slice.
It follows [`docs/tech/stack.md`](../docs/tech/stack.md): a `GameSession` autoload
owns a `WorldSource` (`LocalSim` now). Every game rule (movement, shooting,
patterns, damage) lives in plain `RefCounted` classes — no `Node`, `SceneTree`,
`Input`, or rendering — so the same sim can run in-process for solo play and,
later, on a headless player-hosted lobby. Math is **20 Hz** with **float64**
values (use `SimVec2`, not `Vector2`, in the sim). Render nodes interpolate
between ticks. `TILE_PX = 16` is defined once, in `src/core/sim_constants.gd`.
1.0 sim unit is one tile. Angles use the Godot 2D convention (+X = 0, +Y down,
clockwise positive). Deterministic randomness is **PCG32 only**.

The practice yard loads the shared pack from [`res://data/`](data/), a packed
copy of repo-root [`data/`](../data/) (`make sync-client-data` keeps them
equal). Editor and export both use that `res://` path, so the Burrmite and Driftcap Spore ship in the desktop and Android builds.
A Burrmite wanders the yard and fires `burr_spit`. A rooted Driftcap Spore
sits nearby and fires `spore_ring`.

There is no Godot MultiplayerAPI here and no RPCs for game state. Transport is
`WebSocketPeer` / `TCPServer` only. Protocol v1 frames use the godobuf codec
in `src/net/proto/`. The listen-server core is the Server Engineer's
`LobbyHost` (`src/net/host/`); this client owns the boot scene, lobby browser,
settings, LAN beacon and portal preview. Snapshot replication and client
prediction are stubbed (TODO).

`GameSession` can run solo (`LocalSim` in-process), as a listen host, or as a
remote client. LAN discovery is a UDP beacon (magic `ERLB`) on port **18080**.
The WebSocket listen port defaults to **8080**, path `/ws`. The join code is
only included in the beacon when the host opts in.

Until the Server Engineer's host hooks land, this listen-host path is
temporary: the host plays in a separate local `LocalSim`, remotes see the
host's stand-in bullet world, joiners get an empty arena (snapshot
replication is stubbed), and lobby settings are client-side stubs
(`validate()` is shown in the UI; `LobbyHost.apply_settings` is not called
yet). The beacon player count counts the listen host as one but never
reports more than max, so a full lobby cannot show 51/50 before
`add_local_player` exists.

## Host or join a lobby

From the boot screen: **Play solo**, **Host**, join a listed LAN lobby, join by
code, or join by `IP:port`. The host sets max players (1–50, default 50;
values outside that range are rejected, not clamped). `--max-players` and
`ER_MAX_PLAYERS` are accepted; the flag wins. An invalid cap exits with
code 2 when headless (same as `host_main`) and, with a display, shows the
error and stays on the lobby browser instead of entering the solo arena.
The allowed portal M range is an integer `m100` in [50, 150] step 5, with
min <= 100 <= max; `validate()` reasons are shown in the UI. Import policy
uses two settings (`imports_allowed` / `offline_allowed`) with refusal
codes `REJECTED_IMPORTS_OFF` and `REJECTED_OFFLINE_OFF`, applied when
importing a character, not when joining. Android is join-only in v0.1
(desktop or `--headless -- --host`; a phone listen-host cap is a later
follow-up).

The same export can host headless:

```bash
godot --path client --headless -- --host --name="Yard" --port=8080 --max-players=50
# or pin a join code and refuse offline imports:
godot --path client --headless -- --host --join-code=AB12CD --refuse-imports
# join a host:
godot --path client -- --join-url=ws://127.0.0.1:8080/ws --played-offline
```

`--headless` does not host unless `--host` is passed, so the CI smoke run is
unchanged. Discovery is LAN-only for now (no UPnP or listing service).

## Run the practice yard

1. Install [Godot 4.7.2-stable](https://godotengine.org/download/archive/4.7.2-stable/)
   (standard build, not the .NET one).
2. Open the `client/` folder as a project, or from the repo root:

```bash
godot --path client
```

Controls:

- **Desktop:** WASD or arrows to move (diagonals are normalized), mouse to aim,
  hold the left button to fire, Space or the right button for the ability.
- **Android / touch:** left virtual stick moves, right stick aims and fires,
  an ability button sits above the right stick,
  while held.

Placeholder art is primitive shapes only. Tunables (stride, fire rate, shot
speed / range / lifetime) are on the `SimConfig` resource at
`resources/sim_config.tres`.

## Tests

CI (already on `main` from PR #5) installs [GUT 9.7.1](https://github.com/bitwes/Gut/releases/tag/v9.7.1),
runs `godot --headless --path client --import`, then GUT, and fails if the JUnit
file is missing or has 0 tests.

Locally, from the repo root (Godot 4.7.2 on `PATH` or `GODOT=/path/to/godot`):

```bash
make client-test
```

That installs GUT into `client/addons/gut` if needed (not committed), imports,
runs the tests, and checks the JUnit file the same way CI does.

```bash
# or, after GUT is installed:
godot --headless --path client --import
godot --headless --path client -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

The tests cover 8-dir movement and diagonal normalization, fire-on-press
timing from `docs/design/content-v0.1.md` §1 (float64 `next_ready` in seconds,
Driftrunner golden ticks 0/6/12/18/23/29, Thornguard 0/10/20, no tap-burst,
Gleamwright cast-lock 0/8/19/27/35, mid-hold rate change), projectile
lifetime and range, tick stepping, the `NetClient` stub, official
PCG32 known vectors, golden pattern positions, swept hits, Burrmite and Driftcap Spore
damage / death, packed `res://data` loading, the burr_spit cadence
(first spit 30 ticks after aggro), protocol v1 handshake and import refusal,
portal-multiplier selection, beacon encode/decode, a headless loopback
host+client WebSocket session, deterministic personal loot, idempotent
drop ids, the vision §3.4 XP table (including level 1000), and multi-level-up
from one grant.

`spawn_tick` is the time index of the tick that spawned a shot (the first
processed tick is 0). `tick()` and `snapshot.tick` count completed ticks, so
they are 1 after the first step. A shot fired on the first tick therefore has
`spawn_tick == 0` while `snapshot.tick == 1`.

Shared fixtures live in [`fixtures/`](../fixtures/). From the repo root, Go and
GDScript must agree:

```bash
make data-validate
make fixtures-parity
```

`make fixtures-parity` runs `go test -race ./internal/sim` and `make client-test`.

## Loot and XP

Kills in `LocalSim` roll personal loot and credit XP from `data/loot.json` and
`data/scaling.json` (vision §3.4 and §4.2, content-v0.1 §4). Drops use PCG32
seeded from the instance seed, the enemy id and the drop index, with the looter
as the stream. Each drop has an idempotent `drop_id`. Bags expire after 60 s
(1200 ticks). The HUD shows HP, level and an XP bar; E picks up a bag in range,
and keys 1–8 equip an inventory slot.

Interact prompt (1.5 tiles) and accept (2.0 tiles) ranges, and the practice-yard
enemy level (E = 1), come from `data/scaling.json`. The client auto-selects a
target in the prompt range and sends `interact_target_id` (0 means none). The
sim applies a nonzero id as a press, at most once per seq, and silently drops
an unknown id, a bag the player may not use, or a target farther than the
accept range. The Server Engineer's protocol PR will add
`uint64 interact_target_id = 6` to `InputFrame`; until then the field lives
in `InputIntent` and `LocalSim`. Entity ids are `int` from one counter and stay below 2^63 so they fit the uint64 wire field.
Every practice-yard enemy is fixed at the data E: kills give normal
`killXP(1)`, Glint `ceil(m(1))` = 1, and loot rolls at T* = 0.

## Host interact hook

`proto/v1.InputFrame.interact_target_id` is a uint64 entity id, not a boolean.
Zero means none; a nonzero target is a press on that seq. `LobbyHost` queues
presses from accepted inputs and evaluates them after movement using the
host's position. Unknown / disallowed targets and targets beyond the accept range in
`data/scaling.json` (`interact_accept_range_tiles`) are silently dropped;
the same seq cannot interact twice, including across the uint32 wrap.

The host has not wired the shared sim's interactables yet. For the loot work,
set `host.interact_validator.resolver` to
`func(target_id: int, player_id: int) -> Dictionary`, returning
`{"x": float, "y": float}` in tiles only for an existing target the player
may use, or `{}` otherwise. Set `host.on_interact` to
`func(player_id: int, target_id: int) -> void` to apply accepted presses.
The resolver defaults to unknown, so no interaction is accepted until wired.

## Host API (lobby UI)

Everything lives in `src/net/host/`. `LobbyHost` is the one host core; the
lobby UI drives it through these calls.

**Settings**: `LobbySettings` (`lobby_settings.gd`):

| field | default | rule |
|---|---|---|
| `max_players: int` | 50 | 1–50 |
| `m100_min: int`, `m100_max: int` | 100, 100 | 50–150, multiples of 5, `min <= 100 <= max` |
| `imports_allowed: bool` | true | |
| `offline_allowed: bool` | true | |
| `lobby_name: String` | "" | at most 32 chars, no control chars |
| `join_code: String` | "" | empty = host generates one; else 4–12 chars from `LobbySettings.JOIN_CODE_ALPHABET` |

- `validate() -> PackedStringArray`: empty when valid, otherwise short
  reasons meant to be shown to players as-is. `duplicate_settings()` copies.
- `host.apply_settings(s) -> Error`: `ERR_INVALID_PARAMETER` if `validate()`
  fails (nothing changes); otherwise applies a copy and emits
  `settings_changed(s)` with another copy.
- `host.settings() -> LobbySettings`: a copy. An empty `join_code` is filled
  with a generated code (6 chars, no 0/O/1/I/L, from `Crypto` random bytes,
  never the sim RNG), so read the code from here for the UI and beacon.
- Runtime changes: lowering `max_players` never kicks anyone, it only makes
  new joins fail with `INSTANCE_FULL`. The M range applies to portals opened
  afterwards (`host.is_m100_allowed(m100)`; the Godot host does not handle
  OpenPortal yet, and the protocol PR adds the check there). Import flags
  apply to future imports.
- `--max-players` / `ER_MAX_PLAYERS` go through `apply_settings()`. Setting
  `host.max_players` does too: an invalid value is refused with a warning and
  the cap is unchanged.

**Local player** (listen host): `add_local_player(character = null) -> int`
returns the id, or -1 when full; it counts toward `max_players`.
`submit_local_input(player_id, intent: InputIntent)` uses the same per-tick
queue and rules as a remote InputFrame (applied once per seq, interact presses
go through the interact validator), with no socket and no message budget.
`remove_local_player(player_id)`.

**View**: `signal ticked(tick: int)` fires at the end of every host tick.
`world_view(player_id) -> WorldSnapshot` (null before the player's first
tick) is a read-only `HostWorldSnapshot`: that player's sim snapshot, with
`host_tick` and `others` (`{"id","x","y","aim","hp","local"}`) added.
`tick` and spawn ticks inside use that player's sim clock.

**Imports**: `import_character(blob, player_id) -> int` returns an
`ImportResult` constant (`import_result.gd`). Checked only at import, never at
Hello, so a lobby with imports off can still be joined.

| constant | meaning |
|---|---|
| `IMPORT_RESULT_OK` (0) | imported |
| `REJECTED_IMPORTS_OFF` (1) | lobby has `imports_allowed = false` |
| `REJECTED_OFFLINE_OFF` (2) | character was played offline, lobby has `offline_allowed = false` |
| `REJECTED_BAD_FORMAT` (3) | not a character file |
| `REJECTED_UNSUPPORTED_VERSION` (4) | character file version this host can't read |
| `REJECTED_BAD_SIGNATURE` (5) | signature not verified (every blob for now) |
| `REJECTED_ALREADY_EXISTS` (6) | this player already imported a character here |
| `REJECTED_UNKNOWN_PLAYER` (7) | no such player |

`ImportResult.name_of(code)` and `ImportResult.all()` help map them. The blob
format is a stub for now (`LobbyHost.make_stub_import_blob()`). Import fails
closed: after the flag and format checks, any blob whose signature has not been
verified returns `REJECTED_BAD_SIGNATURE`. Verification is not implemented yet,
so nothing imports until the host-lobby protocol PR adds it.

**Ability press**: `InputFrame.ability_pressed` (and `InputIntent.ability_pressed`
for the local player) is a one-shot press on that frame's seq. The host applies
it at most once per seq (seq 0 is rejected), hands it to the player's sim intent
on the next tick, and clears it after that tick. A later frame in the same tick
that doesn't repeat it keeps the press. Focus and cooldown checks are the sim's.

**Sim**: each player is simulated by the shared `LocalSim` rules (movement,
shots). The world is not one shared multi-player `LocalSim` yet, so players
don't see shared enemies. The stand-in bullet field only runs for the load
test (`--emitters N`, default 0).
