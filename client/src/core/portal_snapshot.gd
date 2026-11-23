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
## For KIND_PLACEHOLDER, the packed boss id (not spawned yet).
var marker_id: String = ""
var marker_name: String = ""


func is_interactable() -> bool:
	return kind == KIND_ENTER or kind == KIND_EXIT
