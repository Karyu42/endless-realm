# Shared game data

Versioned JSON loaded by both the Godot client and the Go server. Schemas live in
`data/schema/`. Times are **ticks** (20 Hz), angles are **degrees** in these files
and converted to radians (Godot 2D convention) at load. Distances are **tiles**.

This pack has the practice-yard enemies `burrmite` (`burr_spit`) and
`driftcap_spore` (`spore_ring`), class bases, vision scaling coefficients,
and v0.1 loot tables.
The `fixture_gap_ring` pattern used only by golden tests (to cover PCG32
`skip.start = "rng"`) lives in `fixtures/patterns/defs.json`, not in the
shipped game pack. Names and numbers follow
[`docs/design/content-v0.1.md`](../docs/design/content-v0.1.md).

The Godot client ships a copy under [`client/data/`](../client/data/) so the
JSON is packed into exports (`res://data`). `make sync-client-data` copies
`data/*.json` there; `make data-validate` fails if the copies drift.

The PCG32 seeding rule and fixture contract are in [`fixtures/README.md`](../fixtures/README.md).
