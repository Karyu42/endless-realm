# Golden fixtures

Shared inputs and expected outputs read by both Go (`server/internal/sim`) and
GDScript (GUT + `make fixtures-parity`). Changing an expected value needs a note
in the PR saying why.

Times are tick indices. Positions are tiles, float64, Godot 2D angles
(+X = 0 rad, +Y down, clockwise positive). Compare with epsilon `1e-9`.

## PCG32

Algorithm: **PCG-XSH-RR 64/32** (Melissa O'Neill), 64-bit state, 32-bit output.
Do **not** use Godot `RandomNumberGenerator` or Go `math/rand`.

Multiplier: `6364136223846793005`

```
uint32 pcg32_random(state, inc):
    old = state
    state = old * 6364136223846793005 + inc          # all uint64, wrap at 2^64
    xorshifted = uint32(((old >> 18) ^ old) >> 27)   # logical shifts
    rot = uint32(old >> 59)
    return (xorshifted >> rot) | (xorshifted << ((-rot) & 31))
```

### Seeding rule (fixed, both sides)

`pcg32_init(initstate, initseq)` is the official `pcg32_srandom`:

1. `state = 0`
2. `inc = (initseq << 1) | 1`
3. `pcg32_random()` once
4. `state += initstate` (uint64 wrap)
5. `pcg32_random()` once

For a `PatternSpawn`, call `pcg32_init(seed, 1)` — `seed` is the spawn's `u64`
seed, and the stream (`initseq`) is **always 1** unless a later contract adds
named streams. Draws happen only when a field asks for rng, in this order:

1. If the pattern is a `ring` and `skip.start` is the string `"rng"`:
   `start = pcg32_random() % count`

No other field in v1 of this pack consumes a draw. Add new draws at the end of
this list so existing fixtures stay stable.

`fixtures/pcg32/known.json` lists official first outputs for fixed
`(initstate, initseq)` pairs. Both sides must match these bits exactly.

`initstate`, `initseq`, and pattern `seed` values are strings encoding a
u64: a decimal integer, or hex with a `0x` prefix. GDScript cannot pass
values ≥ 2^63 through `int()`, so both sides parse with `ParseU64` /
`PCG32.parse_u64`, which returns the bit-identical unsigned value (the
signed bit pattern in GDScript). The official pcg32-demo pair `(42, 54)`
and a high-bit seed/stream case live in `known.json`.

Pattern fixtures that are not part of the shipped pack, including
`fixture_gap_ring`, are defined in `fixtures/patterns/defs.json` and
merged in at test time.

## Patterns

JSON in `data/patterns.json`. `lifetime_ticks = ceil(range / speed * 20)`.
Bullet size radii (tiles), defined once in code as `S=0.15`, `M=0.25`, `L=0.40` (content-v0.1 §0.1). The player hit radius is 0.30.

Closed form, for each emitted bullet:

```
elapsed = t - spawn_tick          # t may be fractional at render time
pos = origin + dir(angle) * speed * elapsed * 0.05
```

where `dir(angle) = (cos(angle), sin(angle))` in radians. A bullet is gone when
`elapsed >= lifetime_ticks` or `speed * elapsed * 0.05 >= range`.

`fan`: `count` bullets centered on the aim angle (or `start_angle_deg` when
`aim` is `fixed`), spread evenly over `spread_deg`. `count = 1` is a single shot
at that angle.

`ring`: bullets at `start_angle_deg + i * 360 / count`. Optional `skip` drops
`consecutive` indices starting at `start` (mod `count`).

`rotate_per_fire_deg` adds `k * value` on volley `k`. `angle_offset_cycle_deg[k % len]`
is the alternative; a pattern uses at most one of these.

## Hit tests (offline LocalSim / future server)

Swept circle vs circle between tick `n-1` and `n`: relative motion reduced to a
segment-circle test with radius `r_a + r_b`. This is what LocalSim uses so fast
shots cannot tunnel. The Go side must use the same test when it applies hits.

## Spiral and burst volleys

`warden_spiral` / `warden_twinspiral_*` are `type: spiral`. Fixture `volley_index`
is the emit index (0, 1, 2…): arm *i* fires at
`base + i × 360°/arms + volley × rotate_per_emit_deg`.
`acolyte_cross` is `type: burst`; `volley_index` is the repeat index, and
`angle_offset_per_repeat_deg` is applied to the child volley. Hazard patterns
emit no bullets.
