class_name HostStandinBulletField
extends RefCounted
## STAND-IN enemy bullets for the Godot host load test. Not gameplay code.
## It exists so the host can be measured with a realistic bullet load before it
## runs the shared enemy/pattern rules (client/src/core). Switching the host to
## those rules is a follow-up; delete this file then.
##
## Closed-form PatternSpawn: each emitter fires a ring every `period` ticks.
## Every bullet in a ring is rebuilt from (seed, emitter, spawn_tick) with a
## seeded PCG32 (Godot's RandomNumberGenerator is PCG32), so a client only needs
## the spawn event. Position at tick t is origin + vel * (t - spawn_tick).
## Hits are swept: segment from the previous tick's position to this tick's,
## tested against player circles bucketed in a uniform grid.

const GRID_CELL: float = 2.0
const PATTERN_RING: int = 1

var emitters_x := PackedFloat64Array()
var emitters_y := PackedFloat64Array()
var emitter_phase := PackedInt32Array()
var ring_count: int = 12
var period_ticks: int = 12
var speed_tiles_per_s: float = 6.0
var lifetime_ticks: int = 50
var bullet_radius: float = 0.2
var seed: int = 1

# Structure of arrays for live bullets. vx/vy are tiles per tick.
var b_ox := PackedFloat64Array()
var b_oy := PackedFloat64Array()
var b_vx := PackedFloat64Array()
var b_vy := PackedFloat64Array()
var b_spawn := PackedInt32Array()
var b_count: int = 0

## Spawn events produced by the last step(): [emitter_id, seed, spawn_tick, x, y] each.
var last_spawns: Array[PackedFloat64Array] = []
var hits_total: int = 0
var checks_total: int = 0

var _rng := RandomNumberGenerator.new()


func _init(p_seed: int, emitter_count: int, arena_w: float, arena_h: float) -> void:
	seed = p_seed
	# Emitters on a grid inside the arena, phases staggered so load is smooth.
	var cols: int = int(ceil(sqrt(float(emitter_count))))
	var rows: int = int(ceil(float(emitter_count) / float(cols)))
	for i in range(emitter_count):
		var cx: int = i % cols
		var cy: int = i / cols
		emitters_x.append((float(cx) + 0.5) * arena_w / float(cols))
		emitters_y.append((float(cy) + 0.5) * arena_h / float(rows))
		emitter_phase.append(i % period_ticks)


func live_bullets() -> int:
	return b_count


## Steps bullets to `tick` and applies hits to players.
## px/py: player positions; player_r: player radius; hp: decremented on hit.
func step(tick: int, px: PackedFloat64Array, py: PackedFloat64Array, player_r: float, hp: PackedInt32Array) -> void:
	_spawn_due(tick)
	var grid := _build_grid(px, py)
	var reach: float = player_r + bullet_radius
	var reach2: float = reach * reach
	var i: int = 0
	while i < b_count:
		var age: int = tick - b_spawn[i]
		if age >= lifetime_ticks:
			_remove(i)
			continue
		var vx: float = b_vx[i]
		var vy: float = b_vy[i]
		var x1: float = b_ox[i] + vx * float(age)
		var y1: float = b_oy[i] + vy * float(age)
		var x0: float = x1 - vx
		var y0: float = y1 - vy
		var hit: int = _sweep_grid(grid, px, py, x0, y0, vx, vy, reach, reach2)
		if hit >= 0:
			hits_total += 1
			hp[hit] -= 10
			_remove(i)
			continue
		i += 1


func _spawn_due(tick: int) -> void:
	last_spawns.clear()
	var vel: float = speed_tiles_per_s * SimConstants.TICK_DT
	for e in range(emitters_x.size()):
		if (tick + emitter_phase[e]) % period_ticks != 0:
			continue
		var spawn_seed: int = hash([seed, e, tick])
		_rng.seed = spawn_seed
		var base: float = _rng.randf() * TAU
		var ox: float = emitters_x[e]
		var oy: float = emitters_y[e]
		for j in range(ring_count):
			var a: float = base + TAU * float(j) / float(ring_count) + _rng.randf_range(-0.05, 0.05)
			b_ox.append(ox)
			b_oy.append(oy)
			b_vx.append(cos(a) * vel)
			b_vy.append(sin(a) * vel)
			b_spawn.append(tick)
			b_count += 1
		var ev := PackedFloat64Array([float(e), float(spawn_seed), float(tick), ox, oy])
		last_spawns.append(ev)


func _build_grid(px: PackedFloat64Array, py: PackedFloat64Array) -> Dictionary:
	var grid: Dictionary = {}
	for p in range(px.size()):
		var key: int = _cell_key(int(floor(px[p] / GRID_CELL)), int(floor(py[p] / GRID_CELL)))
		if grid.has(key):
			(grid[key] as PackedInt32Array).append(p)
		else:
			grid[key] = PackedInt32Array([p])
	return grid


func _sweep_grid(grid: Dictionary, px: PackedFloat64Array, py: PackedFloat64Array,
		x0: float, y0: float, sx: float, sy: float, reach: float, reach2: float) -> int:
	var minx: int = int(floor((minf(x0, x0 + sx) - reach) / GRID_CELL))
	var maxx: int = int(floor((maxf(x0, x0 + sx) + reach) / GRID_CELL))
	var miny: int = int(floor((minf(y0, y0 + sy) - reach) / GRID_CELL))
	var maxy: int = int(floor((maxf(y0, y0 + sy) + reach) / GRID_CELL))
	var seg2: float = sx * sx + sy * sy
	for cx in range(minx, maxx + 1):
		for cy in range(miny, maxy + 1):
			var key: int = _cell_key(cx, cy)
			if not grid.has(key):
				continue
			for p: int in (grid[key] as PackedInt32Array):
				checks_total += 1
				var dx: float = px[p] - x0
				var dy: float = py[p] - y0
				var t: float = 0.0
				if seg2 > 0.0:
					t = clampf((dx * sx + dy * sy) / seg2, 0.0, 1.0)
				var ex: float = dx - sx * t
				var ey: float = dy - sy * t
				if ex * ex + ey * ey <= reach2:
					return p
	return -1


static func _cell_key(cx: int, cy: int) -> int:
	return (cx + 32768) * 65536 + (cy + 32768)


func _remove(i: int) -> void:
	# Swap-remove: order does not matter for closed-form bullets.
	var last: int = b_count - 1
	if i != last:
		b_ox[i] = b_ox[last]
		b_oy[i] = b_oy[last]
		b_vx[i] = b_vx[last]
		b_vy[i] = b_vy[last]
		b_spawn[i] = b_spawn[last]
	b_ox.resize(last)
	b_oy.resize(last)
	b_vx.resize(last)
	b_vy.resize(last)
	b_spawn.resize(last)
	b_count = last
