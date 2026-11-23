# Shared game data

Versioned JSON loaded by both the Godot client and the Go server. Schemas live in
`data/schema/`. Times are **ticks** (20 Hz), angles are **degrees** in these files
and converted to radians (Godot 2D convention) at load. Distances are **tiles**.

This pack has the first practice-yard enemy (`burrmite`) and its `burr_spit`
pattern, plus a `fixture_gap_ring` pattern used only by golden tests
(to cover PCG32 `skip.start = "rng"`), class bases, vision scaling
coefficients, and v0.1 loot tables. Names and numbers follow
[`docs/design/content-v0.1.md`](../docs/design/content-v0.1.md).

The Godot client ships a copy under [`client/data/`](../client/data/) so the
JSON is packed into exports (`res://data`). `make sync-client-data` copies
`data/*.json` there; `make data-validate` fails if the copies drift.

The PCG32 seeding rule and fixture contract are in [`fixtures/README.md`](../fixtures/README.md).
