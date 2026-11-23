# Endless Realm — client

Godot **4.7.2-stable** project (typed GDScript) for the offline practice slice.
It follows [`docs/tech/stack.md`](../docs/tech/stack.md): a `GameSession` autoload
owns a `WorldSource` (`LocalSim` now, `NetClient` stub for later). Sim math lives
in plain `RefCounted` classes at **20 Hz** with **float64** values. Render nodes
interpolate between ticks. `TILE_PX = 16` is defined once, in
`src/core/sim_constants.gd`. 1.0 sim unit is one tile. Angles use the Godot 2D
convention (+X = 0, +Y down, clockwise positive).

There is no Godot MultiplayerAPI here. A future PR will point `GameSession` at
`NetClient` and talk to the Go server over WebSocket + Protobuf.

## Run the practice yard

1. Install [Godot 4.7.2-stable](https://godotengine.org/download/archive/4.7.2-stable/)
   (standard build, not the .NET one).
2. Open the `client/` folder as a project, or from the repo root:

```bash
godot --path client
```

Controls:

- **Desktop:** WASD or arrows to move (diagonals are normalized), mouse to aim,
  hold the left button to fire. These are InputMap actions (`move_up` / `move_down`
  / `move_left` / `move_right`, `fire`).
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
Driftrunner golden ticks 0/6/12/18/23/29, Thornguard 0/10/20, no tap-burst,
Gleamwright cast-lock 0/8/19/27/35, mid-hold rate change), projectile
lifetime and range, tick stepping, and the `NetClient` stub.

`spawn_tick` is the time index of the tick that spawned a shot (the first
processed tick is 0). `tick()` and `snapshot.tick` count completed ticks, so
they are 1 after the first step. A shot fired on the first tick therefore has
`spawn_tick == 0` while `snapshot.tick == 1`.
