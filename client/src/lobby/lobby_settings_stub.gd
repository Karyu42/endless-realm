extends RefCounted
## Temporary stand-in for the Server Engineer's `LobbySettings`
## (`client/src/net/host/`). Do not add `class_name` — that name is reserved
## for their type. Field names and `validate()` match the agreed API.
## Swap this preload for `LobbySettings` once that API lands.

const M100_FLOOR: int = 50
const M100_CEILING: int = 150
const M100_STEP: int = 5
const M100_DEFAULT: int = 100

var max_players: int = LobbyHost.DEFAULT_MAX_PLAYERS
var m100_min: int = M100_DEFAULT
var m100_max: int = M100_DEFAULT
var imports_allowed: bool = true
var offline_allowed: bool = true
var lobby_name: String = ""
## Empty means the host generates one (agreed LobbySettings API).
var join_code: String = ""


func try_set_max_players(text: String) -> bool:
	var n: int = LobbyHost.parse_max_players(text)
	if n < 0:
		return false
	max_players = n
	return true


func try_set_m100_min(text: String) -> bool:
	var n: int = _parse_m100(text)
	if n < 0:
		return false
	m100_min = n
	return true


func try_set_m100_max(text: String) -> bool:
	var n: int = _parse_m100(text)
	if n < 0:
		return false
	m100_max = n
	return true


func validate() -> PackedStringArray:
	var reasons := PackedStringArray()
	if (
		max_players < LobbyHost.MIN_MAX_PLAYERS
		or max_players > LobbyHost.MAX_MAX_PLAYERS
	):
		reasons.append("Max players must be an integer from 1 to 50.")
	if not _m100_ok(m100_min):
		reasons.append("Minimum M (m100) must be an integer from 50 to 150 in steps of 5.")
	if not _m100_ok(m100_max):
		reasons.append("Maximum M (m100) must be an integer from 50 to 150 in steps of 5.")
	if _m100_ok(m100_min) and _m100_ok(m100_max):
		if m100_min > m100_max or m100_min > M100_DEFAULT or m100_max < M100_DEFAULT:
			reasons.append("M range must satisfy min <= 100 <= max.")
	return reasons


func _parse_m100(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty() or not trimmed.is_valid_int():
		return -1
	var n: int = trimmed.to_int()
	if not _m100_ok(n):
		return -1
	return n


func _m100_ok(value: int) -> bool:
	return value >= M100_FLOOR and value <= M100_CEILING and value % M100_STEP == 0
