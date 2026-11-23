# Shared game data

Versioned JSON loaded by both the Godot client and the Go server. Schemas live in
`data/schema/`. Times are **ticks** (20 Hz), angles are **degrees** in these files
and converted to radians (Godot 2D convention) at load. Distances are **tiles**.

This pack has the practice-yard enemies `burrmite` (`burr_spit`) and
`driftcap_spore` (`spore_ring`), the **Tallow Warden** boss and its Waxen
Acolyte adds, class bases and the three v0.1 class abilities, vision scaling
coefficients, client feel (`data/feel.json`), lobby UI copy and touch sizes (`data/lobby_ui.json`), v0.1 loot tables, and a first tiny
slice of **the Hollowmere Vault** (`data/dungeons/hollowmere_vault.json`,
validated by `dungeons.schema.json`). Defeating the Warden opens the vault exit. Official runs set `grants_persistent` true; the practice-yard entrance sets it false, so a practice vault grants nothing that persists outside it.
The `fixture_gap_ring` pattern used only by golden tests (to cover PCG32
`skip.start = "rng"`) lives in `fixtures/patterns/defs.json`, not in the
shipped game pack. Names and numbers follow
[`docs/design/content-v0.1.md`](../docs/design/content-v0.1.md).

The Godot client ships a copy under [`client/data/`](../client/data/) so the
JSON is packed into exports (`res://data`). `make sync-client-data` copies
`data/*.json` and `data/dungeons/*.json` there; `make data-validate` fails if the copies drift.

The PCG32 seeding rule and fixture contract are in [`fixtures/README.md`](../fixtures/README.md).
