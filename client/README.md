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
equal). Editor and export both use that `res://` path, so the Burrmite ships
in the desktop and Android builds. A Burrmite wanders the yard and fires
`burr_spit`.

There is no Godot MultiplayerAPI here and no RPCs for game state. Transport is
`WebSocketPeer` / `TCPServer` only. Protocol v1 frames currently use an interim
JSON `ProtocolCodec` (`src/net/protocol_codec.gd`) whose shapes match
`proto/v1/protocol.proto` (Hello, Welcome, Reject, InputFrame, Snapshot).
godobuf is not on main yet; replacing the codec is a follow-up. Snapshot
replication and client prediction are stubbed (TODO).

`GameSession` can run solo (`LocalSim` in-process), as a listen host, or as a
remote client. The host's own player submits `InputIntent` on the same path as
remotes. LAN discovery is a UDP beacon (magic `ERLB`) on port **18080**. The
WebSocket listen port defaults to **8080**, path `/ws`.

## Host or join a lobby

From the boot screen: **Play solo**, **Host**, join a listed LAN lobby, join by
code, or join by `IP:port`. The host sets max players (1–50, default 50) and
may allow or refuse `played_offline` imports. Android is join-only in v0.1
(desktop or `--headless` hosts; a phone listen-host cap is a later follow-up).

The same export can host headless:

```bash
godot --path client --headless -- --host --name="Yard" --port=8080 --max-players=50
# or pin a join code and refuse offline imports:
godot --path client --headless -- --host --join-code=AB12CD --refuse-imports
# join a host:
godot --path client -- --join-url=ws://127.0.0.1:8080/ws --played-offline
```

`--headless` without `--join` / `--join-url` defaults to hosting. Discovery is
LAN-only for now (no UPnP or listing service).

## Run the practice yard

1. Install [Godot 4.7.2-stable](https://godotengine.org/download/archive/4.7.2-stable/)
   (standard build, not the .NET one).
2. Open the `client/` folder as a project, or from the repo root:

```bash
godot --path client
```

Controls:

- **Desktop:** WASD or arrows to move (diagonals are normalized), mouse to aim,
  hold the left button to fire.
- **Android / touch:** left virtual stick moves, right stick aims and fires
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
Driftrunner golden ticks 0/6/12/18/23/29, Thornguard 0/10/20, no tap-burst),
projectile lifetime and range, tick stepping, the `NetClient` stub, official
PCG32 known vectors, golden pattern positions, swept hits, Burrmite
damage / death, packed `res://data` loading, the burr_spit cadence
(first spit 30 ticks after aggro), protocol v1 handshake and import refusal,
portal-multiplier selection, beacon encode/decode, and a headless loopback
host+client WebSocket session.

Shared fixtures live in [`fixtures/`](../fixtures/). From the repo root, Go and
GDScript must agree:

```bash
make data-validate
make fixtures-parity
```

`make fixtures-parity` runs `go test -race ./internal/sim` and `make client-test`.
