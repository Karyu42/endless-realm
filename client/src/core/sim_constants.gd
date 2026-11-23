class_name SimConstants
extends Object
## Single place for sim units and the 20 Hz tick. Do not restate TILE_PX elsewhere.
## See docs/tech/stack.md.

const TICK_HZ: int = 20
const TICK_DT: float = 1.0 / 20.0
const TILE_PX: float = 16.0
const PROTOCOL_VERSION: int = 1
const MOVE_EPS: float = 1e-12
