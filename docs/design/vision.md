# Endless Realm: Design Vision (v0.1)

Status: draft for review · Owner: Game Design · Scope: first playable slice

Endless Realm is a co-op, top-down bullet-hell MMO. It has no level cap and gear tiers that never stop. Everything except cosmetics can be earned in game, so there is no pay-to-win. Every name, asset and line of text is original. Nothing is taken from any existing game.

All formulas are the source of truth. Tables only illustrate them. All numbers are starting values for tuning. Put them in config, not in code.

Companion docs: base stats for v0.1 enemies, the Tallow Warden, the Wilds ring layout and projectile speeds live in [`docs/design/content-v0.1.md`](content-v0.1.md) (separate PR, branch `design/content-v0.1`). The engine, netcode and persistence choices are in [`docs/tech/stack.md`](../tech/stack.md). Detailed anti-cheat and anomaly-detection thresholds live in a **private ops doc** (owned by Economy Ops) and are deliberately not in this public repo.

Legend: **[v0.1]** is in the first playable slice. **[Later]** is a later-phase idea, written down so v0.1 doesn't block it.

---

## 1. Core loop

1. **[v0.1]** Spawn in **the Hearth**, a safe hub with a vendor, a stash and a portal board.
2. Step into **the Wilds**, a shared open zone in rings. Enemy level rises from the edge (level 1) toward the center (top ring = base level 20 in v0.1; ring count, widths and levels are in `content-v0.1.md`).
3. Dodge bullet patterns, kill enemies, and earn XP, Glint and gear drops.
4. Find or open a **portal** to a dungeon instance (v0.1 has one dungeon, **the Hollowmere Vault**, with one boss, **the Tallow Warden**). The opener sets the level multiplier (§6).
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
| **Glint** (common) | Every kill: `ceil(m(E))` per eligible player, boss ×30; selling gear: `10 × g(T)` | Vendor gear (`40 × g(T)` for tiers up to `T*(Lp) − 2`); tier-up fee; stash pages (500 × 2ⁿ); respawn fee (§7) |
| **Echo Dust** (crafting) | Salvaging gear: `5 × g(T)` | Tier-up T→T+1: `20 × g(T+1)` Dust + `100 × g(T+1)` Glint (about 4 salvages per step) |
| **Riftstone** (portal) | Dungeon boss: `round(4 × M²)` per eligible player (§6) | Portal deposit forfeited on a failed run (§6); stash pages 3+ (10 each); charm re-roll (2); **[Later]** character slots, extra multiplier unlocks |

**Ledger rule:** every currency movement goes through the double-entry ledger (§8.2). That includes kill grants, banking, the vendor, tier-ups, salvage, the respawn fee, portal deposits and trade fees, not just trades.

All sinks scale with `g` or `m` at the same slope as the sources, so inflation stays flat at any level. Vendor gear is always 2 tiers behind on-level, so drops and tier-ups stay the main way to progress.

Glint, Echo Dust and Riftstone can be traded between players (§8). Hardcore characters have separate wallets (§7). The cosmetic-only currency **Prism** is **[Later]**: it ships with the cosmetic store, and the first playable has no paid cosmetics (`stack.md` decision 6). It is never tradeable (D8).

## 6. Portal level multiplier

Whoever opens a portal (a dungeon instance; a whole server instance or shard is **[Later]**, D5) sets **M**.

- **Wire format and validation:** M is sent as an integer number of hundredths, `M100`. The server accepts only `50 ≤ M100 ≤ 150` with `M100 % 5 == 0` and rejects anything else with `INVALID_MULTIPLIER` (acceptance tests: 0.45, 1.55 and 1.07 are rejected; 0.50, 1.05 and 1.50 are accepted). Values above 1.5 are **[Later]**: +0.25 per clear at your current max, up to a **hard cap of 3.0** (D2).
- **Base level B:** the higher of the dungeon's base level (Hollowmere Vault: 10) and the opener's **real** level `Lp` at the moment the portal is created. B is fixed for the instance. The vault stays relevant forever.
- **Content level:** `E = max(1, (B × M100 + 50) div 100)`, which is round half-up in exact integer math (B = 15, M = 0.50 → 7.5 → **8**).
- **Found portals (Wilds):** an elite in the Wilds has a 10% chance to leave a Hollowmere portal. It always has **M = 1.00** and no deposit. B is the higher of the dungeon's base level and that elite's level, and there is no opener. A found portal follows the same lifetime rules as an opened one.
- **What M scales:** enemy level E (so HP, damage and Ward through `m(E)`), kill XP through `killXP(E)`, drop tier through `T*(E)`, Glint through `m(E)`, extra boss rolls and Riftstone. Bullet patterns and speeds do **not** change. **[Later]** Pattern density modifiers at high M.
- **Rewards:**
  - Each eligible player gets `floor((M100 − 100) / 25)` extra boss item rolls when M > 1 (M 1.20 → 0, 1.25 → 1, 1.50 → 2).
  - Riftstone per eligible player is `(4 × M100² + 5000) div 10000`, which is `round(4 × M²)` half-up: M 0.50 → 1, 1.00 → 4, 1.25 → 6, 1.50 → 9.
- **Deposit, not a fee:** opening with M > 1 takes a Riftstone deposit of `ceil(5 × M²)` (6 at M 1.05, 8 at 1.25, 12 at 1.50). The opener gets it back in full when the boss dies, and loses it to the sink if the instance closes without a boss kill. A solo clear therefore always pays, and higher M pays more: net +4 at M 1.00, +6 at 1.25 and +9 at 1.50. Low-M runs (net 1–3) are for helping friends, not farming.

### 6.1 Instance rules and abuse limits
1. **Lock on creation:** M and B are fixed when the portal is created, and the portal label shows `E` and `M` before anyone joins.
2. **Join floor:** players with real `Lp < 0.5 × E` can't enter. If `Lp < E − 10`, they get a confirm dialog ("Content level E, you are level Lp"). This stops luring new players into a death trap.
3. **Level sync down:** inside the portal, players use `Le = min(Lp, E + 5)` (§3.2a), with the tier clamp from §4.1. High-level carries can't faceroll, and low-M runs can't be farmed by high levels.
4. **Anti power-leveling:** under-level XP is credited at no more than `Le + 10` (§3.4). There is no per-kill cap.
5. **Party cap:** 8 players per instance. The portal entrance closes once 8 players have entered.
6. **Per-player scaling:** enemy HP is multiplied by `1 + 0.6 × (n − 1)` for normal enemies and `1 + 0.75 × (n − 1)` for the boss. Damage is not scaled. For a normal enemy, n is the number of players in the instance when it spawns. For the boss, n is the number in the boss room when the fight starts. If someone joins mid-fight, the boss's HP is scaled up and keeps its current percentage.
7. **Boss eligibility (contribution check):** a player is eligible for the boss rewards if any one of these is true during the fight (which starts when the boss first takes damage):
   - (a) they dealt ≥ 2% of the boss's max HP;
   - (b) they used an ability that affected an ally at least 2 times;
   - (c) they were within 12 tiles of the boss for ≥ 50% of the fight's ticks.

   In every case they must also have sent non-idle input in the 30 s before the kill.
8. **Lifetimes:**
   - The entrance stays open 120 s after creation, or until 8 players have entered.
   - An instance lasts at most 30 min. At that point it collapses and players are moved to the Hearth, which banks their loot (§7).
   - An instance closes 60 s after it empties.
   - A deposit (above) is forfeited if the instance closes without a boss kill.
9. **Re-entry after death (Standard):** a Standard player who died keeps their party slot and can rejoin the same live instance from the Hearth portal board, up to 2 times per instance. The 120 s entrance limit doesn't apply to rejoining. They can't enter while the boss room is sealed during a fight. Hardcore deaths are final.
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

**Hardcore (permadeath):**
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
    - **Opening:** the server opens one automatically when an instance worker crashes or restarts, or its tick stalls for more than 2 s. On-call ops can also open one manually for an outage, with a required reason.
    - **Scope:** a window covers the instance, or the whole server for a manual one, from 30 s before the fault until it ends.
    - **Reverts:** deaths inside a window are reverted. The character is restored, tombstoned items are un-tombstoned, and the fee and pending loss are refunded. One audit row is written per revert, with the incident id, actor, character and items. Manual reverts are allowed up to 72 h after the death.
- **Leaderboard:** there are boards for all time and for each season. Ranking is by level, then total XP, then the earliest time the level was reached, with filters per class. Alive and Fallen characters are both listed, with a status badge.
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
- **One item table:** every item, gear or cosmetic token, is exactly one row in `items`, keyed by a server-minted UUIDv7 `item_uid` (the primary key).
  - **Fields:** each row has `mode`, `owner_account`, `owner_character`, `location`, `slot`, `pending`, `trade_lock` and `state`.
  - **Locations:** `location` is one of `EQUIPPED`, `INVENTORY`, `STASH`, `GROUND` (owned by an instance, for a personal drop not yet picked up) or **[Later]** `MAIL`. Offered items stay where they are, with `trade_lock = trade_id`, so there is no escrow copy.
  - **Tombstones:** destroyed, salvaged and vendor-sold items are **tombstoned**, never deleted. Their `state` is `TOMBSTONED`, with a reason (`SALVAGED`, `SOLD`, `DEATH_PENDING`, `DEATH_FALLEN` or `ADMIN`) and a timestamp. A tombstoned `item_uid` can come back only through an audited incident revert (§7.3).
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

### 8.3 Trade log and retention
- **What's logged:** every trade window that reaches at least one Lock writes exactly one `trade_log` row: committed, rejected, failed, timed out or cancelled. The row has `trade_id`, UTC timestamps (open, lock, confirm, commit), both account and character IDs, mode, item_uids with tiers, currency amounts, NTV and the result. Windows cancelled before any Lock produce metrics only.
- **Write access:** the game server's database role can only INSERT. Corrections are written as new compensating rows.
- **Retention (D14):**
  - `trade_log` is partitioned by month. A scheduled daily job running under a dedicated `retention_job` role (the only role allowed to drop partitions) drops partitions older than 24 months.
  - Salted IP and device hashes live in a separate `trade_log_net` table (`trade_id`, `account_id`, `ip_hash`, `device_hash`, `created_at`), partitioned by day. The same job drops partitions older than 90 days.
  - **Acceptance tests:** "no `trade_log_net` row older than 90 days exists" and "no `trade_log` row older than 24 months exists", both checked daily.
- **GDPR erasure:** on an erasure request, the account's personal data (email and login identifiers) is deleted, and `retention_job` deletes that account's `trade_log_net` rows immediately. That targeted delete is audited. `trade_log` rows then reference only a pseudonymous account ID and expire on the 24-month schedule, kept under fraud-prevention legitimate interest. Privacy counsel must confirm this before launch.

### 8.4 Trade value and limits
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
The server flags unusual activity into a human review queue. Examples include very one-sided trades, many new accounts sending to one account, many accounts on one device trading into one account, and implausible earn rates. The only automatic actions are:
- hold the received assets of a flagged trade for up to 48 h (auto-released if nobody acts, with the flag kept on record);
- pause one account's trading pending review;
- the §8.2 freezes and kill switch.

Bans are human-only in v0.1 (D16). Thresholds, time windows and detection models live in the **private ops doc** and are not published here.

**[Later]** A market board (asynchronous listings), mail with attachments, and trade-velocity models.

Why: full currency trading means real-money traders will come. Server-side atomic trades shut out dupes. Gating new accounts and adding a short re-trade hold make bot-farm funnels slow and easy to see, while normal players never notice the limits.

## 9. Seasonal cosmetic track [v0.1, Season 0]

- **Season:** 10 weeks. The track has 30 tiers, and each tier costs 200 **Sparks** (6,000 in total).
- **Sparks:** 1 per 10 kills (only kills with `E ≥ Le − 5` count), 20 per boss when eligible (§6.1), and +50 for the first dungeon clear each UTC day. That is about 250 Sparks per hour, so the full track takes about 24 h of play over 10 weeks. Sparks past tier 30, and unspent Sparks, are discarded at season end.
- **30 tiers (all cosmetic, no Prism in v0.1):** 2 class skins, 6 dyes, 3 portal trails, 2 emotes, 1 title, 6 nameplate frames, 4 projectile tints and 6 Hearth banners.
- **Account-wide unlocks:** cosmetics are unlocks for the whole account. Hardcore and Standard characters earn into the same track and can both use any unlock, since cosmetics carry no power.
- **Trading (D8):** a Standard character can convert an earned season unlock into a tradeable **cosmetic token** (an item with its own `item_uid`, 100 NTV). That removes the unlock until the token is redeemed. Tokens trade only in the Standard pool. Hardcore milestone and leaderboard cosmetics (§7.3) are account-bound and never tradeable.
- There is no paid premium track (D15).

**[Later] Prism** is a cosmetic-only currency, earned on later season tracks or bought in the cosmetic store. It is never tradeable and buys nothing that affects power.

## 10. Decisions (2026-11-23)

D1–D7 are Karyu's decisions. D8–D16 are design defaults accepted by Chief of Staff and can be tuned after playtests.

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
| D14 | *Default, tunable after playtests.* Trade log rows are kept for 24 months. Salted IP and device hashes are kept for 90 days, and both are stated in the privacy policy (§8.3). |
| D15 | *Default, tunable after playtests.* No paid premium season track. Paid cosmetics are sold only as separate store items (§9). |
| D16 | *Default, tunable after playtests.* Enforcement in v0.1 uses automatic holds and pauses only. Bans are human-only. Revisit once flag precision has been measured (§8.5). |

**Tuning ownership:** Design decides tuning numbers (rates, caps, costs, timers, curves) and records them here. They are escalated to Karyu only when a change would alter the game's direction or touch money (monetization, pay-to-win boundaries, real-money flows).

There are no open questions right now. New ones will go in a §11 when they come up.
