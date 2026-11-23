class_name HostWorldSnapshot
extends WorldSnapshot
## LobbyHost.world_view() result: the shared WorldSnapshot for one player,
## plus host-only extras the base type has no fields for yet.
##
## Time base: `tick` and every spawn_tick inside (projectiles, pattern
## bullets) use that player's sim clock, so the usual WorldSnapshot render
## math works unchanged. `host_tick` is the lobby tick it was taken at.

var host_tick: int = 0
## Other players in the lobby: {"id", "x", "y", "aim", "hp", "local"}.
var others: Array[Dictionary] = []
