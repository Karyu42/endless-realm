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
`burr_spit`. There is no network code in this project yet, and no Godot
MultiplayerAPI.

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
damage / death, packed `res://data` loading, and the burr_spit cadence
(first spit 30 ticks after aggro).

Shared fixtures live in [`fixtures/`](../fixtures/). From the repo root, Go and
GDScript must agree:

```bash
make data-validate
make fixtures-parity
```

`make fixtures-parity` runs `go test -race ./internal/sim` and `make client-test`.
