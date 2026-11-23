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
