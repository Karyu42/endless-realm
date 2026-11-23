class_name PortalTransfer
extends RefCounted
## Result of a successful portal interact this tick.
## LocalSim does not move the player to another instance; GameSession (solo)
## or the host (lobby) consumes this and creates or switches the instance.

const KIND_ENTER := "enter"
const KIND_EXIT := "exit"

var kind: String = KIND_ENTER
var player_id: int = 0
var portal_id: int = 0
var dungeon_id: String = ""
var seed: int = 0
var m100: int = 0
var base_level: int = 0
var content_level: int = 0
var opener_id: int = 0
var opener_lp: int = 0
var arrival_x: float = 0.0
var arrival_y: float = 0.0
## Packed entrance flag, consumed by configure_dungeon. Official true, practice false.
var grants_persistent: bool = false
