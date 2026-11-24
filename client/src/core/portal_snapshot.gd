class_name PortalSnapshot
extends RefCounted
## Read-only portal or dungeon marker at one tick.

const KIND_ENTER := "enter"
const KIND_EXIT := "exit"
const KIND_PLACEHOLDER := "placeholder"

var id: int = 0
var x: float = 0.0
var y: float = 0.0
var radius: float = 0.0
var kind: String = KIND_ENTER
var dungeon_id: String = ""
var dungeon_name: String = ""
var m100: int = 0
var content_level: int = 0
var base_level: int = 0
## A fixed entrance (e.g. the practice yard door): it never expires and
## keeps one long-lived instance for the life of the host.
var persistent: bool = false
## From the packed entrance: whether the destination instance grants persistent rewards.
var grants_persistent: bool = false
## For KIND_PLACEHOLDER, the packed boss id (not spawned yet).
var marker_id: String = ""
var marker_name: String = ""
var capacity: int = 0
var admitted_count: int = 0
## Host-closed, or past the admission deadline. The same for every viewer.
var closed: bool = false
## Host tick deadline for new admissions; 0 for persistent doors / markers.
var expire_tick: int = 0
## Per-viewer: this player may re-enter even when `closed`.
var admitted_for_me: bool = false


func is_interactable() -> bool:
	return kind == KIND_ENTER or kind == KIND_EXIT


## Persistent doors are limited by capacity and never appear in
## admitted_portal_ids.
func appears_full() -> bool:
	return kind == KIND_ENTER and persistent and capacity > 0 and admitted_count >= capacity


## An entrance is open when it is not closed, or when it is closed but this
## viewer is already admitted (re-entry). A full persistent door is not open.
func appears_open() -> bool:
	if kind == KIND_EXIT:
		return true
	if kind != KIND_ENTER or appears_full():
		return false
	return not closed or admitted_for_me
