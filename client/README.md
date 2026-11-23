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
Driftrunner golden ticks 0/6/12/18/23/29, Thornguard 0/10/20, no tap-burst,
Gleamwright cast-lock 0/8/19/27/35, mid-hold rate change), projectile
lifetime and range, tick stepping, the `NetClient` stub, official
PCG32 known vectors, golden pattern positions, swept hits, Burrmite
damage / death, packed `res://data` loading, the burr_spit cadence
(first spit 30 ticks after aggro), deterministic personal loot, idempotent
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
in `InputIntent` and `LocalSim`. Entity ids are `int` from one counter.
Every practice-yard enemy is fixed at the data E: kills give normal
`killXP(1)`, Glint `ceil(m(1))` = 1, and loot rolls at T* = 0.
