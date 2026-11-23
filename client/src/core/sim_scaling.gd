class_name SimScaling
extends RefCounted
## Vision §3 and §4 coefficients, loaded from data/scaling.json.
## Formulas live here; the JSON only stores the numbers.

var m_intercept: float = 1.0
var m_per_level: float = 0.05
var g_intercept: float = 1.0
var g_per_tier: float = 0.25
var kill_xp_coef: float = 10.0
var kills_to_level_base: float = 10.0
var kills_to_level_coef: float = 2.0
var kills_to_level_exp: float = 0.75
var type_mult_normal: int = 1
var type_mult_elite: int = 5
var type_mult_boss: int = 50
var under_level_cap: int = 10
var over_level_penalty_per_level: float = 0.05
var over_level_penalty_min: float = 0.1
var sync_plus: int = 5
## Client prompt / auto-select range, center to center, in tiles (content-v0.1 §1.5).
var interact_prompt_range_tiles: float = 0.0
## Host accept tolerance for interact_target_id, center to center (content-v0.1 §1.5).
var interact_accept_range_tiles: float = 0.0
## Fixed E for every practice-yard enemy (content-v0.1 §2.4).
var practice_yard_content_level: int = 0
## Portal M100 accept window and join floor (vision §6). 0 means the packed
## field was missing; is_valid_m100 then fails closed.
var portal_m100_min: int = 0
var portal_m100_max: int = 0
var portal_m100_step: int = 0
var portal_join_floor_numer: int = 0
var portal_join_floor_denom: int = 0
var portal_entrance_lifetime_ticks: int = 0
var _portal_present: Dictionary = {}


static func from_json(d: Dictionary) -> SimScaling:
	var s := SimScaling.new()
	s.m_intercept = float(d.get("m_intercept", 1.0))
	s.m_per_level = float(d.get("m_per_level", 0.05))
	s.g_intercept = float(d.get("g_intercept", 1.0))
	s.g_per_tier = float(d.get("g_per_tier", 0.25))
	var xp: Variant = d.get("xp", {})
	if xp is Dictionary:
		s.kill_xp_coef = float(xp.get("kill_xp_coef", 10.0))
		s.kills_to_level_base = float(xp.get("kills_to_level_base", 10.0))
		s.kills_to_level_coef = float(xp.get("kills_to_level_coef", 2.0))
		s.kills_to_level_exp = float(xp.get("kills_to_level_exp", 0.75))
		s.under_level_cap = int(xp.get("under_level_cap", 10))
		s.over_level_penalty_per_level = float(xp.get("over_level_penalty_per_level", 0.05))
		s.over_level_penalty_min = float(xp.get("over_level_penalty_min", 0.1))
		var tm: Variant = xp.get("type_mult", {})
		if tm is Dictionary:
			s.type_mult_normal = int(tm.get("normal", 1))
			s.type_mult_elite = int(tm.get("elite", 5))
			s.type_mult_boss = int(tm.get("boss", 50))
	var sync: Variant = d.get("sync_plus", 5)
	s.sync_plus = int(sync)
	s.interact_prompt_range_tiles = float(d.get("interact_prompt_range_tiles", 0.0))
	s.interact_accept_range_tiles = float(d.get("interact_accept_range_tiles", 0.0))
	s.practice_yard_content_level = int(d.get("practice_yard_content_level", 0))
	var portal: Variant = d.get("portal", {})
	if portal is Dictionary:
		var pd: Dictionary = portal
		for key in pd.keys():
			s._portal_present[String(key)] = true
		if pd.has("m100_min"):
			s.portal_m100_min = int(pd["m100_min"])
		if pd.has("m100_max"):
			s.portal_m100_max = int(pd["m100_max"])
		if pd.has("m100_step"):
			s.portal_m100_step = int(pd["m100_step"])
		if pd.has("join_floor_numer"):
			s.portal_join_floor_numer = int(pd["join_floor_numer"])
		if pd.has("join_floor_denom"):
			s.portal_join_floor_denom = int(pd["join_floor_denom"])
		if pd.has("entrance_lifetime_ticks"):
			s.portal_entrance_lifetime_ticks = int(pd["entrance_lifetime_ticks"])
	return s


static func round_half_up(x: float) -> int:
	## Positive-side half-up, as used in vision §3.4 and content-v0.1.
	if x >= 0.0:
		return int(floor(x + 0.5))
	return int(ceil(x - 0.5))


func m(level: int) -> float:
	return m_intercept + m_per_level * float(level - 1)


func g(tier: int) -> float:
	return g_intercept + g_per_tier * float(maxi(tier, 0))


func t_star(content_level: int) -> int:
	if content_level <= 0:
		return 0
	return int(content_level / 5)


func type_mult(rank: String) -> int:
	match rank:
		"elite":
			return type_mult_elite
		"boss":
			return type_mult_boss
		_:
			return type_mult_normal


## killXP(E) = 10 × m(E), stored as tenths so L10 is exactly 145.
func kill_xp_tenths(content_level: int) -> int:
	# 10 * 10 * m(L) = 100 * (1 + 0.05*(L-1)) = 100 + 5*(L-1) at the default coefficients.
	return round_half_up(kill_xp_coef * 10.0 * m(content_level))


func kills_to_level(level: int) -> float:
	return kills_to_level_base + kills_to_level_coef * pow(float(level), kills_to_level_exp)


## Whole XP to go from `level` to `level+1` (vision table). Stored XP uses tenths.
func xp_to_next(level: int) -> int:
	return round_half_up(float(kill_xp_tenths(level)) / 10.0 * kills_to_level(level))


func xp_to_next_tenths(level: int) -> int:
	return xp_to_next(level) * 10


## Sum of xpToNext(1)..xpToNext(level-1), in whole XP. Safe for level 1000+.
func total_xp_to_reach(level: int) -> int:
	var total: int = 0
	var l: int = 1
	while l < level:
		total += xp_to_next(l)
		l += 1
	return total


func over_level_penalty(le: int, content_level: int) -> float:
	var steps: int = maxi(0, le - content_level)
	var p: float = 1.0 - over_level_penalty_per_level * float(steps)
	if p < over_level_penalty_min:
		p = over_level_penalty_min
	if p > 1.0:
		p = 1.0
	return p


## Credited tenths for one kill (vision §3.4). M scales XP only through E.
func credited_kill_tenths(content_level: int, le: int, rank: String) -> int:
	var e_eff: int = mini(content_level, le + under_level_cap)
	var raw: float = float(kill_xp_tenths(e_eff) * type_mult(rank)) * over_level_penalty(le, content_level)
	return round_half_up(raw)


func effective_level(lp: int, content_level: int, in_portal: bool) -> int:
	if not in_portal:
		return lp
	return mini(lp, content_level + sync_plus)


## Max HP from a class base, rounded half-up in integer hundredths of m.
func scaled_hp(base_hp: int, level: int, gear_hp: int = 0) -> int:
	var m100: int = round_half_up(m(level) * 100.0)
	return (base_hp * m100 + 50) / 100 + gear_hp


func in_prompt_range(distance: float) -> bool:
	return distance <= interact_prompt_range_tiles


func in_accept_range(distance: float) -> bool:
	return distance <= interact_accept_range_tiles


func missing_pack_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	for field in [
		"m100_min", "m100_max", "m100_step",
		"join_floor_numer", "join_floor_denom", "entrance_lifetime_ticks"
	]:
		if not _portal_present.has(field):
			ids.append("scaling.portal.%s" % field)
	return ids


## Vision §6: 50 ≤ M100 ≤ 150 and M100 % step == 0. Fails closed if step is 0.
func is_valid_m100(m100: int) -> bool:
	if portal_m100_step <= 0:
		return false
	if m100 < portal_m100_min or m100 > portal_m100_max:
		return false
	return m100 % portal_m100_step == 0


## B is the higher of the dungeon base level and the opener's real Lp.
func instance_base_level(dungeon_base: int, opener_lp: int) -> int:
	return maxi(dungeon_base, opener_lp)


## E = max(1, (B × M100 + 50) div 100), vision §6.
func portal_content_level(base_level: int, m100: int) -> int:
	return maxi(1, (base_level * m100 + 50) / 100)


## True when real Lp is below the join floor (Lp < numer/denom × E).
func below_join_floor(lp: int, content_level: int) -> bool:
	if portal_join_floor_denom <= 0:
		return true
	return lp * portal_join_floor_denom < portal_join_floor_numer * content_level
