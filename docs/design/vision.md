# Endless Realm: Design Vision (v0.1)

Status: draft for review · Owner: Game Design · Scope: first playable slice

Endless Realm is a co-op, top-down bullet-hell MMO. It has no level cap and gear tiers that never stop. Everything except cosmetics can be earned in game, so there is no pay-to-win. Every name, asset and line of text is original. Nothing is taken from any existing game.

All formulas are the source of truth. Tables only illustrate them. All numbers are starting values for tuning. Put them in config, not in code.

Legend: **[v0.1]** is in the first playable slice. **[Later]** is a later-phase idea, written down so v0.1 doesn't block it.

---

## 1. Core loop

1. **[v0.1]** Spawn in **the Hearth**, a safe hub with a vendor, a stash and a portal board.
2. Step into **the Wilds**, a shared open zone in rings. Enemy level rises from the edge (level 1) toward the center (top ring = base level 20 in v0.1).
3. Dodge bullet patterns, kill enemies, and earn XP, Glint and gear drops.
4. Find or open a **portal** to a dungeon instance (v0.1 has one dungeon, **the Hollowmere Vault**, with one boss, **the Tallow Warden**). The opener sets the level multiplier (§5).
5. Clear the dungeon for boss loot and Riftstone, then go back to the Hearth.
6. Salvage, tier up and buy gear. Push to a higher level, ring or multiplier and repeat.

Why: one short session loop (Wilds → portal → boss → Hearth, about 10–15 min) shows every system in the slice once, and the endless scaling lets the same loop keep going forever.

## 2. Starting classes [v0.1]

Each class has one weapon type and one ability that uses **Focus**. Movement speed and fire rate are class identity. They do not scale with level (§3.2).

| Class | Role | Weapon | Ability (Focus cost) | Base HP | Base Ward | Stride (tiles/s) | Tempo (shots/s) |
|---|---|---|---|---|---|---|---|
| **Thornguard** | Close-range tank | Bramble Scattergun: 5-shot spread, range 4 | *Thorn Ward*: 50% damage cut for 3 s (40) | 200 | 12 | 4.5 | 2.0 |
| **Gleamwright** | Mid-range support | Lumen Rod: piercing bolt, range 7 | *Kindle Pulse*: heals allies within 4 tiles for 25% max HP (60) | 140 | 6 | 5.0 | 2.5 |
| **Driftrunner** | Long-range skirmisher | Gale Sling: fast twin bolts, range 9 | *Slipstep*: blink 4 tiles with 0.3 s of no damage (30) | 120 | 4 | 6.0 | 3.5 |

All three have 100 Focus with 5/s regen. **[Later]** More classes, class unlocks and gear restricted to one class.

Why: three classes cover tank, support and ranged DPS, which is the minimum for co-op to matter. Keeping it to three also keeps art and balance work small.

## 3. Endless levels and power scaling

### 3.1 Scaling factor
One linear factor drives everything that scales with level:

```
m(L) = 1 + 0.05 × (L − 1)
```

Why: linear growth keeps numbers readable at level 1000 (about ×51, not ×10⁸). Because players and enemies both use `m`, relative power stays constant.

### 3.2 What scales
- **Player:** `MaxHP = classBaseHP × m(L) + gear HP`, and `Ward = classBaseWard × m(L) + gear Ward`.
- **Player damage** comes **only from weapon tier** (§4), not from level. This avoids double scaling, where level and gear compound into quadratic power.
- **Does not scale:** Stride, Tempo, Focus, range, projectile speed and bullet-pattern density. Dodging stays the skill test at every level.
- **Enemy at level E:** `HP = baseHP × m(E)`, `Damage = baseDmg × m(E)`, `Ward = baseWard × m(E)`.
- **Mitigation:** `damageTaken = rawDmg × 100 / (100 + Ward / m(attackerLevel))`. Ward stays meaningful at every level because it is normalized.

### 3.3 Level-difference clamp (anti power creep)
With player level Lp and content level E:

```
D = clamp(1 + 0.02 × (Lp − E), 0.60, 1.30)
damageDealt × D,  damageTaken × (1 / D)
```

Even being far above content gives at most +30%, so old content never becomes one-shot trivial. Being far below costs at most −40%, so there is still a chance with skill.

### 3.4 XP curve

```
killXP(E)  = 10 × m(E)                         (normal enemy; elite ×5, boss ×50)
killsToLevel(L) = 10 + 2 × L^0.75
xpToNext(L) = round(killXP(L) × killsToLevel(L))
```

| Level L | m(L) | killXP at E=L | kills to next | xpToNext(L) | Total XP to reach L |
|---|---|---|---|---|---|
| 1 | 1.00 | 10.0 | 12 | 120 | 0 |
| 10 | 1.45 | 14.5 | 21 | 308 | 1,811 |
| 20 | 1.95 | 19.5 | 29 | 564 | 5,997 |
| 50 | 3.45 | 34.5 | 48 | 1,642 | 37,427 |
| 100 | 5.95 | 59.5 | 73 | 4,358 | 181,591 |
| 500 | 25.95 | 259.5 | 221 | 57,473 | 10,830,199 |
| 1000 | 50.95 | 509.5 | 366 | 186,302 | 69,097,226 |

Why: tying XP to `m` means progress is measured in kills, not raw numbers. Kills per level grow sub-linearly, so level 1000 is about 213k on-level kills in total (about 120 h at 2 s/kill solo, much less in groups or dungeons). It feels endless but never becomes a wall. XP from kills is scaled by `clamp(1 − 0.05 × max(0, Lp − E), 0.1, 1)`, so farming content far below your level gives almost nothing.

Use 64-bit integers for XP. Total XP passes 2³¹ around level 2,800.

## 4. Endless gear tiers

### 4.1 Tier formula
Each slot has a tier T ≥ 0 (T0 to T∞). Slots: weapon, armor, charm (v0.1).

```
g(T) = 1 + 0.25 × T
weaponDamage = classWeaponBase × g(T)      (Thornguard 12/pellet, Gleamwright 30, Driftrunner 14/bolt)
armor HP     = 30 × g(T),  armor Ward = 4 × g(T)
charm        = one of: +Focus regen (fixed +1/s), +HP (20 × g(T)), +Ward (3 × g(T))
```

The **on-level tier** is `T* = floor(E / 5)`, so `g(T*) ≈ m(E)`. Gear of tier T* keeps time-to-kill constant against on-level enemies.

| Content level | On-level tier T* | g(T*) | Gleamwright bolt damage |
|---|---|---|---|
| 1 | T0 | 1.00 | 30 |
| 20 | T4 | 2.00 | 60 |
| 100 | T20 | 6.00 | 180 |
| 1000 | T200 | 51.00 | 1,530 |

**Effective tier clamp:** inside content of level E, the effective tier is `min(T, T* + 3)`. Overgear helps, by up to about +15% at mid levels, but cannot trivialize content.

Why: because tiers and levels use the same slope, nothing has to be rebalanced as tiers go up. Adding tier 201 is just a config row.

### 4.2 Drop rules
A drop from content level E rolls its tier relative to T*:

| Result | T* − 1 | T* | T* + 1 | T* + 2 |
|---|---|---|---|---|
| Normal enemy | 25% | 65% | 9% | 1% |
| Boss | 0% | 50% | 40% | 10% |

The minimum tier is 0. Item drop chance per kill is 4% for normal enemies and 100% for a boss (2 items). **[Later]** Affixes and rarity on top of tier, plus named set items.

## 5. Currencies (all farmable, no pay-to-win)

| Currency (placeholder) | Sources | Sinks |
|---|---|---|
| **Glint** (common) | Every kill: `ceil(m(E))`, boss ×30; selling gear: `10 × g(T)` | Vendor gear (`40 × g(T)` for tiers up to `T*(Lp) − 2`); tier-up fee; stash pages (500 × 2ⁿ); respawn fee (§7 Q3) |
| **Echo Dust** (crafting) | Salvaging gear: `5 × g(T)` | Tier-up T→T+1: `20 × g(T+1)` Dust + `100 × g(T+1)` Glint (about 4 salvages per step) |
| **Riftstone** (portal) | Dungeon boss: `3 × M²` per eligible player (§6) | Opening a portal with M > 1: `ceil(5 × M²)`; **[Later]** character slots, extra multiplier unlocks |

All sinks scale with `g` or `m` at the same slope as the sources, so inflation stays flat at any level. Vendor gear is always 2 tiers behind on-level, so drops and tier-ups stay the main way to progress.

**[Later]** A cosmetic-only premium currency (placeholder **Prism**). It never converts into, or buys, anything that affects power, and it can't be traded for Glint, Echo Dust or Riftstone.

## 6. Portal level multiplier

Whoever opens a portal (a dungeon instance, or **[Later]** a whole server instance) sets **M**.

- **Base level B:** the dungeon's base level (Hollowmere Vault: 10) or the opener's level, whichever is **higher**. The vault stays relevant forever.
- **Content level:** `E = max(1, round(B × M))`.
- **Range:** v0.1 allows M ∈ [0.50, 1.50] in steps of 0.05, default 1.00. Values above 1.5 are **[Later]**, unlocked by clearing at your current max.
- **What M scales:** enemy level E (so HP, damage and Ward through `m(E)`), kill XP through `killXP(E)`, drop tier through `T*(E)`, Glint through `m(E)`, and Riftstone through `3 × M²`. Bullet patterns and speeds do **not** change. **[Later]** Pattern density modifiers at high M.
- **Rewards:** above 1.00, the boss gets +1 extra item roll per 0.25 above 1.00 (two extra at 1.50). Riftstone grows as M², so risk is paid super-linearly. Below 1.00 there are no extra rolls and Riftstone drops off sharply (0.25 × base at M=0.5), so low-M portals are for helping friends, not farming.

### 6.1 Abuse and griefing limits
1. **Lock on entry:** M is fixed as soon as the portal is created, and the portal label shows `E` and `M` before anyone joins.
2. **Join floor:** players with `Lp < 0.5 × E` cannot enter. If `Lp < E − 10`, they get a confirm dialog ("Content level E, you are level Lp"). This stops luring new players into a death trap.
3. **Level-sync down:** players with `Lp > E + 5` are synced to level `E + 5` (HP and Ward at `m(E+5)`, tier clamp from §4.1 applied). Their rewards use E. High-level carries can't faceroll, and low-M runs can't be farmed by high levels.
4. **Anti power-leveling:** XP per kill for a player is capped at `1% × xpToNext(Lp)` from that kill. A level-15 player in an E=60 run gains quickly, but it doesn't jump them 30 levels.
5. **Contribution check (anti-AFK/leech):** boss rewards need ≥ 2% of boss damage dealt, **or** healing/support activity, **or** being within 12 tiles with input in the last 30 s.
6. **Rate limits:** one open portal per player, a 60 s cooldown on opening, and the instance closes 10 min after it empties.
7. **Cost gate:** M > 1 costs Riftstone up front (§5), so spam-opening high M portals is not free.

## 7. Open questions for Karyu

1. **Death model:** permadeath, soft death or a hybrid? *Recommendation:* soft death for v0.1. Respawn in the Hearth, lose the unbanked loot from that run, and pay a Glint respawn fee of `20 × m(L)`. Permadeath could come back later as an opt-in hardcore mode with its own leaderboard.
2. **Multiplier ceiling:** keep v0.1 at 0.5–1.5? *Recommendation:* yes. Raise the ceiling only after playtesting, unlocked by clearing (for example +0.25 per clear at your max, hard cap 3.0).
3. **Player trading:** allow trading gear and currencies between players? *Recommendation:* not in v0.1, so that real-money markets don't form. Later, allow trading gear only, with no currency trading.
4. **Cosmetic monetization:** should Prism cosmetics also be earnable in game? *Recommendation:* yes, a small seasonal earnable track. That stays true to "everything farmable" while paid cosmetics remain a shortcut.
5. **Server-instance multiplier:** can a server owner set M for a whole shard? *Recommendation:* later phase. Keep v0.1 to portal-level M, so there is one rule set to balance and test.
6. **Stat identity growth:** should Tempo and Stride grow with level at all? *Recommendation:* no. Keep them fixed per class, and let gear charms give at most +10%, so dodge skill stays the core at every level.
7. **Overgear clamp:** is `T* + 3` too strict for players who like to "twink" old content? *Recommendation:* keep it for v0.1 and loosen it only if playtesters complain.
