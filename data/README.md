# Shared game data

Versioned JSON loaded by both the Godot client and the Go server. Schemas live in
`data/schema/`. Times are **ticks** (20 Hz), angles are **degrees** in these files
and converted to radians (Godot 2D convention) at load. Distances are **tiles**.

This PR introduces the first pack: one practice-yard enemy (`burrmite`) and its
`burr_spit` pattern, plus a `fixture_gap_ring` pattern used only by golden tests
(to cover PCG32 `skip.start = "rng"`). Names and numbers follow the unmerged
content spec in PR #4 so the full pack can replace this later.

The PCG32 seeding rule and fixture contract are in [`fixtures/README.md`](../fixtures/README.md).
