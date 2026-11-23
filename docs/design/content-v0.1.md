# Endless Realm: Content Spec (v0.1 first playable)

Status: draft for review · Owner: Game Design · Audience: Gameplay Engineer, QA · Depends on: [`vision.md`](vision.md) (PR #1)

This spec turns `vision.md` into numbers the engineer can put straight into `data/`. `vision.md` stays the source of truth for every formula. This doc only adds base values, patterns and the few rules `vision.md` leaves open. Where the two overlap, it cites a vision section instead of restating the rule. If they ever disagree, `vision.md` wins and this doc gets a fix. Engine, netcode and persistence follow [`docs/tech/stack.md`](../tech/stack.md): Godot 4.7.2 client, Go server, Postgres, 20 Hz ticks.

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
| Riftstone **deposit** `ceil(5 × M²)` for M > 1, refunded in full when the boss dies, lost only on a failed run | vision §6 |
| Effective level `Le = min(Lp, E + 5)` in portals, and which formulas use `Le` and which use the real `Lp` | vision §3.2a |
| `attackerLevel` in mitigation (`E` when an enemy hits; weapon gear level `W = max(1, 5 × T_eff)` when a player hits), rounding and min 1 | vision §3.2 |
| `D` factor, XP crediting (tenths of XP, under-level cap at `Le + 10`, over-level penalty) | vision §3.3, §3.4 |
| Effective tier `T_eff = min(T, T*(E) + 3)` | vision §4.1 |
| Personal loot and normal-kill eligibility (damaged it, or within 10 tiles when it died) | vision §4.2 |
| Party cap of **8**, per-player HP scaling, boss eligibility, instance lifetimes, re-entry after death | vision §6.1 |
| Pending loot and banking, Standard death order, hardcore separation, disconnect linger | vision §7 |
| Season track and Sparks (no Prism in v0.1) | vision §9 |

All examples below use these rules. With the vision §6.1 scaling, an 8-player party gives normal enemies ×5.2 HP and the boss ×6.25.

### 0.3 Rules this spec adds
These fill gaps in `vision.md` and don't change any of its formulas:
- **When n is counted:** dungeon enemies spawn when their room activates (§3.1), so the vision §6.1 "n at spawn" is n at room activation. Boss adds use the n of the boss fight.
- **Wilds enemies don't scale with n.** The Wilds aren't an instance and have open-world respawns instead.
- **Boss arena seal:** room 6 seals 3 s after the fight starts (the boss first takes damage, vision §6.1). Anyone who enters during those 3 s counts as a mid-fight join (vision §6.1: HP scales up and keeps its percentage). After the seal, nobody can enter until the boss dies or resets.
- **Boss reset:** if every player in the arena is dead or has left for 10 s, the arena unseals and the boss heals to full and returns to phase 1. The deposit isn't forfeited by a reset, only by the instance closing without a kill (vision §6.1).
- **Wilds drops:** personal drops in the Wilds despawn after 90 s. In a dungeon they last as long as the instance (location `GROUND`, vision §8.2).

---

## 1. Classes

Stats, Focus (100, 5/s regen), costs, cooldowns and the ability rules are in vision §2. Stride and Tempo are fixed, with at most +10% from gear (D6). This section adds weapon patterns and the numbers vision leaves open. HP and Ward scale with `m(Le)` (vision §3.2a).

**Fire timing:** each tick while fire is held, add `Tempo × (1 + tempoBonus) / 20` to a per-player accumulator. Fire one volley each time it reaches ≥ 1, then subtract 1. Reset it to `min(acc, 1)` when fire is released, so tapping never banks shots.

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

Enemy HP below is tuned for about 65 effective solo DPS: about a 2 s TTK for a normal enemy and about 100 s for the boss solo.

With vision §6.1 scaling, an 8-player boss has ×6.25 HP against about ×8 DPS, so the fight is about 80 s.

### 1.5 Controls assumption
- **Desktop:** WASD to move, mouse to aim, hold the left button to fire, Space or the right button for the ability, E to interact or loot, 1–8 for inventory slots, Enter for chat.
- **Android:** twin-stick (left stick moves, right stick aims and fires while held), an ability button above the right stick, a tap-to-loot prompt, and an optional auto-fire toggle.
- **Input frame:** the tech stack's `(move, aim, fire_held, seq)` plus one `ability_pressed` bit and an optional `interact_target_id`. The ability fires on the tick the server receives it, if Focus and the cooldown allow.

---

## 2. Wilds enemies

### 2.1 Layout of the Wilds
- The Wilds are a circle of radius 120 tiles. The Hearth gate sits on the south edge.
- Enemy level depends on distance `r` from the center: `E = clamp(20 − floor(r / 6), 1, 20)`.

| Ring | Name | r (tiles) | Levels | Live population | Roster (spawn weight) |
|---|---|---|---|---|---|
| 1 | Saltreach Verge | 90–120 | 1–5 | 60 | Burrmite 60 (packs of 3), Driftcap Spore 40 |
| 2 | Fernmoor | 60–90 | 6–10 | 50 | Mossback Boar 50, Reedling Slinger 50 (pairs) |
| 3 | Ashen Glade | 30–60 | 11–15 | 40 | Cinderwisp 55 (pairs), Gloomlantern Sentinel 45 |
| 4 | Hollow Heart | 0–30 | 16–20 | 30 + 1 elite | Thornwing Harrier 70, Gloomlantern Sentinel 30, Mirebell Matron (elite) |

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
| **Mirebell Matron** (elite) | 16–20 | 1400 | 2450–2730 | 15 | 30 | 16 spiral / 22 fan | 1.5 | 0.90 | 87.5 / 10 |

- **XP:** `killXP(E)` for normal enemies, ×5 for elites, credited in tenths as in vision §3.4.
- **Glint:** `ceil(m(E))` for normal enemies. For elites it is `5 × ceil(m(E))`. Vision §5 only defines the normal and boss multipliers, so the elite multiplier is new here; it mirrors the XP ×5.
- **Contact damage** is applied at most once per 0.5 s per enemy–player pair.

### 2.3 Behaviors and patterns
"Every X s" is measured from the end of the previous attack, and the first attack comes X s after aggro. Aggro radius is 8 tiles unless stated otherwise. The target is the nearest player in aggro range, re-picked every 1 s.

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
- It alternates two attacks with a 1.25 s gap between them:
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

---

## 3. Dungeon: the Hollowmere Vault

Base level 10. B, E and M are as in vision §6. Party cap, scaling, lifetimes and re-entry are as in vision §6.1.

### 3.1 Layout
The vault is a linear crypt of sunken candle halls: 6 rooms joined by 3-tile-wide corridors. The layout is hand-authored, not procedural, in v0.1.

```
[1 Antechamber] → [2 Drip Hall] → [3 Wick Kennels] → [4 Censer Gallery] → [5 Wax Chapel] → [6 Warden's Sanctum (boss)]
     12×12            18×14           16×16              20×12               18×18                 21×21, 4 pillars
```

- **Room activation:** a room's enemies spawn and wake when the first player enters it, and that is when n is counted (§0.3). Doors never lock in rooms 1–5, and players can retreat.
- **Room 6** seals as described in §0.3, after a "the doors are closing" warning.
- **Clear rule:** room 6's door opens once rooms 2–5 are all cleared (every enemy dead). This stops players skipping straight to the boss.
- **Exit:** when the boss dies, the exit portal to the Hearth spawns in the center of room 6, together with the loot bags.

### 3.2 Vault enemies
These enemies spawn at the instance's level E and use the normal-enemy `n` scaling from vision §6.1.

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
| baseHP | 4500 (E=10 solo: 6,525 · E=10 with 8 players: 40,781) |
| baseWard | 20 |
| Contact damage | 40 |
| Projectile damage | P1 22 / 28 · P2 20 / 30, pools 15 per 0.5 s · P3 22 / 26 |
| Move | 1.5 tiles/s (P1), 1.0 (P2), 0 (P3: anchored at the center) |
| Radius | 1.20 |
| XP | `killXP × 50` = 725.0 at E=10 (vision §3.4) |
| Glint | `ceil(m(E)) × 30` = 60 at E=10 (vision §5) |

**Targeting:** aimed attacks pick a random eligible player in the arena (PCG32). They never pick the same player more than twice in a row when someone else is available.

### 3.4 Boss phases
The thresholds are fractions of the scaled max HP. A transition happens on the first tick HP is at or below the threshold. During a transition the boss takes no damage, and bullets already in flight continue.

**Phase 1, "Steady Flame" (100% to 66%)**: the boss walks slowly toward the arena center and drifts around it.
- `warden_wickring`: 16 bullets in a ring (22.5° apart), speed 5, range 12, size M, 22 damage, every 1.6 s. Each ring is rotated +11.25° from the last.
- `warden_drip`: a fan of 3 bullets with 20° total spread, aimed, speed 8, range 12, size L, 28 damage. It fires every 1.0 s, offset 0.5 s from the ring.

**Transition at 66%, "Melt"** (2.0 s): the boss can't be damaged and its crown flame turns orange. It spawns 4 Waxen Acolytes, one in each corner. Their HP uses the normal-enemy scaling with the boss fight's `n`, and they drop no loot.

**Phase 2, "Guttering" (66% to 33%)**: a 6.0 s loop.
- `warden_spiral` (0–4 s): a 4-arm spiral. Arms are 90° apart and emit 1 bullet each every 0.1 s, rotating +9° per emit. Speed 4, range 12, size S, 20 damage.
- `warden_pools`: at the start of each loop, one telegraphed wax pool under each of up to 3 random players. Each pool has radius 1.5 tiles, a 1.0 s telegraph, and lasts 4.0 s. A player standing in it takes 15 damage every 0.5 s and moves at −30% Stride. This is a debuff, not a stat change, so the D6 cap doesn't apply.
- `warden_lunge_fan` (4–6 s): 2 fans 1.0 s apart. Each fan is 5 bullets with 50° total spread, aimed, speed 9, range 13.5, size L, 30 damage.

**Transition at 33%, "Last Wick"** (3.0 s): the boss can't be damaged. It walks to the arena center and anchors there, and its crown flame turns white.

**Phase 3, "Last Flame" (33% to 0%)**
- `warden_twinspiral`: two 3-arm spirals running at the same time. Arms in each set are 120° apart. Set A rotates +8° per emit and set B −8°. Each arm emits every 0.15 s. Speed 4.5, range 13.5, size S, 22 damage. This runs continuously.
- `warden_gapring`: every 3.0 s, a 24-bullet ring (15° apart) with 4 consecutive bullets left out. The gap's start index is a PCG32 roll of 0–23, which leaves one safe lane. Speed 6, range 12, size M, 26 damage.
- **Soft enrage:** 240 s after the arena seals, every attack interval in P3 is ×0.80. This depends on time only, not on M (vision §6: M doesn't change patterns).

**Death:** loot (§4.2), XP, Glint and Riftstone go to every eligible player (vision §6.1). The deposit is refunded (vision §6). The exit portal spawns, and pools and all live enemy bullets are cleared.

### 3.5 How you get in: portal drops and open cost
There are two ways in.

**A. Found portal (Wilds, free, M = 1.00).**
- An elite (in v0.1, the Mirebell Matron) has a 10% chance to leave a Vault portal when it dies (vision §6).
- It is M = 1.00 with no deposit and no opener. B is the higher of 10 and the Matron's level, so E is 16–20.
- Lifetimes, the join floor and the party cap are as in vision §6.1.

**B. Opened portal (Hearth portal board, chosen M).**
- The opener picks M under the vision §6 rules and pays the vision §6 Riftstone **deposit** when M > 1.00. It is refunded on a boss kill and lost if the instance closes without one.
- **Vault Sigil (added by this spec):** opening also uses 1 Vault Sigil. It is a character-bound consumable that stacks to 10 and isn't tradeable in v0.1, so it stays out of NTV. It paces opened runs now that the deposit makes them free on success.
- **Sigil sources:**
  - 1.5% per eligible kill of a ring-3 or ring-4 normal enemy, rolled separately from the item roll.
  - 50% per eligible player from the Matron.
  - The Hearth vendor sells it for `150 × m(Lp)` Glint. This is a new Glint sink, and it means you can never be locked out.
- The Sigil is spent when the instance is created. It is refunded only if instance creation fails on the server.

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
| Wilds normal enemy | 4% | 1 | Normal | Sigil 1.5% (rings 3–4 only) |
| Vault normal enemy | 4% | 1 | Normal | — |
| Mirebell Matron (elite) | 60% | 1 | Boss | Sigil 50%, found portal 10% (§3.5) |
| Tallow Warden (boss) | 100% | 2 + extra rolls (vision §6) + daily roll (§4.5) | Boss | Riftstone (§4.4) |
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

**Riftstone:** the Warden grants `round(4 × M²)` per eligible player, and the deposit works as in vision §6. Nothing else drops Riftstone in v0.1. This table only illustrates those formulas:

| M | 0.50 | 0.75 | 1.00 | 1.25 | 1.50 |
|---|---|---|---|---|---|
| Yield per eligible player | 1 | 2 | 4 | 6 | 9 |
| Deposit (refunded on a boss kill) | 0 | 0 | 0 | 8 | 12 |
| Net for a solo clear | +1 | +2 | +4 | +6 | +9 |

Riftstone sinks (forfeited deposits, stash pages, charm re-rolls) are listed in vision §5.

### 4.5 Pity and bonus rolls
All counters are per character and stored on the server. Hardcore characters keep their own, since modes never mix (vision §7.3).

- **Wilds pity:**
  - Count eligible normal kills since your last item drop. Only kills with `E ≥ Le − 5` count, the same rule as Sparks (vision §9).
  - At 75, the next eligible kill always drops one item (Normal row).
  - The counter resets on any item drop. The chance of hitting pity without it is about 4.7%.
- **Warden's Favor (boss pity):**
  - Count eligible Warden kills since your last item of tier ≥ T*+2 from the Warden.
  - At 8, the first item roll of your next kill is forced to T*+2.
  - The counter resets when that happens.
- **Daily Hearthfire roll:** your first eligible Warden kill each UTC day gives +1 boss item roll (Boss row). It stacks with the vision §6 extra rolls. Day boundaries are UTC because the server runs on UTC; the client shows the reset in local time.
- **M bonus:** the vision §6 extra boss rolls.

Example: a party member at M=1.50 on their first clear of the day rolls 2 + 2 + 1 = **5** items.

---

## 5. Data format

JSON under `data/`, with a JSON Schema next to each file, as `docs/tech/stack.md` recommends. Both the Go server and the Godot client load the same files. Times are stored in **ticks**, angles in **degrees**, and distances in **tiles**. Formulas stay in code and read their coefficients from `scaling.json`.

```
data/
  scaling.json          # coefficients for vision formulas: m, g, XP, D, party scaling (0.6 / 0.75, cap 8), sync +5, Riftstone 4/5
  classes.json          # stats, weapon_id, ability_id
  weapons.json
  abilities.json
  patterns.json         # every bullet pattern by id
  enemies.json          # stats + AI + pattern refs
  dungeons/hollowmere_vault.json
  loot.json             # tier rows, drop tables, slot weights, pity
  wilds.json            # rings, populations, respawn
  schema/*.schema.json
```

**patterns.json** (one entry; the pattern types are `ring`, `fan`, `spiral`, `burst`, `line_drop`)
```json
{
  "id": "warden_wickring",
  "type": "ring",
  "count": 16,
  "start_angle_deg": 0,
  "aim": "fixed",
  "rotate_per_fire_deg": 11.25,
  "speed": 5.0,
  "range": 12.0,
  "size": "M",
  "damage_key": "p1_ring",
  "skip": null
}
```
```json
{ "id": "warden_twinspiral_a", "type": "spiral", "arms": 3, "emit_interval_ticks": 3,
  "rotate_per_emit_deg": 8, "duration_ticks": 0, "speed": 4.5, "range": 13.5, "size": "S",
  "damage_key": "p3_spiral" }
```
`duration_ticks: 0` means the pattern runs until the phase ends. `skip` is used by `warden_gapring`: `{"consecutive": 4, "start": "rng"}`.

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
  { "id": "p3", "hp_above": 0.0, "enrage": { "after_ticks": 4800, "interval_mult": 0.8 }, "...": "..." }
],
"party_scaling": "boss"
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
    "wilds_normal":   { "item_chance": 0.04, "rolls": 1, "row": "normal", "extra": [ { "item": "vault_sigil", "chance": 0.015, "rings": [3, 4] } ] },
    "matron":         { "item_chance": 0.60, "rolls": 1, "row": "boss",   "extra": [ { "item": "vault_sigil", "chance": 0.50 } ], "found_portal_chance": 0.10 },
    "tallow_warden":  { "item_chance": 1.0,  "rolls": 2, "row": "boss", "m_extra_step": 25, "daily_bonus_rolls": 1,
                        "riftstone": { "yield_coef": 4, "deposit_coef": 5 } }
  },
  "pity": {
    "wilds": { "threshold": 75, "min_level_offset_vs_le": -5 },
    "warden_favor": { "threshold": 8, "forced_offset": 2 }
  }
}
```

**CI checks worth adding:**
- The schema validates.
- Every `pattern` reference resolves.
- Every `*_ticks` value is an integer.
- Each tier row's weights sum to 100.
- A golden fixture for each pattern (seed plus tick to positions) passes on both Go and GDScript (tech stack).

---

## 6. Out of scope for v0.1
Affixes and rarity, set items, more classes, procedural dungeon layouts, a Wilds world boss, tradeable Sigils, M above 1.5, pattern density that scales with M, and accelerating or homing bullets. Anti-cheat and anomaly-detection thresholds are deliberately not in this public repo. They live in the private ops doc (vision header). Prism and paid cosmetics are also out of scope for v0.1 (vision §5, §9; `stack.md` decision 6).

## 7. Open questions for Karyu (direction or money only)
None. Personal loot is already settled in vision §4.2, and everything else here is a tuning number that Design owns (vision §10).
