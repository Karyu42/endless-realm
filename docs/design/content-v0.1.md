# Endless Realm: Content Spec (v0.1 first playable)

Status: draft for review · Owner: Game Design · Audience: Gameplay Engineer, QA · Depends on: [`vision.md`](vision.md) (PR #1)

This spec turns `vision.md` into numbers the engineer can put straight into `data/`. `vision.md` stays the source of truth for every formula. This doc only adds base values, patterns and rules that `vision.md` leaves open (§0). If the two ever disagree, `vision.md` wins and this doc gets a fix.

All names and content are original. All numbers are starting values that Design can tune after playtests (vision §10, tuning ownership).

---

## 0. Conventions and rules this spec relies on

### 0.1 Units
- Distance in **tiles** (1.0 = one tile), speed in **tiles/s**, time written in seconds but every value is a multiple of 0.05 s, so it maps to whole **ticks at 20 Hz** (data files store ticks).
- Angles in **degrees** in data (the loader converts to radians). Godot 2D convention, as in `docs/tech/stack.md`: 0° = +X, +Y is down, positive = clockwise on screen.
- **Aimed** means the pattern's 0° offset points at the target's position at the spawn tick (no lead in v0.1). **Fixed** means an absolute angle.
- Every bullet flies in a straight line at constant speed, so positions stay closed-form. `lifetime_ticks = ceil(range / speed × 20)`.
- Bullet hit radius: **S** 0.15, **M** 0.25, **L** 0.40 tiles. Player hit radius 0.30. Each bullet hits once and is consumed, unless it is marked piercing.
- Randomness (target picks, jitter, spawn points, loot) uses the server's PCG32 with the instance seed. The client never rolls.

### 0.2 Integer rounding
- `roundHalfUp(x) = floor(x + 0.5)`. Use it wherever this doc says "round", never banker's rounding.
- **Content level:** compute with M in hundredths: `E = max(1, floor((B × M100 + 50) / 100))`. Example: B=10, M=1.25 gives E=13.
- **Off-step M:** the server rejects `OpenPortal` unless `M100` is a multiple of 5 within [50, 150].
- **XP per kill** is granted as `roundHalfUp(killXP × falloff)` into an int64.
- **Echo Dust from salvage** = `roundHalfUp(5 × g(T))`.
- **Riftstone** grants are fractional (`3 × M²`), so they use stochastic rounding: `floor(x)`, plus 1 with probability `x − floor(x)` (server PCG32). The expected value is exact, and an M=0.5 run still pays out.
- **Boss extra rolls:** `extra = max(0, (M100 − 100) / 25)` with integer division. M=1.25 gives 1, M=1.45 gives 1, M=1.50 gives 2.

### 0.3 Synced level and `attackerLevel`
With real level `Lp` in content of level `E`, the player's **synced level** is `Ls = min(Lp, E + 5)` (vision §6.1.3). `Ls` replaces `Lp` everywhere combat happens:
- Player MaxHP and Ward use `m(Ls)`. Weapon effective tier is `min(T, T*(E) + 3)` (vision §4.1).
- **`attackerLevel`** in the mitigation formula (vision §3.2) is the attacker's **synced** level. When a player hits an enemy, `attackerLevel = Ls`. When an enemy hits a player, `attackerLevel = E` (the enemy's own level).
- The level-difference factor `D` (vision §3.3) uses `Ls − E`, so it is never above `1 + 0.02 × 5 = 1.10` inside synced content.
- XP falloff and the XP cap (vision §3.4, §6.1.4) keep using the **real** `Lp`, so syncing down can't be used to farm.
- In the Wilds there is no sync (`Ls = Lp`). Each enemy's own level is `E`.

### 0.4 Party cap and per-player scaling
- **Dungeon party cap:** 6 players per instance. The 7th join is refused at the portal.
- **Enemy HP scales with player count** `n` (players inside the instance, capped at 6). For normal enemies `n` is taken when the room activates. For the boss, `n` is the number of players inside the arena when it seals:
  ```
  HP = baseHP × m(E) × (1 + k × (n − 1))      k = 0.30 normal enemies, 0.60 elites and the boss
  ```
  At 6 players that is ×2.5 for normal enemies and ×4.0 for the boss.
- Damage, Ward and bullet patterns don't scale with `n`. **Wilds** enemies don't scale with `n` either; they have open-world respawns instead.
- HP doesn't drop when someone leaves or dies. Phase thresholds (§3.4) are fractions of the scaled max HP.

### 0.5 Loot ownership
**Personal loot:** every eligible player gets their own rolls and their own loot bag. Nobody else can see or open it. Items can still change hands through trading (vision §8). Eligibility:
- **Normal and elite enemies:** you dealt ≥ 10% of the enemy's max HP, **or** you healed or warded an ally within 8 tiles of it during the fight.
- **Boss:** the vision §6.1.5 contribution check.
- Bags last 90 s in the Wilds and until the instance closes in a dungeon. Loot is unbanked until you reach the Hearth (vision §7).

### 0.6 Instance lifetimes and re-entry
- A portal entrance stays open for 60 s (Wilds drop) or 120 s (opened from the Hearth portal board).
- An instance closes 10 min after it is empty (vision §6.1.6), 3 min after the boss dies (the exit portal stays up the whole time), or 30 min after creation, whichever comes first.
- **Re-entry (Standard):** after respawning in the Hearth, the portal board lists any live instance you were in. You can rejoin until the boss arena seals. After that, rejoining is blocked until the boss dies or resets.
- **Boss reset:** if every player in the arena is dead or has left for 10 s, the arena unseals and the boss heals to full and returns to phase 1.
- **Hardcore:** a Fallen character never re-enters. Hardcore instances are hardcore-only (vision §7).

---

## 1. Classes

Stats come from vision §2. Stride and Tempo are fixed, with at most +10% from gear (D6). Focus is 100 max with 5/s regen for every class. Ability cooldowns and Focus costs are checked together: you need both.

**Fire timing:** each tick while fire is held, add `Tempo × (1 + tempoBonus) / 20` to a per-player accumulator. Fire one volley each time it reaches ≥ 1, then subtract 1. Reset it to `min(acc, 1)` when fire is released, so tapping never banks shots.

### 1.1 Thornguard (close-range tank)
| Stat | Value |
|---|---|
| Base HP / Ward | 200 / 12 (× m(Ls)) |
| Stride | 4.5 tiles/s |
| Tempo | 2.0 volleys/s |
| Hit radius | 0.30 |

**Starter weapon: Bramble Scattergun (T0)**
- 5 pellets per volley, 12 damage each at T0 (`12 × g(T)`).
- Spread 40° in total: pellets at −20°, −10°, 0°, +10°, +20° from aim.
- Speed 10 tiles/s, range 4 tiles (8 ticks), size S, no pierce.
- Point-blank volley at T0: 60 damage.

**Ability: Thorn Ward** · 40 Focus · 8 s cooldown
- For 3 s (60 ticks), damage taken is ×0.50, applied after Ward mitigation. Self only.
- Stride is unchanged and you can keep firing.
- Counts as support activity for loot eligibility while an ally is within 8 tiles.

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

**Ability: Kindle Pulse** · 60 Focus · 6 s cooldown
- Instantly heals every ally within 4 tiles, including yourself, for 25% of each target's max HP. It can't overheal.
- 0.25 s cast lock (5 ticks): you can't fire during it, but you can move.
- Healing counts as support activity (loot eligibility and the vision §6.1.5 boss check).

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

**Ability: Slipstep** · 30 Focus · 3 s cooldown
- Blink 4 tiles in your move direction, or your aim direction when you are standing still.
- If a wall is in the way, you stop at the last valid position along the line (sample every 0.25 tiles).
- 0.30 s (6 ticks) of no damage, starting on the blink tick.
- You can't blink across closed doors or the sealed boss arena wall.

### 1.4 DPS reference (T0, every shot hitting, before Ward)
| Class | Per volley | Volleys/s | Sustained DPS |
|---|---|---|---|
| Thornguard | 60 (point blank) | 2.0 | 120 |
| Gleamwright | 30 (×3 if it pierces 3 targets) | 2.5 | 75 single target |
| Driftrunner | 28 | 3.5 | 98 |

Enemy HP below is tuned for about 65 effective solo DPS: about a 2 s TTK for a normal enemy and about 100 s for the boss solo.

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
- **Mirebell Matron:** there is one alive in ring 4 at a time. She respawns 4 min after she dies, at one of 4 fixed lairs, and the server announces it in the Hearth: "The Matron's bells ring in the Hollow Heart."

### 2.2 Stat table
`baseHP`, `baseWard` and the damage values are what goes into the formulas (vision §3.2): `HP = baseHP × m(E)`, `Damage = baseDmg × m(E)`, `Ward = baseWard × m(E)`. The "HP at band" column shows the result at the lowest and highest level of each band.

| Enemy | Band | baseHP | HP at band (lo–hi) | baseWard | Contact dmg | Projectile dmg | Move speed | Radius | XP / Glint at band lo |
|---|---|---|---|---|---|---|---|---|---|
| Burrmite | 1–5 | 60 | 60–72 | 0 | 8 | 10 | 3.5 | 0.35 | 10 / 1 |
| Driftcap Spore | 1–5 | 90 | 90–108 | 2 | 0 | 12 | 0 (static) | 0.50 | 10 / 1 |
| Mossback Boar | 6–10 | 180 | 225–261 | 6 | 25 | 15 | 2.5 (10 charging) | 0.55 | 13 / 2 |
| Reedling Slinger | 6–10 | 100 | 125–145 | 3 | 6 | 14 | 3.0 | 0.40 | 13 / 2 |
| Cinderwisp | 11–15 | 110 | 165–187 | 4 | 10 | 10 | 5.0 | 0.35 | 15 / 2 |
| Gloomlantern Sentinel | 11–20 | 260 | 390–507 | 10 | 15 | 18 ring / 20 fan | 1.2 | 0.60 | 15 / 2 |
| Thornwing Harrier | 16–20 | 160 | 280–312 | 8 | 20 | 16 | 4.0 (12 diving) | 0.45 | 18 / 2 |
| **Mirebell Matron** (elite) | 16–20 | 1400 | 2450–2730 | 15 | 30 | 16 spiral / 22 fan | 1.5 | 0.90 | 88 / 10 |

- **XP:** `10 × m(E)` for normal enemies, ×5 for elites (vision §3.4), rounded.
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
- **Portal drop:** on death, a Hollowmere Vault portal appears where she died (§3.5).

---

## 3. Dungeon: the Hollowmere Vault

Base level B = 10 (vision §6). Content level `E = max(1, roundHalfUp(max(10, opener Lp) × M))`. For a Wilds drop, see §3.5.

### 3.1 Layout
The vault is a linear crypt of sunken candle halls: 6 rooms joined by 3-tile-wide corridors. The layout is hand-authored, not procedural, in v0.1.

```
[1 Antechamber] → [2 Drip Hall] → [3 Wick Kennels] → [4 Censer Gallery] → [5 Wax Chapel] → [6 Warden's Sanctum (boss)]
     12×12            18×14           16×16              20×12               18×18                 21×21, 4 pillars
```

- **Room activation:** a room's enemies wake when the first player enters it. Doors never lock in rooms 1–5, and players can retreat.
- **Room 6** seals 3 s after the first player crosses its threshold, after a "the doors are closing" warning. It stays sealed until the boss dies or resets (§0.6).
- **Clear rule:** room 6's door opens once rooms 2–5 are all cleared (every enemy dead). This stops players skipping straight to the boss.
- **Exit:** when the boss dies, the exit portal to the Hearth spawns in the center of room 6, together with the loot bags.

### 3.2 Vault enemies
These enemies spawn at the instance's level E and use the `n` scaling from §0.4.

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
| baseHP | 6500 (E=10 solo: 9,425 · E=10 with 6 players: 37,700) |
| baseWard | 20 |
| Contact damage | 40 |
| Projectile damage | P1 22 / 28 · P2 20 / 30, pools 15 per 0.5 s · P3 22 / 26 |
| Move | 1.5 tiles/s (P1), 1.0 (P2), 0 (P3: anchored at the center) |
| Radius | 1.20 |
| XP | `killXP × 50` = 725 at E=10 (vision §3.4) |
| Glint | `ceil(m(E)) × 30` = 60 at E=10 (vision §5) |

**Targeting:** aimed attacks pick a random eligible player in the arena (PCG32). They never pick the same player more than twice in a row when someone else is available.

### 3.4 Boss phases
The thresholds are fractions of the scaled max HP. A transition happens on the first tick HP is at or below the threshold. During a transition the boss takes no damage, and bullets already in flight continue.

**Phase 1, "Steady Flame" (100% to 66%)**: the boss walks slowly toward the arena center and drifts around it.
- `warden_wickring`: 16 bullets in a ring (22.5° apart), speed 5, range 12, size M, 22 damage, every 1.6 s. Each ring is rotated +11.25° from the last.
- `warden_drip`: a fan of 3 bullets with 20° total spread, aimed, speed 8, range 12, size L, 28 damage. It fires every 1.0 s, offset 0.5 s from the ring.

**Transition at 66%, "Melt"** (2.0 s): the boss can't be damaged and its crown flame turns orange. It spawns 4 Waxen Acolytes, one in each corner. Their HP uses the arena's `n`, and they drop no loot.

**Phase 2, "Guttering" (66% to 33%)**: a 6.0 s loop.
- `warden_spiral` (0–4 s): a 4-arm spiral. Arms are 90° apart and emit 1 bullet each every 0.1 s, rotating +9° per emit. Speed 4, range 12, size S, 20 damage.
- `warden_pools`: at the start of each loop, one telegraphed wax pool under each of up to 3 random players. Each pool has radius 1.5 tiles, a 1.0 s telegraph, and lasts 4.0 s. A player standing in it takes 15 damage every 0.5 s and moves at −30% Stride. This is a debuff, not a stat change, so the D6 cap doesn't apply.
- `warden_lunge_fan` (4–6 s): 2 fans 1.0 s apart. Each fan is 5 bullets with 50° total spread, aimed, speed 9, range 13.5, size L, 30 damage.

**Transition at 33%, "Last Wick"** (3.0 s): the boss can't be damaged. It walks to the arena center and anchors there, and its crown flame turns white.

**Phase 3, "Last Flame" (33% to 0%)**
- `warden_twinspiral`: two 3-arm spirals running at the same time. Arms in each set are 120° apart. Set A rotates +8° per emit and set B −8°. Each arm emits every 0.15 s. Speed 4.5, range 13.5, size S, 22 damage. This runs continuously.
- `warden_gapring`: every 3.0 s, a 24-bullet ring (15° apart) with 4 consecutive bullets left out. The gap's start index is a PCG32 roll of 0–23, which leaves one safe lane. Speed 6, range 12, size M, 26 damage.
- **Soft enrage:** 240 s after the arena seals, every attack interval in P3 is ×0.80. This depends on time only, not on M (vision §6: M doesn't change patterns).

**Death:** loot (§4.4), XP, Glint and Riftstone go to every eligible player. The exit portal spawns. Pools and all live enemy bullets are cleared.

### 3.5 How you get in: portal drops and open cost
There are two ways in.

**A. Wilds drop (free, M = 1.00).**
- When the Mirebell Matron dies, a Vault portal appears at her body.
- `B = max(10, Matron's E)`, so `E = B` (16–20), with `M = 1.00` locked. Nobody is the opener, and nothing is paid.
- Anyone who passes the vision §6.1.2 join floor can enter until the entrance closes (60 s) or the party cap of 6 is reached.

**B. Vault Sigil (chosen M) from the Hearth portal board.**
- A **Vault Sigil** is a character-bound consumable that stacks to 10. It is not tradeable in v0.1, which keeps it out of NTV.
- **Sources:**
  - 1.5% per eligible kill of a ring-3 or ring-4 normal enemy, rolled separately from the item roll.
  - 1 per eligible player from the Matron, at 50%.
  - The Hearth vendor sells it for `150 × m(Lp)` Glint. This is a new Glint sink, and it means you can never be locked out.
- **Opening:** use 1 Sigil and choose M from 0.50 to 1.50 in steps of 0.05. `B = max(10, opener Lp)`. If M > 1.00, you also pay `ceil(5 × M²)` Riftstone (vision §5). Every rule in vision §6.1 applies: one open portal per player, a 60 s open cooldown, and the label shows E and M.
- The Sigil and the Riftstone are spent when the instance is created. They are refunded only if instance creation fails on the server.

---

## 4. Loot

### 4.1 Item slots and stat lines (v0.1)
Each item has one base type, a tier T, and a server-minted `item_uid` (vision §8.2). There are no affixes or rarity in v0.1.

| Slot | Base types | Stat line(s) |
|---|---|---|
| Weapon | Bramble Scattergun (Thornguard), Lumen Rod (Gleamwright), Gale Sling (Driftrunner) | Damage per projectile = class base × g(T): 12 / 30 / 14 |
| Armor | Wardweave (all classes) | +HP `30 × g(T)`, +Ward `4 × g(T)`, both rounded |
| Charm | Ember Charm (all classes) | Exactly one line, rolled when it drops (table below) |

| Charm line | Weight | Value |
|---|---|---|
| +HP | 30 | `roundHalfUp(20 × g(T))` |
| +Ward | 30 | `roundHalfUp(3 × g(T))` |
| +Focus regen | 20 | +1 /s (flat) |
| +Stride | 10 | 2–10% (uniform, 1% steps). It doesn't scale with T. |
| +Tempo | 10 | 2–10% (same as Stride) |

- Since there is only one charm slot, the +10% cap on Stride and Tempo (D6) holds automatically. The server still clamps the total at +10%.
- Display name: `<Base> T<n>`, for example "Lumen Rod T4".
- Bag color shows tier compared with T* of the content it dropped in: brown for ≤ T*, teal for T*+1, gold for T*+2 or higher.

### 4.2 Drop chances
| Source | Item chance | Items | Tier row (vision §4.2) | Other drops |
|---|---|---|---|---|
| Wilds normal enemy | 4% | 1 | Normal | Sigil 1.5% (rings 3–4 only) |
| Vault normal enemy | 4% | 1 | Normal | — |
| Mirebell Matron (elite) | 60% | 1 | Boss | Sigil 50%, plus the portal (§3.5) |
| Tallow Warden (boss) | 100% | 2 + `extra` (§0.2) + bonus rolls (§4.5) | Boss | Riftstone (§4.3) |
| Boss phase adds / Matron summons | 0% | — | — | — |

- **Slot weights** for every item roll: weapon 40, armor 35, charm 25.
- **Weapon class:** 70% the looter's class, and 15% for each of the other two (that 30% feeds trading).

### 4.3 Tier roll against content level and M
1. Take the content level `E`:
   - Wilds: the enemy's level.
   - Vault: the instance's `E`, which already includes M (vision §6).
   - Synced players still roll against `E`, never against their own level.
2. `T* = floor(E / 5)`.
3. Roll the offset from the vision §4.2 row: Normal is −1/0/+1/+2 at 25/65/9/1%, and Boss is 0/+1/+2 at 50/40/10%. `T = max(0, T* + offset)`.
4. When the item is equipped in content of level E′, its effective tier is `min(T, T*(E′) + 3)` (vision §4.1).

M only affects loot through `E` (and so T*), plus the boss `extra` rolls. Example tiers for a Vault run opened by a level-10 player:

| M | E | T* | Boss item rolls | Normal row range | Boss row range |
|---|---|---|---|---|---|
| 0.50 | 5 | T1 | 2 | T0–T3 | T1–T3 |
| 1.00 | 10 | T2 | 2 | T1–T4 | T2–T4 |
| 1.25 | 13 | T2 | 3 | T1–T4 | T2–T4 |
| 1.50 | 15 | T3 | 4 | T2–T5 | T3–T5 |

### 4.4 Echo Dust and Riftstone yields
**Echo Dust:** it only comes from salvage (vision §5), at `roundHalfUp(5 × g(T))`. Tier-up from T to T+1 costs `20 × g(T+1)` Dust and `100 × g(T+1)` Glint.

| T | 0 | 1 | 2 | 3 | 4 | 5 | 20 |
|---|---|---|---|---|---|---|---|
| Salvage yield (Dust) | 5 | 6 | 8 | 9 | 10 | 11 | 30 |
| Tier-up into T, Dust / Glint | — | 25 / 125 | 30 / 150 | 35 / 175 | 40 / 200 | 45 / 225 | 120 / 600 |

**Riftstone:** each eligible player gets `3 × M²` from the Warden, with stochastic rounding (§0.2). Nothing else drops Riftstone in v0.1.

| M | 0.50 | 0.75 | 1.00 | 1.25 | 1.50 |
|---|---|---|---|---|---|
| Yield per player (expected) | 0.75 | 1.69 | 3.00 | 4.69 | 6.75 |
| Opener's cost | 0 | 0 | 0 | 8 | 12 |
| Net for a solo opener | +0.75 | +1.69 | +3.00 | −3.31 | −5.25 |
| Net for the whole party at 4 players | +3.0 | +6.75 | +12.0 | +10.75 | +15.0 |

**Intended (answers the QA question):** solo runs above M=1 are meant to cost Riftstone. Riftstone is earned at M ≤ 1 and spent to buy the extra boss rolls and higher T* that come with M > 1. For a party it is positive from 2 players up (M=1.5: 13.5 out against 12 in), which rewards co-op, the reason the slice exists. If playtests show solo players feel locked out of M > 1, the tuning knob is the cost coefficient (5), not a new source.

### 4.5 Pity and bonus rolls
All counters are per character, per mode, and stored on the server.

- **Wilds pity:**
  - Count eligible normal kills since your last item drop. Only kills with `E ≥ Lp − 5` count.
  - At 75, the next eligible kill always drops one item (Normal row).
  - The counter resets on any item drop. The chance of hitting pity without it is about 4.7%.
- **Warden's Favor (boss pity):**
  - Count eligible Warden kills since your last item of tier ≥ T*+2 from the Warden.
  - At 8, the first item roll of your next kill is forced to T*+2.
  - The counter resets when that happens.
- **Daily Hearthfire roll:** your first eligible Warden kill each UTC day gives +1 boss item roll (Boss row). It stacks with `extra`. Day boundaries are UTC because the server runs on UTC; the client shows the reset in local time.
- **M bonus:** `extra = max(0, (M100 − 100) / 25)` boss item rolls (vision §6).

Example: a party member at M=1.50 on their first clear of the day rolls 2 + 2 + 1 = **5** items.

---

## 5. Data format

JSON under `data/`, with a JSON Schema next to each file, as `docs/tech/stack.md` recommends. Both the Go server and the Godot client load the same files. Times are stored in **ticks**, angles in **degrees**, and distances in **tiles**. Formulas stay in code and read their coefficients from `scaling.json`.

```
data/
  scaling.json          # m(L), g(T), XP, D clamp, party k, sync offset (+5)
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
"party_hp_k": 0.60
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
    "matron":         { "item_chance": 0.60, "rolls": 1, "row": "boss",   "extra": [ { "item": "vault_sigil", "chance": 0.50 } ] },
    "tallow_warden":  { "item_chance": 1.0,  "rolls": 2, "row": "boss", "m_extra_step": 25, "daily_bonus_rolls": 1,
                        "riftstone": { "coef": 3, "exp": 2, "rounding": "stochastic" } }
  },
  "pity": {
    "wilds": { "threshold": 75, "min_level_offset": -5 },
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
Affixes and rarity, set items, more classes, procedural dungeon layouts, a Wilds world boss, tradeable Sigils, M above 1.5, pattern density that scales with M, and accelerating or homing bullets. Anti-cheat detection thresholds are deliberately not in this repo. They belong in the private ops doc.

## 7. Open questions for Karyu (direction or money only)
1. **Personal loot or shared loot?** This spec uses personal loot: every eligible player rolls their own bag, and nobody else can see it (§0.5). It changes the co-op feel and the trading economy, so it is a direction call.
   *Recommendation:* keep personal loot. It removes loot fights and ninja-looting in a game with full trading, makes the per-player boss rewards in vision §6 work cleanly, and trading still lets players hand items to friends.

Everything else here is a tuning number and is Design's call, recorded above.
