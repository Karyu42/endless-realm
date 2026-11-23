class_name PlayerInventory
extends RefCounted
## 8 inventory slots plus equipped weapon / armor / charm (content-v0.1 §1.5).

var slots: Array[ItemState] = []
var equipped_weapon: ItemState = null
var equipped_armor: ItemState = null
var equipped_charm: ItemState = null
var slot_count: int = 8


func _init(n: int = 8) -> void:
	slot_count = n
	slots.clear()
	slots.resize(slot_count)
	for i in range(slot_count):
		slots[i] = null


func free_index() -> int:
	for i in range(slots.size()):
		if slots[i] == null:
			return i
	return -1


func is_full() -> bool:
	return free_index() < 0


func add(item: ItemState) -> bool:
	var i := free_index()
	if i < 0 or item == null:
		return false
	item.location = ItemState.LOC_INVENTORY
	slots[i] = item
	return true


func take_slot(index: int) -> ItemState:
	if index < 0 or index >= slots.size():
		return null
	var item: ItemState = slots[index]
	slots[index] = null
	return item


func equipped_for(slot: String) -> ItemState:
	match slot:
		ItemState.SLOT_WEAPON:
			return equipped_weapon
		ItemState.SLOT_ARMOR:
			return equipped_armor
		ItemState.SLOT_CHARM:
			return equipped_charm
		_:
			return null


func set_equipped(slot: String, item: ItemState) -> void:
	if item != null:
		item.location = ItemState.LOC_EQUIPPED
	match slot:
		ItemState.SLOT_WEAPON:
			equipped_weapon = item
		ItemState.SLOT_ARMOR:
			equipped_armor = item
		ItemState.SLOT_CHARM:
			equipped_charm = item


## Equip the item in inventory slot `index`, swapping with the matching gear slot.
func equip_from_slot(index: int) -> bool:
	var item := take_slot(index)
	if item == null:
		return false
	var prev := equipped_for(item.slot)
	set_equipped(item.slot, item)
	if prev != null:
		prev.location = ItemState.LOC_INVENTORY
		slots[index] = prev
	return true


func live_items() -> Array[ItemState]:
	var out: Array[ItemState] = []
	for s in slots:
		if s != null:
			out.append(s)
	if equipped_weapon != null:
		out.append(equipped_weapon)
	if equipped_armor != null:
		out.append(equipped_armor)
	if equipped_charm != null:
		out.append(equipped_charm)
	return out
