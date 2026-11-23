class_name DamageNumberPool
extends RefCounted
## Pooled floating combat numbers. Slots are reused; the oldest is recycled
## when the cap is hit so a 50-player crowd cannot allocate without bound.

class Slot:
	var active: bool = false
	var amount: int = 0
	var kind: int = 0
	var x: float = 0.0
	var y: float = 0.0
	var origin_x: float = 0.0
	var origin_y: float = 0.0
	var age: float = 0.0


const KIND_PLAYER_TAKEN := 0
const KIND_DEALT := 1
const KIND_HEAL := 2

var _slots: Array[Slot] = []
var _size: int = 0
var _active: int = 0
var _cursor: int = 0


func configure(pool_size: int) -> void:
	_size = maxi(pool_size, 1)
	_slots.clear()
	_slots.resize(_size)
	for i in range(_size):
		_slots[i] = Slot.new()
	_active = 0
	_cursor = 0


func capacity() -> int:
	return _size


func active_count() -> int:
	return _active


func slot_at(index: int) -> Slot:
	if index < 0 or index >= _slots.size():
		return null
	return _slots[index]


func spawn(amount: int, kind: int, x: float, y: float, stack_offset_px: float) -> int:
	if _size <= 0:
		return -1
	var index: int = _free_index()
	if index < 0:
		index = _oldest_index()
		if _slots[index].active:
			_slots[index].active = false
			_active -= 1
	var n: int = 0
	for s in _slots:
		if s.active and absf(s.origin_x - x) < 8.0 and absf(s.origin_y - y) < 8.0:
			n += 1
	var slot: Slot = _slots[index]
	slot.active = true
	slot.amount = amount
	slot.kind = kind
	slot.origin_x = x
	slot.origin_y = y - float(n) * stack_offset_px
	slot.x = slot.origin_x
	slot.y = slot.origin_y
	slot.age = 0.0
	_active += 1
	return index


func advance(dt: float, lifetime: float, rise_px: float) -> void:
	if lifetime <= 0.0:
		return
	for slot in _slots:
		if not slot.active:
			continue
		slot.age += dt
		var t: float = clampf(slot.age / lifetime, 0.0, 1.0)
		slot.x = slot.origin_x
		slot.y = slot.origin_y - rise_px * t
		if slot.age >= lifetime:
			slot.active = false
			_active -= 1


func alpha_of(slot: Slot, lifetime: float) -> float:
	if slot == null or lifetime <= 0.0:
		return 0.0
	return clampf(1.0 - slot.age / lifetime, 0.0, 1.0)


func _free_index() -> int:
	for _i in range(_size):
		var index: int = (_cursor + _i) % _size
		if not _slots[index].active:
			_cursor = (index + 1) % _size
			return index
	return -1


func _oldest_index() -> int:
	var best: int = 0
	var oldest: float = -1.0
	for i in range(_size):
		if _slots[i].active and _slots[i].age > oldest:
			oldest = _slots[i].age
			best = i
	return best
