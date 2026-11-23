# Endless Realm: Content Spec (v0.1 first playable)

Status: draft for review · Owner: Game Design · Audience: Gameplay Engineer, QA · Depends on: [`vision.md`](vision.md) (PR #1)

This spec turns `vision.md` into numbers the engineer can put straight into `data/`. `vision.md` stays the source of truth for every formula. This doc only adds base values, patterns and the few rules `vision.md` leaves open. Where the two overlap, it cites a vision section instead of restating the rule. If they ever disagree, `vision.md` wins and this doc gets a fix. Engine, netcode and persistence follow [`docs/tech/stack.md`](../tech/stack.md): Godot 4.7.2 client, the Godot game as the lobby host (listen server or `--headless`, vision §11 and the PR #14 amendment), host-local saves, 20 Hz ticks.

All names and content are original. All numbers are starting values that Design can tune after playtests (vision §10, tuning ownership).

---

## 0. Conventions and rules this spec relies on

### 0.1 Units
- Distance in **tiles** (1.0 = one tile), speed in **tiles/s**, time written in seconds but every value is a multiple of 0.05 s, so it maps to whole **ticks at 20 Hz** (data files store ticks).
- Angles in **degrees** in data (the loader converts to radians). Godot 2D convention, as in `stack.md`: 0° = +X, +Y is down, positive = clockwise on screen.
- **Aimed** means the pattern's 0° offset points at the target's position at the spawn tick (no lead in v0.1). **Fixed** means an absolute angle.
- Every bullet flies in a straight line at constant speed, so positions stay closed-form. `lifetime_ticks = ceil(range / speed × 20)`.
- Bullet hit radius: **S** 0.15, **M** 0.25, **L** 0.40 tiles. Player hit radius 0.30. Each bullet hits once and is consumed, unless it is marked piercing.
- Randomness (target picks, spawn points, loot) uses the server's PCG32 with the instance seed (`stack.md`). The client never rolls.

### 0.2 Rules taken from `vision.md` (not restated here)
| Topic | Where it's defined |
|---|---|
| Content level E, M in whole hundredths (`M100`), off-step rejection, round-half-up | vision §6 |
| Extra boss rolls `floor((M100 − 100) / 25)` and Riftstone `round(4 × M²)` per eligible player | vision §6 |
| Opening a portal with a **Vault Sigil** (price, rules, refunds) | vision §5, §6 |
| Riftstone **deposit** `(5 × M100² + 9999) div 10000` for M > 1, refunded on a boss kill even if the opener is absent, refunded on a server fault, otherwise forfeited | vision §6, §7.3 |
| Effective level `Le = min(Lp, E + 5)` in portals, and which formulas use `Le` and which use the real `Lp` | vision §3.2a |
| `attackerLevel` in mitigation (`E` when an enemy hits; weapon gear level `W = max(1, 5 × T_eff)` when a player hits), rounding and min 1 | vision §3.2 |
| `D` factor, XP crediting (tenths of XP, under-level cap at `Le + 10`, over-level penalty) | vision §3.3, §3.4 |
| Effective tier `T_eff = min(T, T*(E) + 3)` | vision §4.1 |
| Personal loot and normal-kill eligibility (damaged it, or within 10 tiles when it died) | vision §4.2 |
| Player cap (the lobby's max players), the **boss-arena seal** (rule 6a: seals on first boss damage, no entry while sealed, reset when no living player is inside), boss eligibility and non-idle input, instance lifetimes, re-entry after death | vision §6.1 |
| Group scaling by peak players in range (`n_peak`): encounter groups, range, start/end events, the `s100(n)` curve to 50 players, and mid-encounter HP rises | vision §3.5 |
| Ground-item expiry (personal drops tombstoned `EXPIRED` 60 s after they drop, or when the instance closes), Wilds included | vision §8.2 |
| Incident windows and fault refunds | vision §7.3 |
| Pending loot and banking, Standard death order, hardcore separation, disconnect linger | vision §7 |
| Season track and Sparks (no Prism in v0.1) | vision §9 |

All examples below use these rules. With the vision §3.5 scaling, a peak of 8 players gives normal enemies ×5.2 HP and the boss ×6.25 (unchanged from the earlier 8-player rule; the curve is in vision §3.5).

### 0.3 Rules this spec adds
These fill gaps in `vision.md` and don't change any of its formulas:
- **When n is counted:** n is the encounter's `n_peak` (vision §3.5). Dungeon enemies spawn at the room's `n_peak` at activation, and later waves and boss adds spawn at the group's current `n_peak`. Wilds enemies scale too, per enemy or pack, from aggro to death, leash or de-aggro.
- **Scaled HP rounding:** max HP is computed in exact integer math and rounded half-up once, at spawn (or at the seal for the boss):
  `HP = (baseHP × m100(E) × s100(n) + 5000) div 10000`, where `m100(E) = 100 + 5 × (E − 1)` and `s100(n)` is the vision §3.5 curve (`100 + 60 × (n − 1)` for normal enemies and `100 + 75 × (n − 1)` for the boss up to n = 8, then +30 and +38 per extra player). When `n_peak` rises, max HP is recomputed and current HP keeps its fraction (vision §3.5). Phase thresholds compare current HP against `max HP × threshold` in the same integer math. Example: Tallow Warden at E=10, n=8 → `(5500 × 145 × 625 + 5000) div 10000 = 49,844`.
- **Fire on press (all weapons):** the first shot fires on the tick fire is pressed, if the weapon is off cooldown. The cooldown is `1 / (Tempo × (1 + tempoBonus))` seconds, counted from that shot, and it keeps running after release. Tapping can therefore never beat the fire rate. The exact rule is in §1.
- **Vault Sigil binding:** a Sigil is bound to the character who bought it (§3.5). This is consistent with vision §5 "not tradeable" and doesn't change it. If the buyer is **Fallen** (hardcore) or **deleted**, every Sigil bound to them, in inventory or in the stash, is tombstoned in the same transaction. The tombstone reason is `CONSUMED`, so there is no refund and no unusable leftovers. Vision §8.2 defines a tombstone as only `state`, `reason` and timestamp, and this spec adds **no item field**. As a content-level extension, the cause (`owner_fallen` or `owner_deleted`) is recorded as reason metadata in the audit entry of the transaction that tombstones the Sigils, not on the item row.
  - **Incident revert:** if a hardcore death is reverted inside an incident window (vision §7.3), the Sigils tombstoned in that death's transaction are un-tombstoned and restored to their owner with the same `item_uid` and location, as part of the same audited revert. Deleting a character is never reverted by an incident window. A pointer to this rule goes into vision §5 the next time `vision.md` is edited.
- **Hazard timing:** a hazard's `duration_ticks` does **not** include its telegraph. The telegraph runs first for `telegraph_ticks`, then the hazard is active for `duration_ticks` (details in §5).
- **Spiral emits and defaults:** see `spiral` in §5.

---

## 1. Classes

Stats, Focus (100, 5/s regen), costs, cooldowns and the ability rules are in vision §2. Stride and Tempo are fixed, with at most +10% from gear (D6). This section adds weapon patterns and the numbers vision leaves open. HP and Ward scale with `m(Le)` (vision §3.2a).

**Fire timing (fire on press, all weapons):** each weapon tracks `next_ready` as a float64 sim time in seconds (tick × 0.05), starting at 0. Let `cd = 1 / (Tempo × (1 + tempoBonus))`. On every tick where `fire_held` is true and `now ≥ next_ready − 1e-9`, one volley fires:
- If fire has been held on every tick since the previous volley (one continuous hold), set `next_ready = next_ready + cd`. This keeps the long-run rate exact even though `cd` isn't a whole number of ticks.
- Otherwise (the first volley after a press), set `next_ready = now + cd`.
- Releasing fire never resets `next_ready`. The cooldown keeps running, so a re-press fires only once `now ≥ next_ready`.
- **Blocked ticks (no catch-up):** a tick where firing is blocked (for example the Kindle Pulse 5-tick cast lock, §1.2) **breaks the continuous hold**. When the block ends, the next volley fires on the first tick where `now ≥ max(next_ready, block end)`, and the schedule restarts from that shot (`next_ready = now + cd`). There is never a catch-up burst.
- **Rate change mid-hold** (for example a charm swap changing `tempoBonus`): `cd` is recomputed at once, but it applies from the next scheduled shot. The pending `next_ready` stays as it is, and the new `cd` is added after the next volley fires.

Golden values:
- **Hold from a press on tick 0:** a Driftrunner (3.5/s, cd ≈ 0.2857 s) fires on ticks 0, 6, 12, 18, 23 and 29 …. A Thornguard (2.0/s) fires on ticks 0, 10, 20 ….
- **Tap:** if a Thornguard presses on tick 0, releases on tick 1 and presses again on tick 3, the volleys are tick 0 and then tick 10 (held from tick 3). Tapping every other tick fires no faster than holding.
- **Cast lock:** a Gleamwright (2.5/s, cd = 0.4 s = 8 ticks) holds fire from tick 0 and casts Kindle Pulse on tick 14, so firing is blocked on ticks 14–18. Volleys come on ticks 0 and 8. The volley due on tick 16 is blocked and fires on tick 19, then ticks 27, 35 …, with no extra volley.

### 1.1 Thornguard (close-range tank)
| Stat | Value |
|---|---|
| Base HP / Ward | 200 / 12 (× m(Le)) |
| Stride | 4.5 tiles/s |
| Tempo | 2.0 volleys/s |
| Hit radius | 0.30 |

**Starter weapon: Bramble Scattergun (T0)**
- 5 pellets per volley, 12 damage each at T0 (`12 × g(T)`).
- Spread 40° in total: pellets at −20°, −10°, 0°, +10°, +20° from aim.
- Speed 10 tiles/s, range 4 tiles (8 ticks), size S, no pierce.
- Point-blank volley at T0: 60 damage.

**Ability: Thorn Ward** · 40 Focus · 8 s cooldown (vision §2)
- Lasts 3 s (60 ticks). Self only. The ×0.50 and the recast rule are as in vision §2.
- Stride is unchanged and you can keep firing.
- It doesn't affect allies, so it doesn't count toward the ally-ability part of boss eligibility (vision §6.1).

### 1.2 Gleamwright (mid-range support)
| Stat | Value |
|---|---|
| Base HP / Ward | 140 / 6 |
| Stride | 5.0 tiles/s |
| Tempo | 2.5 volleys/s |

**Starter weapon: Lumen Rod (T0)**
- 1 bolt, 30 damage at T0 (`30 × g(T)`).
- Spread 0°, speed 14 tiles/s, range 7 tiles (10 ticks), size M.
- **Piercing:** it hits each enemy it passes through once, up to 3 enemies.

**Ability: Kindle Pulse** · 60 Focus · 6 s cooldown (vision §2)
- Instant heal for every player within 4 tiles, including yourself, for 25% of each target's max HP (rounding as in vision §2). It can't overheal.
- 0.25 s cast lock (5 ticks): you can't fire during it, but you can move.
- Each cast that heals an ally counts toward boss eligibility (b) in vision §6.1.

### 1.3 Driftrunner (long-range skirmisher)
| Stat | Value |
|---|---|
| Base HP / Ward | 120 / 4 |
| Stride | 6.0 tiles/s |
| Tempo | 3.5 volleys/s |

**Starter weapon: Gale Sling (T0)**
- 2 parallel bolts per volley, 14 damage each at T0 (`14 × g(T)`).
- The bolts are offset ±0.20 tiles perpendicular to aim, both at 0°.
- Speed 18 tiles/s, range 9 tiles (10 ticks), size S, no pierce.

**Ability: Slipstep** · 30 Focus · 3 s cooldown (vision §2)
- Blink 4 tiles in your move direction, or your aim direction when you are standing still.
- Wall handling is as in vision §2 (it stops at the last free tile). Closed doors and the sealed arena wall count as blocking tiles.
- 0.30 s (6 ticks) of no damage, starting on the blink tick.

### 1.4 DPS reference (T0, every shot hitting, before Ward)
| Class | Per volley | Volleys/s | Sustained DPS |
|---|---|---|---|
| Thornguard | 60 (point blank) | 2.0 | 120 |
| Gleamwright | 30 (×3 if it pierces 3 targets) | 2.5 | 75 single target |
| Driftrunner | 28 | 3.5 | 98 |

**Time-to-kill target.** Enemy HP is tuned against a solo player with **on-level gear** (`T = T*(E)`, so `W = 5 × T*`), at `D = 1`, after enemy Ward, with these assumed hit rates:
- Thornguard: 60% of pellets (3 of 5 at 2–3 tiles).
- Gleamwright: 80%, single target.
- Driftrunner: 70%.

The targets are:
- 1–5 s for a normal enemy
- 20–30 s for the elite
- about 100 s for the boss solo, including about 5 s of phase transitions

Per-ring results (the range across the three classes, from the band's low to high level):

| Content | Enemies | Solo TTK |
|---|---|---|
| Ring 1 (E 1–5) | Burrmite, Driftcap Spore | 0.8–1.5 s |
| Ring 2 (E 6–10) | Reedling Slinger, Mossback Boar | 1.4–3.2 s |
| Ring 3 (E 11–15) | Cinderwisp, Gloomlantern Sentinel | 1.5–4.8 s |
| Ring 4 (E 16–20) | Thornwing Harrier, Gloomlantern Sentinel | 2.3–4.6 s |
| Ring 4 elite | Mirebell Matron | 22–27 s |
| Vault trash (E 10–15) | Wickhound, Waxen Acolyte, plus the ring-3 types | 1.3–4.8 s |
| Tallow Warden (E 10) | | 89–106 s of damage time, plus 5 s of transitions |

Because `g(T*) ≈ m(E)` and Ward is normalized, these times stay nearly flat at every level (vision §4.1).

With vision §3.5 scaling, an 8-player boss has ×6.25 HP against about ×8 DPS, so the fight is about 80 s.

### 1.5 Controls assumption
- **Desktop:** WASD to move, mouse to aim, hold the left button to fire, Space or the right button for the ability, E to interact or loot, 1–8 for inventory slots, Enter for chat.
- **Android:** twin-stick (left stick moves, right stick aims and fires while held), an ability button above the right stick, a tap-to-loot prompt, and an optional auto-fire toggle.
- **Input frame:** the tech stack's `(move, aim, fire_held, seq)` plus one `ability_pressed` bit and an optional `interact_target_id`. The ability fires on the tick the server receives it, if Focus and the cooldown allow.

---

## 2. Wilds enemies

### 2.1 Layout of the Wilds
- The Wilds are a circle of radius 120 tiles. The Hearth gate sits on the south edge.
- Enemy level depends on distance `r` from the center: `E = clamp(20 − floor(r / 6), 1, 20)`.
- Rings are half-open intervals, so every point belongs to exactly one ring. The boundary `r = 90` is in ring 1 (E 5), and `r = 89.9` is in ring 2 (E 6).

| Ring | Name | r (tiles) | Levels | Live population | Roster (spawn weight) |
|---|---|---|---|---|---|
| 1 | Saltreach Verge | 90 ≤ r ≤ 120 | 1–5 | 60 | Burrmite 60 (packs of 3), Driftcap Spore 40 |
| 2 | Fernmoor | 60 ≤ r < 90 | 6–10 | 50 | Mossback Boar 50, Reedling Slinger 50 (pairs) |
| 3 | Ashen Glade | 30 ≤ r < 60 | 11–15 | 40 | Cinderwisp 55 (pairs), Gloomlantern Sentinel 45 |
| 4 | Hollow Heart | 0 ≤ r < 30 | 16–20 | 30 + 1 elite | Thornwing Harrier 70, Gloomlantern Sentinel 30, Mirebell Matron (elite) |

- **Respawn:** 20 s after a death, at a random walkable point in the same ring at least 12 tiles from every player. An enemy's level is fixed when it spawns, from its spawn point.
- **Leash:** if an enemy is pulled more than 16 tiles from its spawn point, or into another ring, it walks back and heals to full.
- **Mirebell Matron:** two are alive in ring 4 at a time, at 2 of 4 fixed lairs. Each respawns 4 min after she dies, and the server announces it in the Hearth: "The Matron's bells ring in the Hollow Heart." With the vision §6 found-portal chance of 10%, that is about one free portal every 20 min per world.

### 2.2 Stat table
`baseHP`, `baseWard` and the damage values are what goes into the formulas (vision §3.2): `HP = baseHP × m(E)`, `Damage = baseDmg × m(E)`, `Ward = baseWard × m(E)`. The "HP at band" column shows the result at the lowest and highest level of each band.

| Enemy | Band | baseHP | HP at band (lo–hi) | baseWard | Contact dmg | Projectile dmg | Move speed | Radius | XP / Glint at band lo (per eligible player) |
|---|---|---|---|---|---|---|---|---|---|
| Burrmite | 1–5 | 60 | 60–72 | 0 | 8 | 10 | 3.5 | 0.35 | 10.0 / 1 |
| Driftcap Spore | 1–5 | 90 | 90–108 | 2 | 0 | 12 | 0 (static) | 0.50 | 10.0 / 1 |
| Mossback Boar | 6–10 | 180 | 225–261 | 6 | 25 | 15 | 2.5 (10 charging) | 0.55 | 12.5 / 2 |
| Reedling Slinger | 6–10 | 100 | 125–145 | 3 | 6 | 14 | 3.0 | 0.40 | 12.5 / 2 |
| Cinderwisp | 11–15 | 110 | 165–187 | 4 | 10 | 10 | 5.0 | 0.35 | 15.0 / 2 |
| Gloomlantern Sentinel | 11–20 | 260 | 390–507 | 10 | 15 | 18 ring / 20 fan | 1.2 | 0.60 | 15.0 / 2 |
| Thornwing Harrier | 16–20 | 160 | 280–312 | 8 | 20 | 16 | 4.0 (12 diving) | 0.45 | 17.5 / 2 |
| **Mirebell Matron** (elite) | 16–20 | 1400 | 2450–2730 | 15 | 30 | 16 spiral / 22 fan | 1.5 | 0.90 | 87.5 / 2 |

- **XP:** `killXP(E)` for normal enemies, ×5 for elites, credited in tenths as in vision §3.4.
- **Glint:** `ceil(m(E))` per eligible player for every non-boss kill, the elite included (vision §5).
- **Contact damage** is applied at most once per 0.5 s per enemy–player pair.

### 2.3 Behaviors and patterns
"Every X s" is measured from the end of the previous attack, and the first attack comes X s after aggro. **AI `fire` steps don't block.** A `fire` step starts the pattern and the AI goes straight to its next step, while multi-emit patterns (bursts, spirals) keep emitting on their own. Any wait after an attack is an explicit `wait` step measured from the `fire` step. For the AI-step enemies below, the listed waits already include this, so an Acolyte cross (emits on ticks 0 and 10) starts every 48 ticks, which is 38 ticks after its last emit. Aggro radius is 8 tiles unless stated otherwise. The target is the nearest player in aggro range, re-picked every 1 s.

**Burrmite** (skittering beetle, packs of 3)
- AI: wanders at 1.5 tiles/s. On aggro it closes to 3 tiles, then strafes around the target at 3 tiles, switching direction every 2 s.
- `burr_spit`: 1 bullet, aimed, speed 6, range 6, size S, every 1.5 s.

**Driftcap Spore** (rooted mushroom)
- AI: never moves. It wakes when a player is within 8 tiles.
- `spore_ring`: 8 bullets in a ring (45° apart), speed 4, range 5, size M, every 2.0 s. The start angle is 0° for the first ring and then alternates with 22.5°, so each ring fills the gaps of the last.

**Mossback Boar** (charging boar)
- AI: wanders. On aggro it keeps 5–7 tiles away, then charges.
- `boar_charge`: telegraph for 0.6 s (paws the ground, with a lane shown on the floor), then dashes 10 tiles/s for 0.8 s toward the target's position at the end of the telegraph. Contact damage applies during the dash. The charge stops early at a wall.
- `boar_burst`: when the charge ends, a fan of 3 bullets with 30° total spread, aimed, speed 7, range 7, size M.
- Cycle: charge, burst, 3.0 s recovery (wandering slowly), repeat.

**Reedling Slinger** (reed-cloaked archer, pairs)
- AI: kites. It keeps 6 tiles from the target and backs off at 3.0 tiles/s if you close to under 4.
- `reed_volley`: 3 bullets in a burst 0.15 s apart, each aimed at fire time, speed 9, range 9, size S. Repeats every 2.2 s.

**Cinderwisp** (floating ember, pairs)
- AI: on aggro it orbits the target at radius 4 tiles, at 90°/s around the target's live position. Each wisp picks a direction at spawn (50/50).
- `wisp_spiral`: 1 bullet every 0.2 s for 2.0 s (10 bullets). The first bullet is aimed, and each next one is rotated +25°. Speed 5, range 7.5, size S. Then a 2.0 s pause before repeating.

**Gloomlantern Sentinel** (slow lantern-headed golem)
- AI: walks toward the target at 1.2 tiles/s and stops at 5 tiles. Aggro radius 10.
- It alternates two attacks with a 1.25 s gap between them. The alternation and the gap are **`enemies.json` AI steps**, not pattern fields: `wait 25` → `fire lantern_ring` → `wait 25` → `fire lantern_fan` → repeat, with `approach` (stop at 5 tiles) running in parallel. The first `fire` is 25 ticks after aggro.
  - `lantern_ring`: 12 bullets in a ring (30° apart), speed 5, range 10, size M, 18 damage. Each new ring is rotated +15° from the last one.
  - `lantern_fan`: 5 bullets in a fan with 60° total spread, aimed, speed 8, range 8, size M, 20 damage.

**Thornwing Harrier** (thorn-feathered raptor)
- AI: circles at 6 tiles, then dives.
- `harrier_dive`: telegraph for 0.5 s (screech, with a line shown), then flies 12 tiles/s for 0.6 s through the target's position. Contact damage applies during the dive.
- `harrier_quills`: during the dive, every 0.1 s (6 times), 2 bullets go out perpendicular to its flight (+90° and −90°), speed 4, range 4, size S. Together they leave a "comb" of quills along its path.
- Cycle: circle for 2.5 s, dive, repeat.

**Mirebell Matron** (elite: a swamp hag who carries a ring of bells)
- AI: slow chase at 1.5 tiles/s, stays 4–6 tiles away. Aggro radius 12. She doesn't leash while any eligible player is within 20 tiles.
- She runs a fixed sequence on repeat:
  1. `matron_tolling` (3.0 s): a 3-arm spiral. Arms are 120° apart and emit 1 bullet each every 0.15 s, rotating +12° per emit. Speed 4.5, range 9, size M, 16 damage.
  2. `matron_peal` (1.0 s): two volleys 0.5 s apart. Each volley is 7 bullets in a fan with 70° total spread, aimed, speed 7, range 10.5, size M, 22 damage.
  3. `matron_brood`: below 50% HP only, once every second cycle. She summons 3 Burrmites at her level next to her. They give no loot, XP or Glint, and a cap of 6 summons can be alive at once.
  4. A 1.5 s pause.
- **Portal drop:** on death, there is a 10% chance a found Hollowmere Vault portal appears where she died (vision §6, and §3.5 here).
- **Loot:** she uses the normal-enemy rules of vision §4.2 (4%, Normal row) and Glint rule of vision §5. Her XP is the vision §3.4 elite ×5.

---

## 3. Dungeon: the Hollowmere Vault

Base level 10. B, E and M are as in vision §6. Player cap, lifetimes and re-entry are as in vision §6.1; scaling is vision §3.5.

### 3.1 Layout
The vault is a linear crypt of sunken candle halls: 6 rooms joined by 3-tile-wide corridors. The layout is hand-authored, not procedural, in v0.1.

```
[1 Antechamber] → [2 Drip Hall] → [3 Wick Kennels] → [4 Censer Gallery] → [5 Wax Chapel] → [6 Warden's Sanctum (boss)]
     12×12            18×14           16×16              20×12               18×18                 21×21, 4 pillars
```

- **Room activation:** a room's enemies spawn and wake when the first player enters it. That starts the room's encounter and its `n_peak` (vision §3.5), which keeps rising if more players arrive. Doors never lock in rooms 1–5, and players can retreat.
- **Room 6** seals, lifts and resets as in vision §6.1 rule 6a. The client shows a "the doors are sealed" cue on the seal tick.
- **Clear rule:** room 6's door opens once rooms 2–5 are all cleared (every enemy dead). This stops players skipping straight to the boss.
- **Exit:** when the boss dies, the exit portal to the Hearth spawns in the center of room 6, together with the loot bags. The bags expire after 60 s (vision §8.2), so the client shows a countdown on each one.

### 3.2 Vault enemies
These enemies spawn at the instance's level E and use the normal-enemy `n_peak` scaling from vision §3.5.

| Enemy | baseHP | baseWard | Contact | Projectile | Move | Radius |
|---|---|---|---|---|---|---|
| Waxen Acolyte | 150 | 8 | 12 | 18 | 2.5 | 0.45 |
| Wickhound | 90 | 4 | 22 | 12 (death burst) | 6.0 | 0.40 |
| Cinderwisp (vault) | as in §2 | | | | | |
| Gloomlantern Sentinel (vault) | as in §2 | | | | | |

**Waxen Acolyte** (hooded figure that drips wax)
- AI: keeps 5 tiles away and side-steps 2 tiles every 3 s.
- `acolyte_cross`: 4 bullets in a "+" shape (fixed 0°, 90°, 180°, 270°), then 0.5 s later 4 more in an "×" (45°, 135°, 225°, 315°). Speed 5, range 8, size M. Every 2.4 s.
- Every third cycle it fires `acolyte_aim` instead: 1 aimed bullet, speed 9, range 10, size M.
- **AI steps (`enemies.json`):** a `sequence` with a cycle counter. Steps: `keep_range 5` (parallel) → `wait 48` → `fire acolyte_cross` → `wait 48` → `fire acolyte_cross` → `wait 48` → `fire acolyte_aim` → repeat. A `sidestep 2 tiles` step runs on its own 60-tick timer (3 s). The first `fire` is 48 ticks (2.4 s) after aggro, and patterns use `trigger: ai_step`, not `timer`.

**Wickhound** (lean candle-hound with a burning wick tail)
- AI: chases at 6 tiles/s and pounces within 2 tiles: a 0.3 s windup, then a 0.25 s lunge at 12 tiles/s. It pauses 1.0 s after each lunge.
- `wick_burst`: on death, 6 bullets in a ring (60° apart, start angle 30°), speed 4, range 4, size S.

**Rosters**
| Room | Enemies | Notes |
|---|---|---|
| 1 Antechamber | none | Safe room for gathering the party. The portal arrival point is here. |
| 2 Drip Hall | 4 Waxen Acolyte, 2 Cinderwisp | Acolytes on the side ledges, wisps in the center |
| 3 Wick Kennels | 8 Wickhound in 2 waves (the 2nd wakes when the 1st dies or after 15 s) | Tests movement |
| 4 Censer Gallery | 2 Gloomlantern Sentinel, 3 Waxen Acolyte | The long room makes ranged play stronger |
| 5 Wax Chapel | 4 Waxen Acolyte, 4 Wickhound, 2 Cinderwisp | Peak trash fight, about 45 s solo |
| 6 Warden's Sanctum | Tallow Warden | §3.4 |

A full solo clear on-level takes about 8–10 min (trash about 5 min, boss about 100 s), which fits the vision §1 loop.

### 3.3 Boss stats: the Tallow Warden
A towering warden made of stacked, melting candles. It carries a lantern-staff, and the flame on its crown changes color with each phase.

| Stat | Value |
|---|---|
| baseHP | 5500 (E=10 solo: 7,975 · E=10 with 8 players: 49,844; rounding in §0.3) |
| baseWard | 20 |
| Contact damage | 40 |
| Projectile damage | P1 22 / 28 · P2 20 / 30, pools 15 per 0.5 s · P3 22 / 26 |
| Move | 1.5 tiles/s (P1), 1.0 (P2), 0 (P3: anchored at the center) |
| Radius | 1.20 |
| XP | `killXP × 50` = 725.0 at E=10 (vision §3.4) |
| Glint | `ceil(m(E)) × 30` = 60 at E=10 (vision §5) |

**Targeting:** aimed attacks pick a random **living player in the arena** (PCG32). They never pick the same player more than twice in a row when someone else is available.

### 3.4 Boss phases
The thresholds are fractions of the scaled max HP. A transition happens on the first tick HP is at or below the threshold. During a transition the boss takes no damage, and bullets already in flight continue.

**Phase 1, "Steady Flame" (100% to 66%)**: the boss walks slowly toward the arena center and drifts around it.
- `warden_wickring`: 16 bullets in a ring (22.5° apart), speed 5, range 12, size M, 22 damage, every 1.6 s. Each ring is rotated +11.25° from the last.
- `warden_drip`: a fan of 3 bullets with 20° total spread, aimed, speed 8, range 12, size L, 28 damage. It fires every 1.0 s, offset 0.5 s from the ring.

**Transition at 66%, "Melt"** (2.0 s): the boss can't be damaged and its crown flame turns orange. It spawns 4 Waxen Acolytes, one in each corner. Their HP uses the normal-enemy scaling with the boss fight's `n`, and they drop no loot.

**Phase 2, "Guttering" (66% to 33%)**: a 6.0 s loop.
- `warden_spiral` (0–4 s): a 4-arm spiral. Arms are 90° apart and emit 1 bullet each every 0.1 s, rotating +9° per emit. Speed 4, range 12, size S, 20 damage.
- `warden_pools`: at the start of each loop, one telegraphed wax pool under each of up to 3 random living players in the arena. Each pool has radius 1.5 tiles and a 1.0 s telegraph, then stays active for 4.0 s (5.0 s in total; the 4.0 s does not include the telegraph). A player standing in it takes 15 damage every 0.5 s and moves at −30% Stride. This is a debuff, not a stat change, so the D6 cap doesn't apply.
- `warden_lunge_fan` (4–6 s): 2 fans 1.0 s apart. Each fan is 5 bullets with 50° total spread, aimed, speed 9, range 13.5, size L, 30 damage.

**Transition at 33%, "Last Wick"** (3.0 s): the boss can't be damaged. It walks to the arena center and anchors there, and its crown flame turns white.

**Phase 3, "Last Flame" (33% to 0%)**
- `warden_twinspiral`: two 3-arm spirals running at the same time. Arms in each set are 120° apart. Set A rotates +8° per emit and set B −8°. Each arm emits every 0.15 s. Speed 4.5, range 13.5, size S, 22 damage. This runs continuously.
- `warden_gapring`: every 3.0 s, a 24-bullet ring (15° apart) with 4 consecutive bullets left out. The gap's start index is a PCG32 roll of 0–23, which leaves one safe lane. Speed 6, range 12, size M, 26 damage.
- **Soft enrage:** the enrage timer starts on the seal tick, which is the tick the boss first takes damage (vision §6.1 rule 6a). It counts every tick, transitions included, and resets when the boss resets. From tick 4,800 (240 s), every attack interval in P3 is ×0.80; if the boss isn't in P3 yet, that applies from the moment P3 begins. This depends on time only, not on M (vision §6: M doesn't change patterns).

**Death:** loot (§4.2), XP, Glint and Riftstone go to every eligible player (vision §6.1). The deposit is refunded to the opener even if they are absent (vision §6). The exit portal spawns, and pools and all live enemy bullets are cleared.

### 3.5 How you get in: portal drops and open cost
There are two ways in.

**A. Found portal (Wilds, free, M = 1.00).**
- An elite (in v0.1, the Mirebell Matron) has a 10% chance to leave a Vault portal when it dies (vision §6). With 2 Matrons alive and a 4 min respawn plus about 25 s solo kill time, that works out to about one free portal every 20 min per world.
- It is M = 1.00 with no deposit and no opener. B is the higher of 10 and the Matron's level, so E is 16–20.
- Lifetimes, the join floor and the player cap are as in vision §6.1.

**B. Opened portal (Hearth portal board, chosen M).**
- Opening uses one **Vault Sigil** and, when M > 1.00, the Riftstone deposit. They are taken in one transaction with the instance's creation (vision §6).
- The Sigil's price (`150 × m(Lp)` Glint), tradeability, the `CONSUMED` tombstone and the fault refund are as in vision §5, §6 and §7.3.
- **Source:** Sigils come only from the Hearth vendor in v0.1 (vision §5). Nothing drops them.
- **Binding (content-level clarification, consistent with vision's "not tradeable"):** a Sigil is bound to the character who bought it. It can sit in that character's inventory or in the stash. A Sigil in the stash keeps `owner_character` = the buyer, and only the buyer can withdraw or use it, even though the stash is shared by the account. It can't be traded, given away or moved to another character. Sigils stack to 10 per slot. If the buyer is Fallen or deleted, their bound Sigils are tombstoned `CONSUMED` (§0.3).

---

## 4. Loot

### 4.1 Item slots and stat lines (v0.1)
Each item has one base type, a tier T, and a server-minted `item_uid` (vision §8.2). There are no affixes or rarity in v0.1.

| Slot | Base types | Stat line(s) |
|---|---|---|
| Weapon | Bramble Scattergun (Thornguard), Lumen Rod (Gleamwright), Gale Sling (Driftrunner) | Damage per projectile = class base × g(T): 12 / 30 / 14 |
| Armor | Wardweave (all classes) | +HP `30 × g(T)`, +Ward `4 × g(T)` (vision §4.1), both rounded half-up |
| Charm | Ember Charm (all classes) | Exactly one line, rolled when it drops (table below) |

| Charm line | Weight | Value |
|---|---|---|
| +HP | 30 | `20 × g(T)`, rounded half-up |
| +Ward | 30 | `3 × g(T)`, rounded half-up |
| +Focus regen | 20 | +1 /s (flat) |
| +Stride | 10 | 2–10% (uniform, 1% steps). It doesn't scale with T. |
| +Tempo | 10 | 2–10% (same as Stride) |

- Since there is only one charm slot, the +10% cap on Stride and Tempo (D6) holds automatically. The server still clamps the total at +10%.
- A charm can be re-rolled for Riftstone (vision §5). The new line uses the same weights.
- Display name: `<Base> T<n>`, for example "Lumen Rod T4".
- Bag color shows tier compared with T* of the content it dropped in: brown for ≤ T*, teal for T*+1, gold for T*+2 or higher.

### 4.2 Drop chances
| Source | Item chance | Items | Tier row (vision §4.2) | Other drops |
|---|---|---|---|---|
| Wilds normal enemy | 4% | 1 | Normal | — |
| Vault normal enemy | 4% | 1 | Normal | — |
| Mirebell Matron (elite) | 4% | 1 | Normal | Found portal 10% (vision §6) |
| Tallow Warden (boss) | 100% | 2 + extra rolls (vision §6) | Boss | Riftstone (§4.4) |
| Boss phase adds / Matron summons | 0% | — | — | — |

- **Slot weights** for every item roll: weapon 40, armor 35, charm 25.
- **Weapon class:** 70% the looter's class, and 15% for each of the other two (that 30% feeds trading).

### 4.3 Tier roll against content level and M
1. Take the content level `E`:
   - Wilds: the enemy's level.
   - Vault: the instance's `E`, which already includes M (vision §6).
   - Synced players still roll against `E`, never against their own level.
   - Eligibility for the roll is as in vision §4.2 (normal kills) and vision §6.1 (boss).
2. `T* = floor(E / 5)`.
3. Roll the offset from the vision §4.2 row: Normal is −1/0/+1/+2 at 25/65/9/1%, and Boss is 0/+1/+2 at 50/40/10%. `T = max(0, T* + offset)`.
4. When the item is used against an enemy of level E′, it fights at `T_eff` (vision §4.1).

M only affects loot through `E` (and so T*), plus the vision §6 extra boss rolls. Example tiers for a Vault run opened by a level-10 player:

| M | E | T* | Boss item rolls | Normal row range | Boss row range |
|---|---|---|---|---|---|
| 0.50 | 5 | T1 | 2 | T0–T3 | T1–T3 |
| 1.00 | 10 | T2 | 2 | T1–T4 | T2–T4 |
| 1.25 | 13 | T2 | 3 | T1–T4 | T2–T4 |
| 1.50 | 15 | T3 | 4 | T2–T5 | T3–T5 |

### 4.4 Echo Dust and Riftstone yields
**Echo Dust:** it only comes from salvage (vision §5), at `5 × g(T)` rounded half-up. Tier-up from T to T+1 costs `20 × g(T+1)` Dust and `100 × g(T+1)` Glint.

| T | 0 | 1 | 2 | 3 | 4 | 5 | 20 |
|---|---|---|---|---|---|---|---|
| Salvage yield (Dust) | 5 | 6 | 8 | 9 | 10 | 11 | 30 |
| Tier-up into T, Dust / Glint | — | 25 / 125 | 30 / 150 | 35 / 175 | 40 / 200 | 45 / 225 | 120 / 600 |

**Riftstone:** the Warden grants `(4 × M100² + 5000) div 10000` (= `round(4 × M²)`) per eligible player, and the deposit works as in vision §6. Nothing else drops Riftstone in v0.1. This table only illustrates those formulas:

| M | 0.50 | 0.75 | 1.00 | 1.25 | 1.50 |
|---|---|---|---|---|---|
| Yield per eligible player | 1 | 2 | 4 | 6 | 9 |
| Deposit `(5 × M100² + 9999) div 10000`, refunded on a boss kill | 0 | 0 | 0 | 8 | 12 |
| Net for a solo clear | +1 | +2 | +4 | +6 | +9 |

Riftstone sinks (forfeited deposits and charm re-rolls) are listed in vision §5. Stash pages cost Glint only.

### 4.5 Bonus rolls
The only bonus rolls in v0.1 are the vision §6 extra boss rolls for M > 1. A player at M=1.50 rolls 2 + 2 = **4** Warden items. There is no pity system in v0.1 (see §6).

---

## 5. Data format

JSON under `data/`, with a JSON Schema next to each file, as `docs/tech/stack.md` recommends. Both the Godot host and the Godot client (one shared sim) load the same files, as does the Go reference harness while it exists. Times are stored in **ticks**, angles in **degrees**, and distances in **tiles**. Formulas stay in code and read their coefficients from `scaling.json`.

```
data/
  scaling.json          # coefficients for vision formulas: m, g, XP, D, group HP scaling (vision §3.5: normal k/t 60/30, boss 75/38, kink 8, n_max 50), sync +5, Riftstone 4/5
  classes.json          # stats, weapon_id, ability_id
  weapons.json
  abilities.json
  patterns.json         # every bullet pattern by id
  enemies.json          # stats + AI + pattern refs
  dungeons/hollowmere_vault.json
  loot.json             # tier rows, drop tables, slot weights
  wilds.json            # rings, populations, respawn
  schema/*.schema.json
```

**Schemas:** `validate-data.py` looks up `data/schema/<file stem>.schema.json` first, then `data/schema/<parent dir>.schema.json`. So:
- `data/dungeons/hollowmere_vault.json` is validated by **`data/schema/dungeons.schema.json`**. That one schema covers every future dungeon file in `data/dungeons/`.
- Every other top-level file uses its own `<stem>.schema.json` (`scaling`, `classes`, `weapons`, `abilities`, `patterns`, `enemies`, `loot`, `wilds`).
- A data file with no matching schema, or a schema no file uses, fails or warns in `data-validate`.

**patterns.json**

*Pattern types.* Every bullet type flies straight at constant speed, so it stays closed-form (`stack.md`). The server broadcasts one `PatternSpawn` per emission. A `hazard` is broadcast as its own spawn, not as bullets.

| Type | Meaning | Type-specific fields |
|---|---|---|
| `fan` | N bullets spread evenly across a total arc. N = 1 is a single shot. | `count`, `spread_deg` |
| `ring` | N bullets 360°/N apart | `count`, `skip` (optional: `{consecutive, start: int or "rng"}`) |
| `spiral` | K arms that each emit one bullet every interval, rotating as they go. Emits happen at ticks 0, e, 2e … **strictly less than** `duration_ticks` (exclusive), so `wisp_spiral` (e 4, duration 40) gives 10 emits. **Defaults:** `aim: "aimed"` (arm 0 points at the target on emit 0; the other arms are offset by 360°/K) and `start_angle_deg: 0`. `matron_tolling` and `warden_spiral` use these defaults | `arms`, `emit_interval_ticks`, `rotate_per_emit_deg`, `duration_ticks` (0 = until the phase ends) |
| `burst` | Repeats a child pattern N times | `repeats`, `interval_ticks`, `reaim` (bool), `angle_offset_per_repeat_deg`, `child` (inline pattern) |
| `line_drop` | While the source moves, emits bullets at angles relative to its heading | `emit_interval_ticks`, `emits`, `angles_rel_heading_deg[]` |
| `hazard` | A ground area that hurts and/or slows players inside it. Each pool is **placed at the target's position on the spawn tick**, when the telegraph starts, and doesn't move. The telegraph runs `telegraph_ticks` with no effect, then the pool is active for `duration_ticks`. Damage applies on active ticks 0, t, 2t … < duration. `warden_pools`: 20-tick (1.0 s) telegraph, then 80 ticks (4.0 s) active, 5.0 s in total, so a player who stays in it takes at most 8 hits | `shape` (`circle`), `radius`, `placement` (`under_targets`), `max_targets`, `telegraph_ticks`, `duration_ticks`, `tick_interval_ticks`, `damage_key`, `slow_pct` |

*Common fields* (all bullet types):
- `speed`, `range`, `size`, `damage_key`
- `aim`: `aimed` (at the target), `fixed` (absolute), or `heading` (the source's facing)
- `start_angle_deg`
- **Per-volley angle:** `rotate_per_fire_deg` adds k × value on volley k. `angle_offset_cycle_deg[]` adds `list[k mod len]` on volley k. Use one or the other.
- `trigger`:
  - `timer`: from an AI loop or a phase loop
  - `ai_step`: fired by an AI `fire` step
  - `on_death`: fired once, at the death position, on the death tick
  - `phase_enter`

*Mapping of every pattern in this spec:*

| Pattern | Type | Key fields |
|---|---|---|
| `burr_spit` | fan | count 1, aimed, speed 6, range 6, S, trigger timer 30 |
| `spore_ring` | ring | count 8, fixed, start 0, `angle_offset_cycle_deg [0, 22.5]`, speed 4, range 5, M, timer 40 |
| `boar_burst` | fan | count 3, spread 30, aimed, speed 7, range 7, M, `ai_step` (end of charge) |
| `reed_volley` | burst | repeats 3, interval 3, reaim true, child fan count 1 aimed speed 9 range 9 S; timer 44 |
| `wisp_spiral` | spiral | arms 1, emit 4, rotate +25, duration 40, aim aimed at the first emit, speed 5, range 7.5, S; timer 40 (the 2 s pause) |
| `lantern_ring` | ring | count 12, fixed, `rotate_per_fire_deg 15`, speed 5, range 10, M |
| `lantern_fan` | fan | count 5, spread 60, aimed, speed 8, range 8, M |
| `harrier_quills` | line_drop | emit 2, emits 6, `angles_rel_heading_deg [90, -90]`, speed 4, range 4, S, `ai_step` (dive start) |
| `matron_tolling` | spiral | arms 3, emit 3, rotate +12, duration 60, speed 4.5, range 9, M |
| `matron_peal` | burst | repeats 2, interval 10, reaim true, child fan count 7 spread 70 aimed speed 7 range 10.5 M |
| `acolyte_cross` | burst | repeats 2, interval 10, reaim false, `angle_offset_per_repeat_deg 45`, child ring count 4 fixed start 0 speed 5 range 8 M; timer 48 |
| `acolyte_aim` | fan | count 1, aimed, speed 9, range 10, M (every 3rd cycle instead of the cross) |
| `wick_burst` | ring | count 6, fixed, start 30, speed 4, range 4, S, trigger `on_death` |
| `warden_wickring` | ring | count 16, fixed, `rotate_per_fire_deg 11.25`, speed 5, range 12, M |
| `warden_drip` | fan | count 3, spread 20, aimed, speed 8, range 12, L |
| `warden_spiral` | spiral | arms 4, emit 2, rotate +9, duration 80, speed 4, range 12, S |
| `warden_pools` | hazard | circle r 1.5, `under_targets`, max 3, telegraph 20, duration 80, tick 10, slow 30 |
| `warden_lunge_fan` | burst | repeats 2, interval 20, reaim true, child fan count 5 spread 50 aimed speed 9 range 13.5 L |
| `warden_twinspiral_a` / `_b` | spiral | arms 3, emit 3, rotate +8 / −8, duration 0, speed 4.5, range 13.5, S |
| `warden_gapring` | ring | count 24, fixed, `skip {consecutive 4, start "rng"}`, speed 6, range 12, M; timer 60 |

The charges, dives, pounces and the Matron's summon are AI actions with contact damage, not patterns (see `enemies.json`).

*Examples*
```json
{ "id": "warden_wickring", "type": "ring", "count": 16, "aim": "fixed", "start_angle_deg": 0,
  "rotate_per_fire_deg": 11.25, "speed": 5.0, "range": 12.0, "size": "M", "damage_key": "p1_ring",
  "trigger": "timer" }
```
```json
{ "id": "spore_ring", "type": "ring", "count": 8, "aim": "fixed", "start_angle_deg": 0,
  "angle_offset_cycle_deg": [0, 22.5], "speed": 4.0, "range": 5.0, "size": "M", "damage_key": "ring",
  "trigger": "timer" }
```
```json
{ "id": "acolyte_cross", "type": "burst", "repeats": 2, "interval_ticks": 10, "reaim": false,
  "angle_offset_per_repeat_deg": 45, "trigger": "timer",
  "child": { "type": "ring", "count": 4, "aim": "fixed", "start_angle_deg": 0,
             "speed": 5.0, "range": 8.0, "size": "M", "damage_key": "cross" } }
```
```json
{ "id": "harrier_quills", "type": "line_drop", "emit_interval_ticks": 2, "emits": 6,
  "angles_rel_heading_deg": [90, -90], "aim": "heading", "speed": 4.0, "range": 4.0, "size": "S",
  "damage_key": "quill", "trigger": "ai_step" }
```
```json
{ "id": "wick_burst", "type": "ring", "count": 6, "aim": "fixed", "start_angle_deg": 30,
  "speed": 4.0, "range": 4.0, "size": "S", "damage_key": "death_burst", "trigger": "on_death" }
```
```json
{ "id": "warden_pools", "type": "hazard", "shape": "circle", "radius": 1.5,
  "placement": "under_targets", "max_targets": 3, "telegraph_ticks": 20, "duration_ticks": 80,
  "tick_interval_ticks": 10, "damage_key": "p2_pool", "slow_pct": 30, "trigger": "timer" }
```
```json
{ "id": "warden_twinspiral_a", "type": "spiral", "arms": 3, "emit_interval_ticks": 3,
  "rotate_per_emit_deg": 8, "duration_ticks": 0, "aim": "fixed", "start_angle_deg": 0,
  "speed": 4.5, "range": 13.5, "size": "S", "damage_key": "p3_spiral", "trigger": "phase_enter" }
```

**enemies.json**
```json
{
  "id": "mossback_boar",
  "name": "Mossback Boar",
  "rank": "normal",
  "base": { "hp": 180, "ward": 6, "contact": 25, "damage": { "burst": 15 } },
  "move_speed": 2.5,
  "radius": 0.55,
  "aggro_radius": 8,
  "leash": 16,
  "ai": {
    "type": "sequence",
    "steps": [
      { "action": "keep_range", "min": 5, "max": 7, "until": "ready" },
      { "action": "telegraph", "ticks": 12, "fx": "lane" },
      { "action": "dash", "speed": 10, "ticks": 16, "target": "locked_pos", "contact": true },
      { "action": "fire", "pattern": "boar_burst" },
      { "action": "wander", "ticks": 60 }
    ]
  }
}
```

**Boss phases** (inside `enemies.json`, `rank: "boss"`)
```json
"phases": [
  { "id": "p1", "hp_above": 0.66, "move_speed": 1.5,
    "loops": [ { "pattern": "warden_wickring", "every_ticks": 32, "offset_ticks": 0 },
               { "pattern": "warden_drip",     "every_ticks": 20, "offset_ticks": 10 } ] },
  { "id": "t1", "transition": true, "ticks": 40, "invulnerable": true,
    "on_enter": [ { "summon": "waxen_acolyte", "at": "corners", "count": 4, "loot": false } ] },
  { "id": "p2", "hp_above": 0.33, "loop_ticks": 120, "...": "..." },
  { "id": "t2", "transition": true, "ticks": 60, "invulnerable": true, "move_to": "center" },
  { "id": "p3", "hp_above": 0.0, "enrage": { "timer_start": "seal", "after_ticks": 4800, "interval_mult": 0.8 }, "...": "..." }
],
"party_scaling": "boss",
"target_rule": "living_in_arena"
```

**loot.json**
```json
{
  "tier_rows": {
    "normal": [ { "offset": -1, "w": 25 }, { "offset": 0, "w": 65 }, { "offset": 1, "w": 9 }, { "offset": 2, "w": 1 } ],
    "boss":   [ { "offset": 0, "w": 50 }, { "offset": 1, "w": 40 }, { "offset": 2, "w": 10 } ]
  },
  "slot_weights": { "weapon": 40, "armor": 35, "charm": 25 },
  "weapon_class_weights": { "own": 70, "other_each": 15 },
  "tables": {
    "wilds_normal":   { "item_chance": 0.04, "rolls": 1, "row": "normal" },
    "matron":         { "item_chance": 0.04, "rolls": 1, "row": "normal", "found_portal_chance": 0.10 },
    "tallow_warden":  { "item_chance": 1.0,  "rolls": 2, "row": "boss", "m_extra_step": 25,
                        "riftstone": { "yield_coef": 4, "deposit_coef": 5 } }
  }
}
```

**Where each check runs:**

| Check | Where |
|---|---|
| Every file parses, each schema passes the metaschema check, and each file validates against its schema | `validate-data.py` (CI `data-validate`, first step) |
| Every pattern has a `type` from the table, with that type's required fields. Done with `oneOf`/`if-then` on `type` in `patterns.schema.json`; `hazard` doesn't require `speed`, `range` or `size` | JSON Schema (`patterns.schema.json`) |
| Every `*_ticks` value is a non-negative integer; enums (`aim`, `trigger`, `size`, `rank`) are valid | JSON Schema |
| Every `pattern` reference (in AI steps, phase loops and `child`) resolves to an id in `patterns.json` | `make data-validate` script |
| Every pattern's `damage_key` resolves to a key in the `base.damage` map of **every** enemy that uses that pattern (hazards included). An unused `damage_key` on an enemy is a warning | `make data-validate` script |
| Each tier row's weights, `slot_weights` and `weapon_class_weights` (own + 2 × other_each) sum to 100 | `make data-validate` script |
| A golden fixture for each pattern (seed plus tick to positions) passes on both Go and GDScript | CI `fixtures-parity` job |

The `make data-validate` target is added by the data PR. Until then, CI skips it with a notice (`ci.yml`).

---

## 6. Out of scope for v0.1
Affixes and rarity, set items, more classes, procedural dungeon layouts, a Wilds world boss, tradeable Sigils, M above 1.5, pattern density that scales with M, and accelerating or homing bullets. Anti-cheat and anomaly-detection thresholds are deliberately not in this public repo. They live in the private ops doc (vision header). Prism and paid cosmetics are also out of scope for v0.1 (vision §5, §9; `stack.md` decision 6).

### Post-v0.1 candidates
These were cut to keep v0.1 inside vision §4.2 and §5. No numbers are committed. Each would need a vision change first.
- Pity for Wilds item drops
- Boss pity (a guaranteed high-tier roll after a dry streak)
- A daily first-clear bonus boss roll
- Sigil drop sources (from enemies or the elite)
- An elite-specific loot table and Glint multiplier

## 7. Open questions for Karyu (direction or money only)
None. Personal loot is already settled in vision §4.2, and everything else here is a tuning number that Design owns (vision §10).
