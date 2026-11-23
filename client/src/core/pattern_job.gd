class_name PatternJob
extends RefCounted
## Multi-emit pattern (burst / spiral) that continues after the fire that started it.

var source_id: int = 0
var def: PatternDef = null
var start_tick: int = 0
var next_emit_tick: int = 0
var emit_index: int = 0
var end_tick: int = -1
var repeats_left: int = -1
var reaim: bool = false
var aim: float = 0.0
var interval: int = 1
var live: bool = true
