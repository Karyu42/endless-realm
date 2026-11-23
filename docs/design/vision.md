# Endless Realm: Design Vision (v0.1)

Status: draft for review · Owner: Game Design · Scope: first playable slice

Endless Realm is a co-op, top-down bullet-hell MMO. It has no level cap and gear tiers that never stop. Everything except cosmetics can be earned in game, so there is no pay-to-win. Every name, asset and line of text is original. Nothing is taken from any existing game.

All formulas are the source of truth. Tables only illustrate them. All numbers are starting values for tuning. Put them in config, not in code.

Companion docs: base stats for v0.1 enemies, the Tallow Warden, the Wilds ring layout and projectile speeds will live in [`docs/design/content-v0.1.md`](content-v0.1.md) (merged from PR #4). **This doc is the source of truth.** Where the two disagree, vision.md wins. The engine, netcode and persistence choices are in [`docs/tech/stack.md`](../tech/stack.md). Detailed anti-cheat and anomaly-detection thresholds live in a **private ops doc** (for official services such as the listing service; inside a lobby the host admin replaces Economy Ops, D30) and are deliberately not in this public repo.

**Hosting (D17):** there are no official servers for now, only offline solo and player-hosted lobbies (§11). "The server" in this doc means the lobby's host (the Godot game as listen server or `--headless`, D24). Sections that assumed one trusted official server are marked **⚠ Hosting** and reconciled in §11.6.

Legend: **[v0.1]** is in the first playable slice. **[Later]** is a later-phase idea, written down so v0.1 doesn't block it.

---

## 1. Core loop

1. **[v0.1]** Spawn in **the Hearth**, a safe hub with a vendor, a stash and a portal board.
2. Step into **the Wilds**, a shared open zone in rings. Enemy level rises from the edge (level 1) toward the center (top ring = base level 20 in v0.1; ring count, widths and levels are in `content-v0.1.md`).
3. Dodge bullet patterns, kill enemies, and earn XP, Glint and gear drops.
4. Find a **portal**, or open one with a **Vault Sigil**, to a dungeon instance (v0.1 has one dungeon, **the Hollowmere Vault**, with one boss, **the Tallow Warden**). The opener sets the level multiplier (§6).
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

All three have 100 Focus with 5/s regen. Stride and Tempo are fixed per class. All gear together can add at most +10% to each (D6).

**Ability rules:** Focus and a per-ability cooldown both apply.
- **Thorn Ward:** 8 s cooldown. The 50% cut multiplies the final damage (after Ward mitigation and the §3.3 `D` factor). Recasting refreshes the duration and doesn't stack.
- **Kindle Pulse:** 6 s cooldown. Heals the caster too. The heal is rounded half-up to a whole HP.
- **Slipstep:** 3 s cooldown. It passes through enemies and bullets but not walls: the blink stops at the last free tile before a blocking tile. **[Later]** More classes, class unlocks and gear restricted to one class.

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
- **Mitigation:** `damage = rawDmg × 100 / (100 + defenderWard / m(attackerLevel))`, then × `D` (§3.3). The result is rounded half-up to a whole HP, with a minimum of 1. Ward stays meaningful at every level because it is normalized.
  - When an **enemy hits a player**, `attackerLevel = E`, the enemy's level.
  - When a **player hits an enemy**, `attackerLevel = W = max(1, 5 × T_eff)`, the weapon's *gear level* from its effective tier (§4.1). Enemy mitigation therefore depends on the player's gear, not their level.
  - **Worked example (golden value):** an L20 Gleamwright with a T4 Lumen Rod (60 damage) hits an E=20 enemy with `baseWard = 10`. Enemy Ward is `10 × 1.95 = 19.5`, and `W = 20`, so `m(W) = 1.95`. Damage is `60 × 100 / (100 + 10) = 54.55`; with `D = 1` that is **55**.

### 3.2a Effective level
One rule applies everywhere: **inside a portal**, `Le = min(Lp, E + 5)` (level sync, §6.1). **In the Wilds and the Hearth**, `Le = Lp`.

`Le` is used by all combat and reward formulas: HP and Ward (`m(Le)`), `D`, the XP rules in §3.4 and the Sparks rule in §9. The **real** level `Lp` is used only for the join floor (§6.1), the respawn fee (§7), trade NTV (§8.4), and leaderboards and XP storage.

| Example (portal E = 40) | Lp | Le | Notes |
|---|---|---|---|
| Over-level | 60 | 45 | Synced. `D = 1.10`. Over-level XP penalty at `Le − E = 5` |
| On-level | 40 | 40 | Normal |
| Under-level | 25 | 25 | `D = 0.70`. XP per kill is credited as `killXP(35)` (§3.4) |
| Too low | 15 | – | Can't join (`15 < 0.5 × 40`) |

### 3.3 Level-difference clamp (anti power creep)
With effective level Le (§3.2a) and the level E of the specific enemy:

```
D = clamp(1 + 0.02 × (Le − E), 0.60, 1.30)
damageDealt × D,  damageTaken × (1 / D)
```

Even being far above content gives at most +30%, so old content never becomes one-shot trivial. Being far below costs at most −40%, so there is still a chance with skill.

### 3.4 XP curve

```
killXP(E)  = 10 × m(E)                         (normal enemy; elite ×5, boss ×50)
killsToLevel(L) = 10 + 2 × L^0.75
xpToNext(L) = round(killXP(L) × killsToLevel(L))

credited XP per kill = killXP(min(E, Le + 10)) × typeMult × overLevelPenalty
overLevelPenalty = clamp(1 − 0.05 × max(0, Le − E), 0.1, 1)
```

No per-kill cap applies to on-level or over-level kills, or to bosses. **Anti power-leveling:** an under-level player is credited XP as if the enemy were at most 10 levels above them. Carried players still level faster than solo, but they can't jump dozens of levels in a run, and the table below holds exactly for on-level play.

XP is stored as an int64 count of **tenths of XP**. Each credited XP value is rounded half-up to 0.1. **Acceptance test:** an on-level normal kill at L10 credits exactly 14.5 XP, and an on-level boss kill at L10 credits 725.0 XP.

| Level L | m(L) | killXP at E=L | kills to next | xpToNext(L) | Total XP to reach L |
|---|---|---|---|---|---|
| 1 | 1.00 | 10.0 | 12 | 120 | 0 |
| 10 | 1.45 | 14.5 | 21 | 308 | 1,811 |
| 20 | 1.95 | 19.5 | 29 | 564 | 5,997 |
| 50 | 3.45 | 34.5 | 48 | 1,642 | 37,427 |
| 100 | 5.95 | 59.5 | 73 | 4,358 | 181,591 |
| 500 | 25.95 | 259.5 | 221 | 57,473 | 10,830,199 |
| 1000 | 50.95 | 509.5 | 366 | 186,302 | 69,097,226 |

Why: tying XP to `m` means progress is measured in kills, not raw numbers. Kills per level grow sub-linearly, so level 1000 is about 213k on-level kills in total (about 120 h at 2 s/kill solo, much less in groups or dungeons). It feels endless but never becomes a wall. The over-level penalty means farming content far below your level gives almost nothing.

Use 64-bit integers for XP. Total XP passes 2³¹ at about level 3,545 (in whole XP; tenths are 10× that).

### 3.5 Group scaling by peak players in range (n_peak) [v0.1]

Karyu's rule: enemy scaling follows the players **in range**, and it stays at the **highest count reached** during an encounter, even if players leave, die or the count fluctuates. It applies everywhere enemies exist: the Wilds, dungeon rooms and the boss arena. In offline solo, `n_peak` is always 1.

**What scales:** enemy **max HP only**.
- **Not scaled:** damage, Ward, bullet count, pattern density, speeds and attack intervals. Dodging stays the skill test at any group size (§3.2), and a 50-player crowd doesn't turn the screen into an undodgeable wall.
- **Rewards are not scaled by n:** loot stays **personal** (§4.2). Every eligible player gets their own normal rolls, XP (§3.4), Glint (§5), Riftstone (§6) and Sparks (§9), exactly as solo. Total loot grows with the group only because each extra eligible player rolls their own.

**Encounter groups.** `n_peak` is tracked per encounter group, not per player:

| Content | Encounter group | "In range" (`n_now`) | Starts | Ends (and resets `n_peak`) |
|---|---|---|---|---|
| **Wilds** | One enemy, or one pack spawned together (e.g. a Burrmite pack of 3) | Living players within **12 tiles** of any living member | On **aggro**: the first tick a player is inside the member's aggro radius (content §2.3) or damages it | **Death** of the last member; **leash** (pulled > 16 tiles from spawn or into another ring, content §2.1); or **de-aggro**: no player within its aggro radius for **10 s** in a row. On leash and de-aggro the members walk back and heal to full max HP at `n = 1` |
| **Dungeon room** (rooms 1–5) | All enemies of the room, every wave included | Living players **inside the room's bounds** or within **12 tiles** of any living enemy of the room (covers shooting from the doorway) | **Room activation**: the first player enters the room (content §3.1) | **Cleared** (every enemy of every wave dead), or **room reset**: no player in range for **30 s** in a row. On reset, surviving enemies heal to full at `n = 1`, unspawned waves stay unspawned, and the room re-activates on the next entry |
| **Boss arena** (room 6) | The boss plus all its adds | Living players **inside the arena bounds** | The first tick a living player is inside the arena | **Boss death**, or **boss reset** (no living player left in the arena, §6.1 rule 6a), or instance collapse |

- **Counting:** `n_now` counts distinct living characters present in the world (connected **or lingering**, §7.3). Dead characters don't count, but they don't lower `n_peak` either. It is evaluated **every tick** (20 Hz).
- **Never decreases:** `n_peak = max(n_peak, n_now)` each tick, with `n_peak ≥ 1` from the encounter's start. Only the end events above reset it.
- **Why 12 tiles:** the longest player weapon range is 9 tiles (Gale Sling) and the loot-proximity radius is 10 (§4.2). Anyone who can hit the enemy or share its loot is counted.
- **Spawns inside an encounter:** a later wave or a summoned add spawns at the group's current `n_peak`.
- **Tick order:** apply joins/leaves and movement first; start encounters; sample living in-range players and update every group's peak; rescale living enemies; then process attacks, damage, deaths, phase transitions and end/reset events. Deaths later in this tick do not retroactively lower its sampled count. Dead enemies are never rescaled. Phase transitions **latch** until reset, so a rescale or rounding cannot undo one.
- **Overlapping groups:** one player can count in multiple encounter groups on the same tick (a doorway between rooms or overlapping Wilds packs). Count once per group; this is intentional. Boundaries use distance squared ≤ 144, same zone/mode, and room polygons include their boundary. A pack leash/de-aggro resets the whole pack; the Matron's content-defined 20-tile no-leash exception still applies. Resetting clears damage, eligibility and outstanding projectiles for that encounter before new aggro. An uncleared room can re-activate from in-range damage as well as entry, so doorway shots cannot hit a dormant unscaled room.

**Curve.** One kink at 8 players: the approved v0.1 coefficients hold exactly up to 8 (so every 8-player number in `content-v0.1.md` stays valid), and each player past 8 adds half as much:

```
n_max = 50                                      (data-pack ceiling, provisional until the 50-player load test passes; not live lobby occupancy)
n = min(n_peak, n_max)
s100(n) = 100 + k × (min(n, 8) − 1) + t × max(0, n − 8)

normal enemies: k = 60, t = 30
boss:           k = 75, t = 38
(boss adds are normal enemies: normal k and t, with the boss encounter's n_peak)

maxHP = (baseHP × m100(E) × s100(n_peak) + 5000) div 10000     (exact integer math, half-up; m100(E) = 100 + 5 × (E − 1))
```

**Raising max HP mid-encounter:** when `n_peak` rises, the new max HP is computed from the formula, and current HP keeps its fraction: `curHP' = (curHP × maxHP' + maxHP div 2) div maxHP` (half-up). Phase thresholds always compare against the current max HP. Max HP never goes down during an encounter.

| n (peak) | 1 | 2 | 4 | 8 | 16 | 32 | 50 |
|---|---|---|---|---|---|---|---|
| Normal enemy HP × | 1.00 | 1.60 | 2.80 | 5.20 | 7.60 | 12.40 | 17.80 |
| Boss HP × | 1.00 | 1.75 | 3.25 | 6.25 | 9.29 | 15.37 | 22.21 |
| Tallow Warden max HP at E = 10 | 7,975 | 13,956 | 25,919 | 49,844 | 74,088 | 122,576 | 177,125 |
| Ideal boss fight (100 s solo × s / n) | 100 s | 88 s | 81 s | 78 s | 58 s | 48 s | 44 s |

The ideal fight time assumes damage grows linearly with players. Real crowds lose some damage to dodging and overlap, so large fights should land at about 50–70 s. **Tuning (Design's call):** the kink at 8 and the tail coefficients `t` are playtest knobs. Because rewards stay per player while HP grows half as fast past 8, rewards per unit of enemy HP rise in big groups (about 2.8× solo at n = 50 for normal enemies, vs 1.5× at n = 8). That is intended to make big lobbies feel good; watch it in playtests. Full curve for n = 1…50 is in Appendix A.

**Golden values (acceptance tests):** Tallow Warden at E = 10: n = 8 → 49,844, n = 16 → 74,088, n = 50 → 177,125. A normal enemy with baseHP 100 at E = 1: n = 9 → 550, n = 50 → 1,780. A boss at 60% HP (`(49,844 × 60 + 50) div 100 = 29,906`) when `n_peak` goes 8 → 9 at E = 10: max 49,844 → 52,874, current 29,906 → 31,724.

**[Later]** Bigger arenas for large lobbies. The 21×21 Warden's Sanctum gets crowded past about 16 players; that is a content-tuning follow-up, not a rule change.

## 4. Endless gear tiers

### 4.1 Tier formula
Each slot has a tier T ≥ 0 (T0 to T∞). Slots: weapon, armor, charm (v0.1).

```
g(T) = 1 + 0.25 × T
weaponDamage = classWeaponBase × g(T)      (Thornguard 12/pellet, Gleamwright 30, Driftrunner 14/bolt)
armor HP     = 30 × g(T),  armor Ward = 4 × g(T)
charm        = one of: +Focus regen (fixed +1/s), +HP (20 × g(T)), +Ward (3 × g(T)), +Stride 2–10%, +Tempo 2–10%
               (total Stride/Tempo bonus from all gear capped at +10% each, D6)
```

The **on-level tier** is `T* = floor(E / 5)`, so `g(T*) ≈ m(E)`. Gear of tier T* keeps time-to-kill constant against on-level enemies.

| Content level | On-level tier T* | g(T*) | Gleamwright bolt damage |
|---|---|---|---|
| 1 | T0 | 1.00 | 30 |
| 20 | T4 | 2.00 | 60 |
| 100 | T20 | 6.00 | 180 |
| 1000 | T200 | 51.00 | 1,530 |

**Effective tier clamp (D7):** against an enemy of level E (each enemy's own level, in the Wilds too), the effective tier is `T_eff = min(T, T*(E) + 3)`. The most overgear can add is `+0.75` to `g`. As a share of on-level damage that is **+75% at E 1–4, +37.5% at E 20, +21% at E 50, +12.5% at E 100 and +3% at E 500**, and it stacks with `D` (at most ×1.30). Overgear is strongest in the low v0.1 levels and fades as levels rise. That is intended: it rewards running content again early, and it doesn't trivialize endgame content. Revisit after playtests (tuning).

Charm rolls for +Stride and +Tempo are uniform integer percentages from 2 to 10.

Why: because tiers and levels use the same slope, nothing has to be rebalanced as tiers go up. Adding tier 201 is just a config row.

### 4.2 Drop rules
A drop from content level E rolls its tier relative to T*:

| Result | T* − 1 | T* | T* + 1 | T* + 2 |
|---|---|---|---|---|
| Normal enemy | 25% | 65% | 9% | 1% |
| Boss | 0% | 50% | 40% | 10% |

The minimum tier is 0. Item drop chance per kill is 4% for normal enemies and 100% for a boss (2 items, plus extra rolls from §6). **Loot is personal:** every eligible player gets their own rolls and their own drops, visible only to them, so there are no loot fights. A player is eligible for a normal kill if they damaged the enemy or were within 10 tiles when it died. Boss eligibility is in §6.1. **[Later]** Affixes and rarity on top of tier, plus named set items.

## 5. Currencies (all farmable, no pay-to-win)

| Currency (placeholder) | Sources | Sinks |
|---|---|---|
| **Glint** (common) | Every kill: `ceil(m(E))` per eligible player, boss ×30; selling gear: `10 × g(T)` | Vendor gear (`40 × g(T)` for tiers up to `T*(Lp) − 2`); tier-up fee; **Vault Sigil** (`150 × m(Lp)`, §6); stash pages (pages 1–2 free; the k-th page bought costs `500 × 2^(k−1)`: 500, 1,000, 2,000 …); respawn fee (§7) |
| **Echo Dust** (crafting) | Salvaging gear: `5 × g(T)` | Tier-up T→T+1: `20 × g(T+1)` Dust + `100 × g(T+1)` Glint (about 4 salvages per step) |
| **Riftstone** (portal) | Dungeon boss: `round(4 × M²)` per eligible player (§6) | Portal deposit forfeited on a failed run (§6); charm re-roll (2); **[Later]** character slots, extra multiplier unlocks |

**Ledger rule:** every currency movement goes through the double-entry ledger (§8.2). That includes kill grants, banking, the vendor, Sigil purchases, tier-ups, salvage, the respawn fee, portal deposits and refunds, and trade fees, not just trades.

**Vault Sigil [v0.1]:** a consumable item (with its own `item_uid`) bought from the Hearth vendor.
- **Price:** `150 × m(Lp)` Glint, computed as `(150 × (100 + 5 × (Lp − 1)) + 50) div 100`, at the buyer's real level (L1 → 150, L20 → 293, L100 → 893).
- **Rules:** it is not tradeable in v0.1 and has no level binding, so it can be used at any later level. It is consumed at the Hearth portal board to open a Hollowmere Vault portal (§6).

Level-dependent sources and sinks (kill Glint, selling, the vendor, tier-ups, the Sigil, the respawn fee) all scale with `g` or `m` at the same slope, so inflation stays flat at any level. Stash pages and the Riftstone sinks are deliberately flat one-off or utility costs. Vendor gear is always 2 tiers behind on-level, so drops and tier-ups stay the main way to progress.

Glint, Echo Dust and Riftstone can be traded between players (§8). Hardcore characters have separate wallets (§7). The cosmetic-only currency **Prism** is **[Later]**: it ships with the cosmetic store, and the first playable has no paid cosmetics (`stack.md` decision 6). It is never tradeable (D8).

## 6. Portal level multiplier

Whoever opens a portal (a dungeon instance; a whole server instance or shard is **[Later]**, D5) sets **M**.

**Opening a portal:** at the Hearth portal board, the opener consumes one **Vault Sigil** (§5), picks M and, if M > 1, pays the Riftstone deposit (below). The Sigil and deposit are taken in one transaction with the instance's creation. If anything fails, nothing is taken.

- **Wire format and validation:** M is sent as an integer number of hundredths, `M100`. The server accepts only `50 ≤ M100 ≤ 150` with `M100 % 5 == 0` and rejects anything else with `INVALID_MULTIPLIER` (acceptance tests: 0.45, 1.55 and 1.07 are rejected; 0.50, 1.05 and 1.50 are accepted). Values above 1.5 are **[Later]**: +0.25 per clear at your current max, up to a **hard cap of 3.0** (D2).
- **Base level B:** the higher of the dungeon's base level (Hollowmere Vault: 10) and the opener's **real** level `Lp` at the moment the portal is created. B is fixed for the instance. The vault stays relevant forever.
- **Content level:** `E = max(1, (B × M100 + 50) div 100)`, which is round half-up in exact integer math (B = 15, M = 0.50 → 7.5 → **8**).
- **Found portals (Wilds):** an elite in the Wilds has a 10% chance to leave a Hollowmere portal. It always has **M = 1.00** and no deposit. B is the higher of the dungeon's base level and that elite's level, and there is no opener. A found portal follows the same lifetime rules as an opened one.
- **What M scales:** enemy level E (so HP, damage and Ward through `m(E)`), kill XP through `killXP(E)`, drop tier through `T*(E)`, Glint through `m(E)`, extra boss rolls and Riftstone. Bullet patterns and speeds do **not** change. **[Later]** Pattern density modifiers at high M.
- **Rewards:**
  - Each eligible player gets `floor((M100 − 100) / 25)` extra boss item rolls when M > 1 (M 1.20 → 0, 1.25 → 1, 1.50 → 2).
  - Riftstone per eligible player is `(4 × M100² + 5000) div 10000`, which is `round(4 × M²)` half-up: M 0.50 → 1, 1.00 → 4, 1.25 → 6, 1.50 → 9.
- **Deposit, not a fee:** opening with M > 1 takes a Riftstone deposit of `(5 × M100² + 9999) div 10000`, which is `ceil(5 × M²)` (6 at M 1.05, 8 at 1.25, 12 at 1.50).
  - **Refund:** when the boss dies, the deposit goes back in full to the opener's banked wallet as one ledger transaction, idempotent per instance id. This happens even if the opener is dead, disconnected or outside the instance at that moment.
  - **Server fault:** the deposit and the Sigil are refunded if the instance is lost to a fault (§7.3).
  - **Forfeit:** otherwise the deposit goes to the sink if the instance closes without a boss kill.
- **Net Riftstone per solo clear:** +4 at M 1.00, +6 at 1.25 and +9 at 1.50, so a clear always pays and higher M pays more. Below 1.00 it pays 1 (M 0.50) to 4 (M 0.95), never more than at M 1.00, so low-M runs are for helping friends, not farming.

### 6.1 Instance rules and abuse limits
1. **Lock on creation:** M and B are fixed when the portal is created, and the portal label shows `E` and `M` before anyone joins.
2. **Join floor:** players with real `Lp < 0.5 × E` can't enter. If `Lp < E − 10`, they get a confirm dialog ("Content level E, you are level Lp"). This stops luring new players into a death trap.
3. **Level sync down:** inside the portal, players use `Le = min(Lp, E + 5)` (§3.2a), with the tier clamp from §4.1. High-level carries can't faceroll, and low-M runs can't be farmed by high levels.
4. **Anti power-leveling:** under-level XP is credited at no more than `Le + 10` (§3.4). There is no per-kill cap.
5. **Player cap:** a portal instance holds up to the lobby's **max players** (host setting, 1–50, default 50, §11.3). Each portal stores its capacity **at creation**; later lobby max-player changes affect new portals only, not existing entrances or reserved re-entry slots. The lobby-wide live admission cap still applies. The entrance closes once that stored many distinct slots have been admitted and never reopens merely because a player leaves. Offline solo is always 1.
6. **Group scaling:** enemy max HP scales with the **peak** number of players in range, `n_peak`, per encounter (§3.5): rooms track it from activation to clear or reset, and the boss arena from the first player entering to the boss's death or reset. Damage and patterns are not scaled. Max HP only ever rises during an encounter (keeping the current HP fraction), never falls when players leave, die or disconnect.
6a. **Boss-arena seal:**
   - **Start:** the arena seals on the tick the boss first takes damage, and that tick is also the fight start. The boss encounter's `n_peak` (§3.5) has been counting since the first player entered the arena; it keeps counting while sealed, and since nobody can enter, it only changes before the seal.
   - **While sealed:** nobody can enter the arena. That includes new joiners and Standard players rejoining, who can enter the instance but wait outside the arena door. Nobody inside can leave except by dying or disconnecting (§7.3 linger).
   - **Lifting:** the seal lifts when the boss dies, when no living player is left in the arena (the boss then resets to full HP and is untouched for 5 s before a new fight can start), or when the instance collapses.
7. **Boss eligibility (contribution check):** a player is eligible for the boss rewards if any one of these is true during the fight (which starts when the boss first takes damage):
   - (a) they dealt ≥ 2% of the boss's max HP;
   - (b) they used an ability that affected an ally at least 2 times;
   - (c) they were within 12 tiles of the boss for ≥ 50% of the fight's ticks.

   In every case they must also have sent non-idle input in the 30 s before the kill. **Non-idle input** means at least one input frame (`move, aim, fire_held, seq`, per `stack.md`) in which the move vector differs from the previous frame, the aim angle changed by ≥ 1°, `fire_held` is true, or an ability was used.
8. **Lifetimes:**
   - The entrance stays open 120 s after creation, or until its creation-time capacity has been admitted (rule 5).
   - An instance lasts at most 30 min. At that point it collapses and players are moved to the Hearth, which banks their loot (§7).
   - An instance closes 60 s after it empties.
   - A deposit (above) is forfeited if the instance closes without a boss kill, except when it is lost to a server fault (§7.3).
9. **Re-entry after death (Standard):** a Standard player who died keeps their party slot and can rejoin the same live instance from the Hearth portal board, up to 2 times per instance. The 120 s entrance limit doesn't apply to rejoining. They can enter the instance during a fight but not the sealed arena (rule 6a). Hardcore deaths are final.
10. **Rate limits:** one open portal per player, with a 60 s cooldown that starts when the portal is opened.

## 7. Death modes [v0.1]

Each character is created as **Standard** or **Hardcore**. The mode is fixed for the character's whole life.

### 7.1 Banking model (both modes)
- **Pending:** everything picked up or earned outside the Hearth is *pending*. Items carry `pending = true` wherever they are (inventory or equipped). Currency goes into the character's pending wallet. Equipping a pending item is allowed, and it stays pending.
- **Banking event:** the moment the character's position enters the Hearth zone (portal exit, instance collapse, walking in, or reconnecting into the Hearth), the server clears every pending flag and moves pending currency into the account's banked wallet for that mode. This is one ledger transaction. Trading, salvage, the vendor and the stash exist only in the Hearth, so they only ever touch banked assets.
- **XP is never pending.** XP is kept the moment it's credited, even if you die later.

### 7.2 Standard death (soft)
The server applies these steps in order, in one transaction:
1. Pending items, equipped or not, are tombstoned with reason `DEATH_PENDING`. Banked items (equipped or in inventory) are kept.
2. Pending currency moves to the sink.
3. A respawn fee of `20 × m(Lp)` Glint (real level, not synced) is taken from the banked wallet. If the balance is lower, the fee is the balance, so it never goes below 0.
4. The character respawns in the Hearth with full HP. Level and XP are kept.

### 7.3 Hardcore (permadeath)
- **Separate realm:** hardcore characters have their own Glint, Echo Dust and Riftstone wallets, their own stash, their own ledger accounts (§8.2) and their own trading pool.
  - **Instances:** hardcore uses its own Hearth and its own Wilds and portal instances. Hardcore players never see, heal or fight beside Standard players.
  - **No crossover:** no gear or currency moves between hardcore and Standard, in either direction. The only exception is account-wide cosmetic unlocks, which have no power (§9).
- **On death:** the character is **Fallen**. Equipped gear, inventory and pending loot are tombstoned with reason `DEATH_FALLEN`, along with pending currency. The account's hardcore stash and hardcore wallets survive. The Fallen character stays as a read-only memorial with its name, class, level, cause of death and date.
- **Disconnect rule (both modes; it matters most for hardcore):**
  - **Link lost:** the client sends a heartbeat every 1 s. The link counts as lost on a socket close, or after **5 s** with no packet.
  - **Linger:** for the next **5 s** the character stays in the world. It stops moving, can't fire or use abilities, takes damage normally and can die.
  - **After linger:** if it survives, the character is removed from the instance. On reconnect it appears in the Hearth, and its pending loot banks (§7.1).
  - **Logout:** a voluntary logout or quit outside the Hearth uses the same 5 s linger. A logout inside the Hearth is instant.
  - **Incident windows:** these protect players from server faults.
    - **⚠ Hosting:** "on-call" below means the lobby's **host admin** (§11.6).
    - **Opening:** the server opens one automatically when an instance worker crashes or restarts, or its tick stalls for more than 2 s. On-call ops can also open one manually for an outage, with a required reason.
    - **Scope:** a window covers the instance, or the whole server for a manual one, from 30 s before the fault until it ends.
    - **End:**
      - An automatic window ends when the instance is declared lost (a worker crash, or a tick stall over 10 s ends the instance), or once its tick has been healthy for 30 s in a row (no tick more than 100 ms late).
      - Automatic windows last at most 15 min unless on-call extends them.
      - A manual window ends when on-call closes it, with a required reason.
    - **Instance lost to a fault:**
      - Players are placed in the Hearth on reconnect, and their pending loot **banks normally**, so it is not forfeited.
      - The opener gets back the Riftstone deposit and a freshly minted Vault Sigil (new `item_uid`, reason `INCIDENT_REFUND`).
      - Ground drops nobody picked up are tombstoned `EXPIRED`, with no further compensation in v0.1.
    - **Reverts:** deaths inside a window are reverted. The character is restored, tombstoned items are un-tombstoned, and the fee and pending loss are refunded. One audit row is written per revert, with the incident id, actor, character and items. Manual reverts are allowed up to 72 h after the death.
- **Leaderboard (⚠ Hosting: per lobby in v0.1, no global board; Offline-flagged characters are never listed, §11.6–11.7):** there are boards for all time and for each season. Ranking is by level, then total XP, then the earliest time the level was reached, with filters per class. Alive and Fallen characters are both listed, with a status badge.
- **Reward:** hardcore earns no power bonus. Leaderboard ranks and milestones (level 20/50/100 reached in hardcore) give cosmetic titles and portal trails only.

Why: keeping the hardcore economy fully separate is the only way its scarcity stays meaningful. If gear could flow in from standard, permadeath would cost nothing.

## 8. Player trading [v0.1]

Full trading is allowed: items **and** currencies (Glint, Echo Dust, Riftstone) can be traded between players in the same mode (§7). Cosmetic tokens (§9) can be traded in Standard only. **Prism and purchased cosmetics are never tradeable** (D8).

### 8.1 Trade flow
1. Trading happens only in the Hearth. To open a trade window, the two players must be within 3 tiles. The window is cancelled if either player moves more than 6 tiles away, changes zone, disconnects or closes it.
2. Each side offers up to 8 item slots (gear or Standard cosmetic tokens), plus currency amounts. An amount can be at most the sender's **tradeable** banked balance (§8.4) minus the fee.
3. Both sides press **Lock**. Any offer change after a Lock, during the countdown or after one side has confirmed resets both sides to unlocked and restarts the countdown.
4. A 3-second review countdown runs, then both sides press **Confirm**.
5. The server commits the trade, or rejects it as a whole.
6. **Timers:** the window is cancelled after 60 s with no offer change or button press, and it lasts at most 5 min.

### 8.2 Data integrity (server-authoritative)
**⚠ Hosting:** all of §8 runs **per lobby** on the lobby's host and its save. The rules are unchanged; "Economy Ops", "on-call" and `econ_admin` mean the lobby's host admin. Offline-flagged characters can't trade with non-Offline ones (§11.7). See §11.6.

- **One item table:** every item, gear or cosmetic token, is exactly one row in `items`, keyed by a server-minted UUIDv7 `item_uid` (the primary key).
  - **Fields:** each row has `mode`, `owner_account`, `owner_character`, `location`, `slot`, `pending`, `trade_lock` and `state`.
  - **Locations:** `location` is one of `EQUIPPED`, `INVENTORY`, `STASH`, `GROUND` (owned by an instance, for a personal drop not yet picked up) or **[Later]** `MAIL`. Offered items stay where they are, with `trade_lock = trade_id`, so there is no escrow copy.
  - **Tombstones:** destroyed, salvaged and vendor-sold items are **tombstoned**, never deleted. Their `state` is `TOMBSTONED`, with a reason (`SALVAGED`, `SOLD`, `CONSUMED` (a used Sigil), `EXPIRED`, `DEATH_PENDING`, `DEATH_FALLEN` or `ADMIN`) and a timestamp. **Ground expiry:** a personal drop left on `GROUND` is tombstoned `EXPIRED` 60 s after it drops, or when its instance closes, whichever comes first. The same applies in the Wilds. A tombstoned `item_uid` can come back only through an audited incident revert (§7.3).
  - **Acceptance test:** at any time, every `item_uid` resolves to exactly one row and one location, checked by the primary key plus an automated invariant test.
- **Ledger:** a double-entry `ledger_entries` table. Every currency movement (§5) is a transaction whose entries sum to zero per currency.
  - **Mint and sink:** grants come from a `FAUCET` system account and spending goes to a `SINK` account. Each mode has its own pair per currency, so hardcore and Standard are separate ledgers, and a transaction may not mix modes.
  - **Batching:** kill grants may be batched per instance into one transaction every ≤ 5 s.
  - **Consistency rule:** cached wallet balances are updated in the same transaction as their entries. A database check at commit time rejects any transaction whose entries don't sum to zero. A full reconciliation job compares every cached balance to the ledger every 15 min, so the **maximum detection latency is 15 min**.
- **Commit transaction:** one `SERIALIZABLE` transaction locks both accounts' wallets and the offered item rows, in ascending account-id order to avoid deadlocks. Lock timeout is 2 s.
  - **Inside the transaction:** ownership and amount checks, the gate and daily cap (§8.4), the re-trade-hold check, the trade ledger entries, the fee entries, the new hold tranches for the receiver, the cap counters, the trade-log row (§8.3) and the stored result. Anomaly flags are evaluated asynchronously afterwards and are not part of the commit.
  - **Failure handling:** on a serialization failure or lock timeout, the server retries automatically up to 3 times with 50–200 ms jittered backoff. The whole commit has a 5 s budget.
  - **Result codes:** `COMMITTED`, `REJECTED_<reason>` (`INSUFFICIENT_FUNDS`, `ITEM_MOVED`, `HELD_ASSET`, `DAILY_CAP`, `GATE`, `FROZEN` or `TRADING_PAUSED`), `FAILED_RETRY` or `TIMED_OUT`. Any result other than `COMMITTED` changes nothing. Both clients then show "Trade failed — nothing changed (reason)", and the window returns to unlocked.
- **Idempotency:** the server creates the `trade_id` (UUIDv7) when the window opens, and it is the primary key of the `trades` table, which stores the final result. A repeated commit for a `trade_id` returns the **original** result.
  - **Lock and Confirm:** these messages carry `(trade_id, offer_version)` and are idempotent. A message with a stale `offer_version` is ignored.
  - **Acceptance test:** sending the same commit N times produces exactly one ledger transaction per currency and one trade-log row.
- **Concurrency acceptance tests:**
  - **CI:** 200 concurrent trades plus 200 concurrent equip, salvage, sell and stash operations over 20 accounts for 60 s.
  - **Nightly soak:** 2,000 concurrent operations over 200 accounts for 30 min.
  - **Pass criteria:** every `item_uid` is in exactly one live location or tombstoned; per mode and currency, the ledger total equals faucet minus sink and every cached balance matches the ledger; every `trade_id` is either fully applied or not at all; no lock wait exceeds 2 s.
- **Freeze and pause:**
  - **Item freeze:** if an `item_uid` integrity check fails, the affected items are frozen. They stay where they are and still work if equipped, but they can't be traded, moved, salvaged, sold or stashed.
  - **Wallet freeze:** if a wallet fails reconciliation, it is frozen. It still receives grants, but trades, the vendor and tier-ups that debit it are blocked.
  - **Kill switch:** an unbalanced ledger trips a server-wide pause on trade commits. In-flight commits fail with `TRADING_PAUSED` and open windows close. Everything else keeps running.
  - **Owners:** the kill switch trips automatically or by the on-call server engineer. Freezes are applied automatically and reviewed by **Economy Ops** (in v0.1, the on-call server engineer with the `econ_admin` role). Only `econ_admin` can clear a freeze or the pause, and every action is audited. The on-call engineer is paged within **5 min** of detection.

### 8.3 Trade log, privacy notice, retention and erase-player

**Host responsibility (D26):** each lobby's host is responsible for its own data and erasure requests. The project does **not** operate a character/account database or receive gameplay, inventory or trade histories. The internet listing service does receive host addresses and lobby metadata (§11.4), so it is not described as collecting no personal data. **Privacy counsel must approve before any public release: [pre-release issue #20](https://github.com/Karyu42/endless-realm/issues/20).** This section is an implementation default, not a legal determination of grounds for retention.

**Mandatory host notice:** before authentication, profile creation, import or persistent connection logging, the join screen must show the host's notice. It names the operator and erasure contact, describes every category below, states the host's chosen retention values and any platform-level access logging, explains imports and device snapshots, states that a **ban survives erase-player** (the banned lobby key and expiry are kept until the ban expires) and that the import registry keeps a **pseudonymous** record of imported characters (a hash of the origin lobby and character id, kept for the lobby's lifetime and not removed by erase-player), and links the listing service's notice. The client sends no identity key or character snapshot until the player has read and accepted that notice. Network addresses necessarily reach the host to fetch it; the pre-notice path must not persist them. No notice, no join. Material changes require showing the notice again before play resumes.

**Trade log:** every window reaching one Lock writes one `trade_log` row (committed, rejected, failed, timed out or cancelled), with `trade_id`, UTC event timestamps, local profile and character IDs, mode, item IDs/tiers, amounts, NTV and result. Earlier cancellations produce identity-free counters only. Gameplay appends records; corrections append compensating records. A separate host maintenance path may purge/redact records for retention and erasure. Local-store transactions must retain the §8.2 atomicity and idempotency invariants; Postgres roles/partitions are not required.

**D14 retention defaults:** the table is authoritative and supersedes the earlier salted-hash/email design. Retention periods are maxima, purged at least daily; online data subject to erase-player is processed immediately. `trade_log_net` doesn't exist. No IP/device hashes, stable device master public key, email or passwords are stored in lobby data or application logs. A per-lobby authentication public key is an identity credential, **not** a device fingerprint.

| Category and scope | Retention default / allowed range | What `erase-player` does |
|---|---|---|
| Host-local profile, lobby authentication key, display name, wallets, gate counters, season progress/unlocks | While active; purge after 24 months of inactivity (host may shorten to 30 days) | Delete profile, key and name mapping, revoke live sessions, close trades and remove its balances and progression in a maintenance transaction |
| Characters, memorials, owned inventory/equipment and stash, pending/ground drops | Same as owning profile; tombstones expire 90 days after destruction unless needed for an active incident (≤ 72 h) | Delete owned saves and drops, remove names and owner/key links from tombstones. Already-traded items now owned by someone else remain; redact links that identify the erased profile |
| Ledger, grant/trade result and idempotency records | 24 months by default (3 days to 24 months). Older entries may be **compacted** into one opening-balance entry per wallet and currency, so balances still equal the ledger sum | Redact subject identifiers, keys, names and character/provenance mappings; preserve balanced numeric entries and anonymous operation IDs needed for remaining wallets and retry safety. No erased profile can reconnect to replay a grant |
| `trade_log` | 24 months by default, host-configurable **3 days minimum** through 24 months | Redact subject references and any names/provenance. Keep only transaction values, result and unlinkable local operation references until expiry; never claim pseudonymization alone guarantees legal anonymity |
| All-time and season leaderboard rows | While profile retained; old seasonal boards expire 24 months after season ends | Remove the profile's rows and displayed memorials immediately |
| Chat | In-memory only until disconnect or lobby shutdown; no transcript files | Drop buffered messages by that player. A client may have seen/copied them; the host cannot erase another person's copies |
| Host-admin, import, incident and revert audit rows | 90 days; host may choose 3–90 days (enough for the 72 h revert window) | Remove identifying actor/subject fields, names, identity keys and snapshot payloads; retain action, time, result and anonymous local references until expiry. Reverts for the erased subject are disabled |
| Import registry (§11.5): `origin_key` hash + import date only | Lifetime of the lobby | **Not removed** by erase-player or audit expiry. It is **pseudonymous**, not anonymous: anyone holding the character's export can recompute the hash and match it. It holds no profile link, player key, name or snapshot. Whether a lifetime retention is justified for it is for counsel to confirm under #20. A host-admin clear deletes one row and writes an identity-free audit entry |
| Ban entries | 90 days, host may choose 3–90 days; manual extensions require an audited reason | Keep only the banned per-lobby public key and the expiry, so the ban **survives the erase** and still works, and delete the name, reason text and profile link. That one retained key is flagged for counsel review in #20. There is no hidden device-fingerprint ban |
| Server / connection / error logs | Application logs are identity-free counters/error codes only, rotated within 7 days. IPs, identity keys, names and device hashes are never persisted | No player-specific application records remain to remove. Host proxy/OS logging must be disabled or redacted to the same policy, documented in the mandatory notice and tested; a third-party platform's separate policy requires privacy review |
| Host backups | Encrypted, local; expire within 30 days | Delete accessible per-profile exports immediately, queue redaction/deletion for backups and prevent restoration from reintroducing erased data. An erase journal is applied before any restored save goes online; expire the journal after the last affected backup is destroyed |
| Device's offline saves, key backup and exported character snapshots | Until the player deletes them; device-managed only | Host erasure cannot remotely delete them. The client offers "delete local copies" after the receipt; also erase files/backups manually. Restoring an old snapshot is a **new import**, subject to the receiving host's policy, never automatic recovery of an erased profile |
| Listing service: host endpoint/IP, host/lobby name and fingerprint, capacity/counts, mode/settings and portal summaries | Only current listing rows: expire **180 s** after last heartbeat; delete immediately on delist. No history, player identities or raw request logs retained by the application | Host operator delists that lobby. Player profile erasure has no listing player row to remove. Provider/edge telemetry and its retention must be disclosed and approved under #20 before the service is public |

**Erasure requests:** contact the lobby operator shown in the notice; listing removal requests go to the listing operator's published contact. The host's erase command runs even if its trade interface is paused and writes an identity-free receipt (request id, completion time, counts removed), not a fresh copy of the erased identifiers. Requests concerning other hosts, devices or copied exports must reach those holders separately. Imported provenance is a historical claim, not permission to keep personal identifiers indefinitely: retained items/records lose identifying mappings on erasure while keeping opaque local lineage needed for integrity. Immutable provenance means gameplay cannot rewrite history, not that privacy maintenance cannot redact it.

**Acceptance checks:** expiry and erase tests cover every row above. Import-registry rows: re-importing the same origin is still `ALREADY_IMPORTED` after the import audit row has expired and after the importer was erased; a Fallen copy and an offline-progressed copy are rejected the same way; a copy whose origin is this lobby gets `ALREADY_PRESENT` (original exists) or `REJECTED_ORIGIN_RETIRED` (original deleted or erased); an admin clear allows exactly one new import. Ban rows: rejoining after an erase with the same device secret is still banned, the ban lapses at its expiry, and a re-bind carries it to the new key. Also covered: trade/revert/idempotency invariants after redaction, backup restore after an erase, and log capture during a join proving that identity keys and raw network addresses are not persisted. The 3-day minimum supports the existing 72 h incident window; the dedicated incident journal, not a trade log alone, contains the undo state. No promise of GDPR compliance is made before #20 is signed off.

### 8.4 Trade value and limits
**⚠ Hosting:** account age and hours played are counted **per lobby** (time since the host-local profile was created in this lobby, hours in this lobby, §11.2). Hosts can turn the gate and cap off (§11.3).

**Normalized trade value (NTV):** the value one side gives away, in Glint at the giving character's **real** level `L` at commit time.

```
itemValue(T) = 40 × g(T)            (vendor price); cosmetic token = 100 NTV flat
NTV = round_half_up((Glint + 2 × EchoDust + 25 × m(L) × Riftstone + Σ itemValue) / m(L))
```

The fee doesn't count toward NTV. Dividing by `m(L)` keeps the limits meaningful at every level, and 1 NTV is about one on-level kill's worth of Glint. **Golden value:** at L=20, 500 Glint plus one T4 item is `(500 + 80) / 1.95 = 297.4` → **297 NTV**.

| Rule | Value |
|---|---|
| **Account-age gate:** can trade at all only after | account age ≥ 72 h **and** ≥ 5 h played **and** a character at level ≥ 10 **in the same mode** as the trade |
| **New-account daily cap:** applies while account age < 14 days **or** < 20 h played; it lifts only once **both** are met | ≤ 1,500 NTV given away and ≤ 20 committed trades per UTC day, **per account** across both modes |
| Cap enforcement | Checked at Lock ("Daily trade limit: X NTV left today") and again at commit (`REJECTED_DAILY_CAP`). Only committed trades count |
| Established accounts | No hard cap; anomaly review only (§8.5) |
| **Re-trade hold:** items and currency received in a trade | Can't be traded on for 1 h. Items: `hold_until` per `item_uid`. Currency: one held tranche per receipt (amount, expiry); tradeable balance = banked − unexpired holds. Held assets can still be spent (vendor, tier-up, fees), salvaged, equipped or stashed. Spending uses unheld currency first |
| Cooldown between trades (per character) | 5 s |
| **Trade fee (D9)** | `ceil(2% × Glint sent)`, so 1 Glint minimum whenever Glint > 0. Paid by the sender as a ledger entry to the sink inside the commit. Rejected with `INSUFFICIENT_FUNDS` if the tradeable balance < amount + fee. Item-only trades are free |

Test rows for the cap: a 15-day-old account with 10 h played is **capped**. A 10-day-old account with 30 h played is **capped**. A 15-day-old account with 25 h played is **uncapped**.

Gifts (one side empty) are allowed and count toward the giver's cap.

### 8.5 Abuse review (public summary)
**⚠ Hosting:** flags go to the lobby's host admin and bans are per lobby. Thresholds inside the open-source host software are effectively public, so v0.1 relies on host authority, not secrecy (§11.6, D27).

The server flags unusual activity into a human review queue. Examples include very one-sided trades, many new accounts sending to one account, a burst of newly created profiles that all trade into one account, and implausible earn rates. The only automatic actions are:
- hold the received assets of a flagged trade for up to 48 h (auto-released if nobody acts, with the flag kept on record);
- pause one account's trading pending review;
- the §8.2 freezes and kill switch.

Bans are human-only in v0.1 (D16). Thresholds, time windows and detection models live in the **private ops doc** and are not published here.

**[Later]** A market board (asynchronous listings), mail with attachments, and trade-velocity models.

Why: full currency trading means real-money traders will come. Server-side atomic trades shut out dupes. Gating new accounts and adding a short re-trade hold make bot-farm funnels slow and easy to see, while normal players never notice the limits.

## 9. Seasonal cosmetic track [v0.1, Season 0]

**⚠ Hosting:** season dates ship in the data pack (UTC). Sparks, the track and unlocks are per lobby, and per device for offline play; "account-wide" below means account-wide within one lobby's profile (§11.2, §11.6, D28).

- **Season:** 10 weeks. The track has 30 tiers, and each tier costs 200 **Sparks** (6,000 in total).
- **Sparks:** 1 per 10 kills (only kills with `E ≥ Le − 5` count), 20 per boss when eligible (§6.1), and +50 for the first dungeon clear each UTC day. That is about 250 Sparks per hour, so the full track takes about 24 h of play over 10 weeks. Sparks past tier 30, and unspent Sparks, are discarded at season end.
- **30 tiers (all cosmetic, no Prism in v0.1):** 2 class skins, 6 dyes, 3 portal trails, 2 emotes, 1 title, 6 nameplate frames, 4 projectile tints and 6 Hearth banners.
- **Account-wide unlocks:** cosmetics are unlocks for the whole account. Hardcore and Standard characters earn into the same track and can both use any unlock, since cosmetics carry no power.
- **Trading (D8):** a Standard character can convert an earned season unlock into a tradeable **cosmetic token** (an item with its own `item_uid`, 100 NTV). That removes the unlock until the token is redeemed. Tokens trade only in the Standard pool. Hardcore milestone and leaderboard cosmetics (§7.3) are account-bound and never tradeable.
- There is no paid premium track (D15).

**[Later] Prism** is a cosmetic-only currency, earned on later season tracks or bought in the cosmetic store. It is never tradeable and buys nothing that affects power.

## 10. Decisions (2026-11-23)

D1–D7, D17–D21, D23, D24 and D31 are Karyu's decisions (relayed by Chief of Staff; the D18/D23/D24 quotes are from Chief of Staff's chat as cited in the [PR #14 review](https://github.com/Karyu42/endless-realm/pull/14#pullrequestreview-6027324646); D31 is his later card answer relayed by Chief of Staff). D22 and D28–D30 are Chief of Staff rulings. D8–D16 and D25–D27 are design defaults accepted by Chief of Staff and can be tuned after playtests (D14 remains gated by privacy review). For D31, Chief of Staff approved per-lobby derived keys and export/backup as a concept. The specific choices (file format, mandatory passphrase, no recovery phrase, key derivation, KDF and cipher) are design/engineering defaults (Game Designer and Server Engineer, specified in `docs/tech/stack.md` via [PR #26](https://github.com/Karyu42/endless-realm/pull/26)).

| # | Decision |
|---|---|
| D1 | Both death modes ship in v0.1: Standard (soft death) and Hardcore (permadeath) with a separate economy, trading pool and leaderboard (§7). |
| D2 | Portal multiplier is 0.5–1.5 in v0.1. Later it is raised by clearing at your current max, up to a hard cap of 3.0. |
| D3 | Full player trading, currency included, with anti-RMT and anti-dupe safeguards (§8). |
| D4 | Cosmetics can also be earned through a small seasonal track (§9). |
| D5 | Shard (server-instance) multiplier is a later phase. v0.1 has the portal multiplier only. |
| D6 | Stride (movement speed) and Tempo (fire rate) are fixed per class, with at most +10% from gear in total. |
| D7 | The overgear clamp stays at on-level tier + 3 (§4.1). |
| D8 | *Default, tunable after playtests.* Prism and paid cosmetics are account-bound and never tradeable. Earned cosmetics are tradeable (§8, §9). |
| D9 | *Default, tunable after playtests.* Trade fee is 2% of Glint transferred, paid by the sender. Item-only trades are free (§8.4). |
| D10 | *Default, tunable after playtests.* Re-trade hold is 1 h at launch. Raise it to 24 h only if funnel or lopsided flags show RMT at scale (§8.4). |
| D11 | *Default, tunable after playtests.* Trading gate is 72 h account age + 5 h played + a level-10 character in the same mode. The new-account cap is 1,500 NTV/day and 20 trades/day per account. It lifts only once the account is ≥ 14 days old **and** has ≥ 20 h played. Review the flag data after 2 weeks (§8.4). |
| D12 | *Default, tunable after playtests.* On hardcore death, equipped gear, inventory and pending loot are tombstoned. The hardcore stash and wallets survive (§7.3). |
| D13 | *Default, tunable after playtests.* Fallen hardcore characters remain as memorials only, with no conversion to Standard (§7). |
| D14 | *Default, subject to pre-release privacy review #20.* Per-lobby trade-log retention defaults to 24 months, configurable from 3 days to 24 months. No IP/device hashes or email; mandatory notice, per-category erasure and retention are in §8.3. |
| D15 | *Default, tunable after playtests.* No paid premium season track. Paid cosmetics are sold only as separate store items (§9). |
| D16 | *Default, tunable after playtests.* Enforcement in v0.1 uses automatic holds and pauses only. Bans are human-only. Revisit once flag precision has been measured (§8.5). |
| D17 | No official servers for now: offline solo and player-hosted lobbies only (§11). |
| D18 | The host sets the lobby's max players, default 50 (§11.3). Karyu: "solo and player lobbies, let players decide on a max player count, defaulted to 50." The 1–50 **ceiling** is a provisional engineering/design limit, not his decision, until the 50-player load test passes (`stack.md`). |
| D19 | The lobby browser shows the multipliers of open portals; with more than 5 open it shows at least the 2 lowest and 2 highest (§11.4). |
| D20 | Enemy scaling is dynamic with the players in range and stays at the peak count reached during an encounter (§3.5). |
| D21 | Offline characters aren't tracked but are flagged, and lobbies can disable them (§11.7). |
| D22 | *Chief of Staff ruling.* Discovery: LAN, invite code and direct address first, then a Cloudflare Workers listing-only service planned for the free tier; any paid tier needs Karyu's approval (§11.4). |
| D23 | Characters live on the lobby that created them. Other lobbies may import them if the receiving host allows it, offline and lobby characters alike (§11.5). Karyu: "the character initially lives on the server they were created on and can be imported if allowed on the other server". |
| D24 | The host is the Godot game (listen server or `--headless`); Go is a reference/test harness only. Karyu: "since we use godot anyway why not that one?" |
| D25 | *Default, tunable after playtests.* Offline-flagged characters earn normally but never appear on leaderboards and can't trade with non-Offline characters (§11.7). |
| D26 | *Default, tunable after playtests.* Hosts are responsible for their own lobby's data: a mandatory pre-join privacy notice, per-category retention and `erase-player` (§8.3), and no IP or device hashes. Public release is gated on privacy counsel review, [issue #20](https://github.com/Karyu42/endless-realm/issues/20). |
| D27 | *Default, tunable after playtests.* Leaderboards and bans are per lobby. Anti-cheat relies on host authority, not secret thresholds (§11.6). |
| D28 | *Confirmed decision via CoS.* Seasons and cosmetic unlocks are per lobby (per device offline); no paid cosmetics in v0.1 (§11.6). |
| D29 | *Confirmed via CoS; also recorded in `docs/tech/stack.md` (Mobile).* Desktop and headless hosting first. Android is join-only in v0.1; no Android-host default. |
| D30 | *Confirmed via CoS.* Host admin replaces Economy Ops/on-call within each lobby. D1 (both death modes, separate economies) and D3 (full trading, currencies included) are reaffirmed; trading and the anti-RMT gate default **ON**. |
| D31 | Identity: a device key, an account (host-local profile) per lobby, no email or password and no central account service. Karyu, on a card relayed by Chief of Staff: "Identity: device key, an account per lobby, no email or password and no central account service for now". *Approved by Chief of Staff as a concept:* per-lobby keys derived from a device-held secret, plus export and backup. *The specific choices are design/engineering defaults (Game Designer and Server Engineer, specified in `docs/tech/stack.md` via [PR #26](https://github.com/Karyu42/endless-realm/pull/26))* (§11.2). |

**Tuning ownership:** Design decides tuning numbers (rates, caps, costs, timers, curves) and records them here. They are escalated to Karyu only when a change would alter the game's direction or touch money (monetization, pay-to-win boundaries, real-money flows).

## 11. Hosting model: offline solo and player-hosted lobbies [v0.1]

Decisions (2026-11-23, D17–D24, D29 and D31; credits in §10): **there are no official servers for now.** The game runs in two ways:
- **Offline solo:** the client's in-process sim (`LocalSim`, `stack.md`), with no network and no tracking. `n_peak` is always 1. The device acts as its own host for saves (§11.5).
- **Player-hosted lobbies:** a player hosts with the **Godot game itself**, either as a listen server inside their client or as the same export run `--headless` (D24, `docs/tech/stack.md`). Solo and hosted play run the same GDScript sim, rules and `data/` pack. A lobby is one Hearth, one Wilds and its portal instances.

Everything in this doc that said "the server" now means **the lobby's host**. Its authority against clients is unchanged: the host still validates movement, hits, loot and XP (§8.2, `stack.md`). Nobody validates the host itself. Sections that assumed one trusted official server are marked **⚠ Hosting** and reconciled in §11.6.

### 11.1 Trust model
- **Host-authoritative per lobby.** Each lobby is its own world, with its own profiles, characters, stash, wallets, ledger, trade log, leaderboards and season progress, all stored by the host. Lobbies share only the game version and data pack.
- **A lobby is exactly as trustworthy as its host.** The host can edit its own save. The game never calls a character "verified". It only says where the character was recorded (§11.5 provenance), and the lobby browser says so plainly (§11.4).
- **Version lock:** a client can join only a lobby with the same protocol version and `data/` pack hash. Hosts can't change formulas or tuning in v0.1. **[Later]** Modded or custom-rule lobbies, shown with their own badge.

### 11.2 Identity: device keys and host-local profiles (D31)
Karyu's decision: "Identity: device key, an account per lobby, no email or password and no central account service for now". Chief of Staff approved per-lobby derived keys and export/backup as a concept. The specific choices below are design/engineering defaults (Game Designer and Server Engineer, specified in `docs/tech/stack.md` via [PR #26](https://github.com/Karyu42/endless-realm/pull/26)). The crypto parameters live in `stack.md` (Identity) and aren't repeated here.

- **No email, no password, no central account.** Each device creates and keeps a secret identity root. For every host it joins, the client derives a **separate per-lobby Ed25519 key pair** from that root and the host's full `host_id`: `HKDF-SHA256(root, info = "er-lobby-id-v1" ‖ host_id)`, with `host_id` as its 32 raw fingerprint bytes, gives the Ed25519 seed for that lobby. The root is 32 random bytes. Output lengths and test vectors are in `stack.md`. Different hosts therefore see unrelated player keys. Only that **per-lobby public key** leaves the device; the root/master public key is never sent. Authentication uses a fresh, single-use host nonce bound to the host identity/session, signed with that lobby key. No global player identifier is used.
- **Joining a lobby:** after the mandatory pre-join notice (§8.3), the host checks the signature and creates a **host-local profile** on first successful join. It owns that lobby's account-level state (wallets per mode, stash, cosmetic unlocks, trade gate counters) and characters. The display name is unique within the lobby. The UI uses a short fingerprint for display, but authorization compares the full key/fingerprint, never the shortened label.
- **Hosts have keys too.** Each host installation has a stable key pair; `host_id` is the **full SHA-256 fingerprint of its public key**. Short forms are display-only. Clients pin it on first connection and warn on a change; address or lobby-name changes don't create a new profile. A new host key is a different identity unless the client explicitly trusts an authenticated migration.
- **Linkability:** unrelated hosts see different player authentication keys. Display names, network addresses, a shared host impersonating several lobbies, and voluntarily exported character provenance can still link activity. The pre-join/import notice explains that; the game does not promise anonymity. Character exports carry source-lobby provenance, never the device root or player authentication keys. Identity backup files are separate (§11.2 Key export and backup).
- **Key export and backup (D31; concept approved by Chief of Staff, specifics are design/engineering defaults):**
  - **What is exported:** one backup file holding only the device's secret identity root, a format version and the creation date. There is **no recovery phrase** (no mnemonic or word list) in v0.1; the file is the only backup. That is enough to re-derive every per-lobby key, because they are derived from the root and each `host_id`. The file contains no profiles, characters, host list or per-lobby keys. Lobby data stays on each host.
  - **Encryption (mandatory):** the file is always encrypted with a passphrase the player chooses, and there's no unencrypted export option. The key comes from Argon2id and the cipher is XChaCha20-Poly1305 (authenticated, so a wrong passphrase or a tampered file fails cleanly). The Argon2id cost parameters, salt and nonce sizes, file layout and test vectors are defined in `docs/tech/stack.md` (Identity), which is the single source for them. The game never stores or uploads the passphrase or the file, and there's no cloud copy.
  - **User-initiated only:** export runs only when the player picks "Export identity" in settings and confirms. Nothing is backed up automatically. Importing the file on another device replaces or adds that device's root only after an explicit confirmation, and that device then reaches the same profiles in every lobby.
  - **No backup, no recovery:** losing the device (or the root) without an export loses the identity. There is no central account to recover it from. The client warns about this on first launch and before an uninstall/reset where the platform allows it.
  - **Admin re-bind:** the only fallback is per lobby. A host admin can re-bind a profile to a new public key in their own lobby, and each re-bind writes an audit row (old key, new key, admin, reason).
  - **Bans carry over:** if the old key is banned, the new key gets the same ban and expiry in the same transaction. The old key stays banned too, so a re-bind can't be used to dodge a ban.
- **"Account" in §7–§9** means the host-local profile in that lobby. That includes account age and hours played (§8.4).

### 11.3 Host lobby settings
Set by the host when the lobby starts. Fields marked *live* can change while it runs; the rest need a restart.

| Setting | Range | Default | Notes |
|---|---|---|---|
| Lobby name | 3–32 characters | "<host name>'s lobby" | Shown in the browser |
| Password | optional, 0–64 characters | none | Shown as a lock icon. The password is never listed |
| Mode | Standard or Hardcore | Standard | One mode per lobby. Hardcore lobbies are the separate realm of §7.3 |
| **Max players** | **1–50** | **50** (desktop / `--headless`) | The ceiling of 50 is **provisional** until the 50-player load test passes (`stack.md`); if it fails, the ceiling drops to the tested value; Android is join-only for v0.1 (later CoS ruling, D29), with no Android-host default. *Live:* lowering it never kicks anyone, it only blocks new joins. It also caps every portal instance (§6.1 rule 5) |
| **Allow imported characters** | on / off | on | *Live.* Whether characters created elsewhere (another lobby or offline solo) can be imported into this lobby (§11.5) |
| **Allow Offline-flagged characters** | on / off | on | *Live.* Applies to imports whose `played_offline` flag is set. Only matters while imports are on. Turning it off blocks new imports of flagged characters; flagged characters already in the lobby stay |
| **Allowed multiplier range** | `M_min` to `M_max` in hundredths, each in `[50, 150]`, step 5, `M_min ≤ 100 ≤ M_max` | 50 to 150 (the full v0.1 range) | *Live* for new portals. Validate the global step/range first (`INVALID_MULTIPLIER`), then the host range (`MULTIPLIER_NOT_ALLOWED`). The latter is an **additive protocol enum value**, not a renumbering; old peers must not treat it as a success. 1.00 must stay in range, because found portals (§6) are always M = 1.00 |
| Listing | internet (listing service), LAN only, or invite-only | internet | Invite-only lobbies appear in no browser. LAN-only lobbies are never sent to the listing service |
| Trading | on / off | **on** (D30) | *Live.* Off rejects new trade windows and cancels open ones |
| Trading gate and daily cap (§8.4, anti-RMT) | on / off | **on** (D30) | *Live.* The thresholds themselves are fixed by the data pack |

The host also has a **host admin** role for kicks, bans, freezes, incident windows, reverts and profile re-binds in that lobby. By default that is the host's own profile, and it can grant the role to others.

### 11.4 Lobby browser and discovery (D22)
**Sources, in v0.1 order (D22):** LAN, invite code/direct address first; the internet listing follows. These first discovery paths are one initial milestone, not a claim that a code-only build must precede LAN. The internet listing (the Cloudflare Workers directory) is in scope for v0.1 under D22, after LAN and code/direct address. Relay and NAT punch-through are out of scope; the service details are in `docs/tech/stack.md` (Discovery). UPnP/manual port forwarding may make a host reachable; a code is not a gameplay relay or NAT-punch guarantee.

**Sources:**
1. **LAN discovery:** hosts on the same network announce themselves by broadcast. Rows refresh live, at least every 5 s.
2. **Invite code and direct address:** the player enters a code or `host:port`, and the client queries that host directly. Saved and recent lobbies are re-queried the same way.
3. **Internet listing service:** a listing-only service on **Cloudflare Workers**, planned to run in the **free tier**. Moving to any paid tier needs Karyu's approval first.
   - **Listing only:** it stores one row per internet-listed lobby (the row fields below plus the host's reachable address or invite code). It stores no player profiles, characters, player identity keys, chat or game state, and it never relays gameplay traffic.
   - **Request budget:** at the time of writing, Workers Free allows 100,000 requests per day ([Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/), checked 2026-11-23). To stay inside that, a host heartbeats every **60 s** and a row expires **180 s** after its last heartbeat. A client fetches the list when the browser opens and on manual refresh, at most once per **30 s**. Live details (ping, players, portal chips) for visible rows come straight from each host, not from the service. When the daily budget runs out, the service rejects requests and clients fall back to LAN, codes and saved lobbies. It never upgrades itself to a paid tier.
   - The Server Engineer owns the implementation and its storage choice, which must also fit the free tier.

**Row fields (one row per lobby, the same whatever the source):**

| Field | Content |
|---|---|
| Name and host | Lobby name, host display name, host fingerprint |
| Mode | Standard / Hardcore badge |
| Players | `current / max` (e.g. `12 / 50`). A full lobby shows "Full" and its join button is disabled |
| Imports | "Imports OK", "No Offline" (imports on, Offline-flagged off) or "No imports" |
| Multiplier range | The host's allowed range, e.g. `×0.50–×1.50` |
| **Open portals** | Count, plus up to 5 portal chips (rule below). Each chip shows `×M` and the content level `E`, e.g. `×1.25 · E 25`. Found portals have a small "found" mark |
| Ping | Measured by the client, in ms |
| Lock | Lock icon if a password is set |
| Source | LAN / code / saved / internet icon |
| Version | Hidden when it matches. A mismatched lobby is greyed out with "Different version" |
| Trust note | Every row's tooltip: "Hosted by a player. Progress here is recorded by this host only." |

**Open portal:** a portal instance in that lobby whose entrance still accepts entries (within 120 s of creation and not at the player cap, §6.1 rule 8). It drops off the list as soon as its entrance closes.

**Chip selection rule.** Let `N` be the number of open portals, sorted by **M100 ascending**, then **E ascending**, then **creation time ascending**, then **portal id ascending**. This order is the tie-break everywhere.
- `N ≤ 5`: show all `N` chips in that order.
- `N > 5`: show **exactly 5 chips**, left to right: positions `0` and `1` (the 2 lowest), position `floor((N − 1) / 2)` (the median), and positions `N − 2` and `N − 1` (the 2 highest). Then add a "+`N − 5` more" chip. For `N ≥ 6` these five positions are always distinct. Clicking the row expands the full sorted list.
- Equal multipliers are separate chips, so two portals at ×1.25 can both show.
- Example: open portals at ×0.50, ×0.80, ×1.00, ×1.00, ×1.20, ×1.35, ×1.50 (N = 7) → chips ×0.50, ×0.80, ×1.00 (position 3), ×1.35, ×1.50, "+2 more".

**Sorting the list:** joinable first (compatible version, not full), then ping ascending, then players descending, then lobby name A–Z. The player can instead sort by players, ping, name, or highest open M (the last chip).

**Filters:** mode, hide full, hide password-protected, "accepts my character" (imports on, plus Offline allowed if the character is flagged), and "has an open portal in my M range".

### 11.5 Characters: where they live, provenance and import (D23)
- **Where a character lives:** a character lives on the lobby that created it, stored by that host. A character created in offline solo lives on that device. Nothing is ever "the" global copy, and no host owns a character anywhere except in its own save.
- **Immutable provenance.** Every character carries a provenance block that the creating host writes once and no later host may change:
  - `origin_host_id` (the creating host's fingerprint, or the device's for offline solo) and `origin_character_id`, the UUIDv7 it had there;
  - `origin_lobby_name` (the creating lobby's display name), `created_at`, `mode` and `class`;
  - `played_offline`, the Offline flag (§11.7). It is set when the character is created in offline solo, or when a copy is imported into offline solo. It is never cleared, and it is copied into every later copy;
  - `import_chain`, an append-only list of `(source_host_id, source_lobby_name, host_id, local_character_id, imported_at)`, one entry per import. The latest entry names the **source lobby** the copy came from. Lobby names aren't globally unique, so the UI always shows the host fingerprint beside them.
- **Export:** a player can export a character's snapshot from the lobby where it lives, at that lobby's Hearth. The host signs the snapshot with its host key. That signature only shows which host issued the snapshot and that nothing changed in transit; it proves nothing about how the character was earned. Offline solo has its own host key on the device (its `host_id` is the offline origin), and offline exports are signed with it. That key is shared by every export from that device, which is part of the voluntary-export linkability noted in §11.2.
- **Import is a copy, never a move.** Importing creates a **new, independent character** in the receiving lobby. Nothing happens to the source copy, which keeps existing where it lived. Neither host is told about, coordinates with or answers to the other.
  - There are **no cross-host transactions or guarantees.** Copies of one character can exist in several lobbies at once and diverge freely. Each lobby's economy is separate (§11.1), so these copies don't duplicate anything inside any one lobby.
  - **What the copy carries:** class, mode, level, XP, and the snapshot's equipped and inventory gear and cosmetic tokens. It doesn't carry pending loot (snapshots are taken in the Hearth, after banking), the source profile's stash or wallets, Sparks, cosmetic unlocks or leaderboard history. Those are profile state in the source lobby. *Design default, tunable after playtests.*
  - **New ids on arrival:** the receiving host mints fresh `item_uid`s for every carried item (provenance reason `IMPORTED`) and writes one audit row per import. Imported items stay subject to the §8.4 re-trade hold, which starts at import.
  - **Idempotent import per origin character per lobby.** A lobby accepts a given `(origin_host_id, origin_character_id)` once, across all its profiles.
    - **Import registry:** each accepted import stores one row: `origin_key` plus the import date (UTC day). It holds no profile, player key, name, lobby name or snapshot. The record is **pseudonymous**: the hash is unsalted, so anyone with the export can link it.
      - **Encoding:** `origin_key = SHA-256(input)`. The input is exactly 61 bytes: the ASCII bytes `er-import-v1` (12 bytes), one `0x00` byte, `origin_host_id` as its **32 raw bytes** (not hex), and `origin_character_id` as the UUIDv7's **16 raw bytes** in RFC 9562 network (big-endian) byte order. Every field has a fixed length, so the concatenation is unambiguous without delimiters or length prefixes. Text forms in a snapshot (hex or canonical UUID) are decoded first; a wrong length or a malformed value gives `REJECTED_INVALID`. The host stores the 32-byte digest raw and shows it as 64 lowercase hex characters in logs and tests.
      - **Test vector:** `origin_host_id` = SHA-256 of the ASCII bytes `er-test-host-key` = `d2ed0c4430d0dcf7d2303562e886e89ecc95c769d763cf79674c2093f3512b36`, and `origin_character_id` = `01936f4e-8a2b-7c3d-9e4f-0123456789ab`. The result is `origin_key` = `1202198c4d29f9914372a6717a5e3c537924cb271d11979cf60c903966e95ad3`. It lives as long as the lobby, and neither audit expiry nor erase-player removes it (§8.3). Only a host-admin clear deletes a row, and that writes an identity-free audit entry.
    - **Rejection:** importing the same origin again is rejected with `ALREADY_IMPORTED`. This also covers a copy that died (a Fallen hardcore copy) and a copy that went through offline play and came back with `played_offline` set. Every copy keeps its origin pair, so all of them stay blocked until an admin clears the row.
    - This stops repeated imports of the same snapshot from multiplying items inside one lobby.
  - **Importing back into the origin lobby:** if a snapshot's `origin_host_id` is this lobby's own `host_id`, the import is always rejected.
    - `ALREADY_PRESENT` when the original character still exists here, alive or as a memorial.
    - `REJECTED_ORIGIN_RETIRED` when no character with that `origin_character_id` exists here, whether it was deleted, erased or is simply unknown.
    - **Why one code for unknown ids:** after an erase the host keeps no record of the erased character, so it can't tell "erased" from "never existed". It shouldn't keep a tombstone just to tell them apart, since that would be retained personal data. A snapshot that verifies against this lobby's own host key was issued here, so an unknown id means it was retired, or that the host key was compromised; neither case should re-create a character. A separate code would also act as an oracle for whether an id was erased.
    - The original already lives in this lobby, so a round-trip copy would duplicate its gear, and a returning copy could undo a deletion, an erasure or a hardcore death. The host-admin clear doesn't apply to this rule.
- **Checks on import (receiving host):** the version and data-pack hash match; imports are allowed (§11.3), and Offline-flagged ones too if the flag is set; the mode matches the lobby (**Hardcore → Hardcore only; Standard → Standard only**, never conversion); the character isn't Fallen (memorials can't be imported); the signature verifies against the key named in the snapshot; and the snapshot is well-formed: schema, item ids, and levels, tiers and stats consistent with this data pack's formulas. Signing proves issuance, not honest earning; a dishonest host can forge reachable values. Authenticate the receiving profile and bind the new copy to it; an export is a portable bearer copy, not proof of global ownership. Result codes: `IMPORTED`, `REJECTED_IMPORTS_OFF`, `REJECTED_OFFLINE_OFF`, `REJECTED_VERSION`, `REJECTED_MODE`, `REJECTED_FALLEN`, `REJECTED_SIGNATURE`, `REJECTED_INVALID`, `ALREADY_IMPORTED`, `ALREADY_PRESENT` or `REJECTED_ORIGIN_RETIRED`. Any result except `IMPORTED` changes nothing. **Check order:** the host runs the checks in this order and returns the first failure, so every snapshot gets exactly one code.
  1. `REJECTED_IMPORTS_OFF`
  2. `REJECTED_VERSION`
  3. `REJECTED_INVALID`
  4. `REJECTED_SIGNATURE`
  5. Origin is this lobby: `ALREADY_PRESENT` or `REJECTED_ORIGIN_RETIRED`
  6. `REJECTED_OFFLINE_OFF`
  7. `REJECTED_MODE`
  8. `REJECTED_FALLEN`
  9. `ALREADY_IMPORTED`
  10. Otherwise, `IMPORTED`.

  The origin rule comes before `REJECTED_FALLEN`, so a memorial snapshot from this lobby gets `ALREADY_PRESENT` (its memorial is still here) or `REJECTED_ORIGIN_RETIRED` (the memorial was deleted or erased), never `REJECTED_FALLEN`. A Fallen snapshot from another lobby gets `REJECTED_FALLEN` before the registry check, so it gets that one code even if the same origin was imported earlier. **Proto plan:** these are design names. When they enter `proto/v1` (the future host-lobby protocol PR, see `docs/tech/stack.md`), they form their own `ImportResult` enum with an `IMPORT_RESULT_` prefix: `IMPORT_RESULT_UNSPECIFIED = 0`, then `IMPORT_RESULT_IMPORTED`, `IMPORT_RESULT_REJECTED_MODE`, `IMPORT_RESULT_ALREADY_IMPORTED`, `IMPORT_RESULT_ALREADY_PRESENT`, `IMPORT_RESULT_REJECTED_ORIGIN_RETIRED`, and so on, additive only. That way they can't collide with join or portal codes such as `INVALID_MULTIPLIER` or `MULTIPLIER_NOT_ALLOWED`.
- **After import, the copy is a normal character of that lobby.** It plays, trades and ranks like a character created there. The only exception is the Offline flag's limits (§11.7). The receiving host's import setting is the gate, and there are no extra "imported" restrictions.
- **Hardcore copies:** permadeath applies per copy. A copy that dies is Fallen in that lobby only.
- **Where provenance shows:** on the character sheet ("Imported from <source lobby name> · <source host fingerprint> · <date>", plus "Created on <origin lobby name>" when that differs), character select, player-list details and the trade window. This is provenance, not a restrictive Imported badge.

### 11.6 Reconciling what assumed an official server

| Section | Assumed before | v0.1 position | Basis |
|---|---|---|---|
| §8.2 Ledger, item table, anti-dupe | One central Postgres | The **invariants**, scoped per lobby in the host's save (`stack.md`: host-local store, one writer, idempotent grants). Database-specific Postgres roles/isolation language in §8.2 is historical; implement atomic one-writer commits with the same retry/rollback results locally. Retention/erasure exceptions in §8.3 override any "never deleted" wording. Dupe-safety holds against clients; a host can still edit its own data. Imports mint new `item_uid`s (§11.5). Freezes, the kill switch and clearing them move from on-call/`econ_admin` to the lobby's **host admin** | D23 |
| §8.3 Trade log, retention, GDPR | Project-wide logs and email/hash-based erasure | Mandatory notice and host-local per-category retention/erasure in §8.3. No IP/device hashes. Listing metadata is collected separately, expiring after 180 s. Public release blocked on [#20](https://github.com/Karyu42/endless-realm/issues/20) | D26 |
| §8.4 Account-age gate, new-account cap | Central account age and hours | **Per lobby:** account age is the time since the profile was created in *this lobby*, and hours played are hours *in this lobby*. Same thresholds (D11). Hosts can turn the gate off (§11.3) | D24 |
| §8.5 Abuse review, D16 | Central review queue and private ops doc | Flags go to the lobby's host admin, and bans are per lobby. The host software is open source and runs on players' machines, so any detection threshold it contains is effectively public. v0.1 relies on host authority over clients (§8.2, `stack.md`), not on secret thresholds. The private ops doc covers only official services such as the listing service | D27 |
| §7.3 Hardcore leaderboard | One global board | **Per-lobby boards only**, labelled with the lobby name. Offline-flagged characters are never listed | D25, D27 |
| §7.3 Incident windows and reverts | On-call ops | Automatic windows still open when the host's sim crashes, restarts or stalls (same triggers). Manual windows, extensions and reverts are done by the host admin, with the same audit rows | — |
| §6.1 Party cap 8, n snapshots | 8-player instances; n fixed at room activation and arena seal | Instance cap = the lobby's max players. Scaling uses `n_peak` (§3.5) | D18, D20 |
| §9 Seasons and cosmetics | Central season service; account-wide unlocks | Season dates ship in the data pack (UTC), so every lobby and offline play share Season 0's dates. Sparks, the track and unlocks are **per lobby** (per device offline). Cosmetic tokens trade only inside their lobby; one carried in an import is a new token there. No paid cosmetics | D28 |
| `stack.md` | Official Go server + Postgres; email + password | Godot host (Go = reference/test harness, D24). Identity is D31: a device key, an account per lobby, no email/password and no central account service. It uses per-lobby HKDF-derived Ed25519 keys and a mandatory passphrase-encrypted backup file, with no recovery phrase (§11.2); the crypto parameters live in `stack.md` (Identity). Android is join-only in v0.1 (D29). The internet listing is in scope (D22). `stack.md` is owned by the Server Engineer; this doc doesn't edit it | D24 |

**Hosting platforms (latest ruling, D29):** desktop listen servers and desktop `--headless` hosts ship first. Android is **join-only in v0.1**, not a listen host. `docs/tech/stack.md` agrees; its phone-host default of 8 applies only after v0.1. A web-export client cannot host either. The Godot shared sim remains authoritative; existing Go code is a reference/test harness, not the live gameplay host.

### 11.7 Offline flag (`played_offline`)
- **What it is:** a permanent per-character provenance flag (§11.5). It is set on every character created in offline solo and on any copy imported into offline solo. It is never cleared, because no host can vouch for state the offline sim produced. The UI calls it "Offline".
- **Not tracked:** offline characters live only on the device. Nothing about them is recorded anywhere else until a copy is imported into a lobby.
- **Where it shows:** an "Offline" badge on the nameplate, in the lobby player list, in the trade window, on the character sheet and on character select. The lobby browser shows whether a lobby accepts flagged imports (§11.4).
- **What it can't do (D25):**
  - It never appears on any leaderboard, and its hardcore milestones give no cosmetics.
  - It can't trade with non-Offline characters. Trades between two Offline characters are allowed wherever trading is on.
- **What it can do:** everything else: play, join portals, earn loot, XP and Sparks normally, and count toward `n_peak` like anyone.
- Offline hardcore is on the honor system, since offline play can't be audited. Permadeath still applies to a flagged hardcore copy inside a lobby.

## 12. Hosting decisions and defaults (2026-11-23)

These come from Karyu's answers and Chief of Staff's rulings on the §12 questions in the first version of this PR. They are recorded as D22–D31 in §10.

- **D22, Discovery (Chief of Staff ruling):** LAN, invite code and direct address first, then an internet listing-only service on Cloudflare Workers, planned for the free tier. The internet browser is in scope. Any paid tier needs Karyu's approval first (§11.4).
- **D23, Characters (Karyu):** a character lives on the lobby that created it. Other lobbies may import it if the receiving host allows it, and that applies to offline and lobby characters alike. Import permission is set per host. Import is a copy with immutable provenance and no global ownership (§11.5).
- **D24, Host (Karyu):** the host is the Godot game, as a listen server or `--headless`. Go is a reference/test harness only.
- **D25, Offline characters (design default, accepted by CoS):** they play and earn normally, but never appear on leaderboards and can't trade with non-Offline characters (§11.7).
- **D26, Player data (design default, accepted by CoS):** each host is responsible for its own lobby's data, with a mandatory notice, per-category retention and erase-player (§8.3). No IP or device hashes.
- **D27, Competition and enforcement (design default, accepted by CoS):** leaderboards and bans are per lobby. Anti-cheat relies on host authority over clients, not secret thresholds (§11.6).
- **D28, Seasons/cosmetics (CoS ruling):** seasons and unlocks are per lobby and per device, with no paid cosmetics (§11.6).
- **D29, Hosting platforms (CoS ruling):** desktop/headless first; Android join-only in v0.1. This is later than, and differs from, #14's Android-host default.
- **D30, Modes/trading/admin (CoS ruling):** D1 and D3 stand; the host admin replaces Economy Ops. Trading and the anti-RMT gate are **ON** by default (§11.3).
- **Public-release gate:** privacy counsel review in [pre-release issue #20](https://github.com/Karyu42/endless-realm/issues/20) must be completed before any public release. This doc does not resolve it.

- **D31, Identity (Karyu):** "Identity: device key, an account per lobby, no email or password and no central account service for now". Chief of Staff approved per-lobby derived keys and export/backup as a concept. The specifics (a mandatory passphrase-encrypted file, no recovery phrase, HKDF derivation, Argon2id + XChaCha20-Poly1305) are design/engineering defaults (Game Designer and Server Engineer, specified in `docs/tech/stack.md` via [PR #26](https://github.com/Karyu42/endless-realm/pull/26)) (§11.2).

**No open questions.** Everything in §11 is a decision or a tunable design default. The import rules in §11.5 (what a copy carries, new item ids, the import registry) don't change direction or money.

## Appendix A. Group scaling curve, n = 1…50

`s100(n)` from §3.5 (divide by 100 for the multiplier). Normal: k 60, t 30. Boss: k 75, t 38.

| n | normal | boss | n | normal | boss | n | normal | boss | n | normal | boss | n | normal | boss |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 100 | 100 | 11 | 610 | 739 | 21 | 910 | 1119 | 31 | 1210 | 1499 | 41 | 1510 | 1879 |
| 2 | 160 | 175 | 12 | 640 | 777 | 22 | 940 | 1157 | 32 | 1240 | 1537 | 42 | 1540 | 1917 |
| 3 | 220 | 250 | 13 | 670 | 815 | 23 | 970 | 1195 | 33 | 1270 | 1575 | 43 | 1570 | 1955 |
| 4 | 280 | 325 | 14 | 700 | 853 | 24 | 1000 | 1233 | 34 | 1300 | 1613 | 44 | 1600 | 1993 |
| 5 | 340 | 400 | 15 | 730 | 891 | 25 | 1030 | 1271 | 35 | 1330 | 1651 | 45 | 1630 | 2031 |
| 6 | 400 | 475 | 16 | 760 | 929 | 26 | 1060 | 1309 | 36 | 1360 | 1689 | 46 | 1660 | 2069 |
| 7 | 460 | 550 | 17 | 790 | 967 | 27 | 1090 | 1347 | 37 | 1390 | 1727 | 47 | 1690 | 2107 |
| 8 | 520 | 625 | 18 | 820 | 1005 | 28 | 1120 | 1385 | 38 | 1420 | 1765 | 48 | 1720 | 2145 |
| 9 | 550 | 663 | 19 | 850 | 1043 | 29 | 1150 | 1423 | 39 | 1450 | 1803 | 49 | 1750 | 2183 |
| 10 | 580 | 701 | 20 | 880 | 1081 | 30 | 1180 | 1461 | 40 | 1480 | 1841 | 50 | 1780 | 2221 |
