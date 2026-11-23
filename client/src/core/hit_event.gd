class_name HitEvent
extends RefCounted
## One resolved hit from a completed LocalSim tick. Read-only; do not mutate
## or keep past the next step().

const KIND_PLAYER_TAKEN := 0
const KIND_DEALT := 1

var tick: int = 0
var kind: int = KIND_DEALT
var target_id: int = 0
var x: float = 0.0
var y: float = 0.0
var amount: int = 0
