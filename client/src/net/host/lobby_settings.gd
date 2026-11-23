class_name LobbySettings
extends RefCounted
## Host-owned lobby settings (stack decision 2b). The lobby UI edits a copy and
## hands it to LobbyHost.apply_settings(); validate() reasons are shown to
## players verbatim, so keep them short and readable.

const MIN_M100: int = 50
const MAX_M100: int = 150
const M100_STEP: int = 5
const BASE_M100: int = 100
const MAX_LOBBY_NAME_LENGTH: int = 32
## Join codes: uppercase letters and digits without look-alikes (0/O, 1/I/L).
const JOIN_CODE_ALPHABET: String = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
const JOIN_CODE_LENGTH: int = 6
const MIN_JOIN_CODE_LENGTH: int = 4
const MAX_JOIN_CODE_LENGTH: int = 12

## Players allowed at once, 1-50. Lowering it never kicks anyone.
var max_players: int = 50
## Allowed portal multipliers in hundredths, in [50, 150], multiples of 5,
## with m100_min <= 100 <= m100_max.
var m100_min: int = 100
var m100_max: int = 100
## Accept characters created on another lobby.
var imports_allowed: bool = true
## Accept characters flagged as played offline.
var offline_allowed: bool = true
var lobby_name: String = ""
## Empty means the host generates one when the settings are applied.
var join_code: String = ""


## Empty when valid; otherwise one short reason per problem.
func validate() -> PackedStringArray:
	var out := PackedStringArray()
	if max_players < 1 or max_players > 50:
		out.append("Max players must be between 1 and 50.")
	var m_ok := true
	for m in [m100_min, m100_max]:
		if m < MIN_M100 or m > MAX_M100 or m % M100_STEP != 0:
			m_ok = false
	if not m_ok:
		out.append("Level multipliers must be 0.50 to 1.50 in steps of 0.05.")
	elif m100_min > BASE_M100 or m100_max < BASE_M100:
		out.append("The multiplier range must include 1.00.")
	if lobby_name.length() > MAX_LOBBY_NAME_LENGTH:
		out.append("Lobby name must be at most %d characters." % MAX_LOBBY_NAME_LENGTH)
	for i in range(lobby_name.length()):
		if lobby_name.unicode_at(i) < 32:
			out.append("Lobby name can't contain control characters.")
			break
	if join_code != "" and not is_valid_join_code(join_code):
		out.append("Join code must be %d to %d characters from %s." % [
			MIN_JOIN_CODE_LENGTH, MAX_JOIN_CODE_LENGTH, JOIN_CODE_ALPHABET])
	return out


func is_valid() -> bool:
	return validate().is_empty()


## True if m100 is inside this lobby's allowed portal multiplier range.
func allows_m100(m100: int) -> bool:
	return m100 >= m100_min and m100 <= m100_max and m100 % M100_STEP == 0


func duplicate_settings() -> LobbySettings:
	var c := LobbySettings.new()
	c.max_players = max_players
	c.m100_min = m100_min
	c.m100_max = m100_max
	c.imports_allowed = imports_allowed
	c.offline_allowed = offline_allowed
	c.lobby_name = lobby_name
	c.join_code = join_code
	return c


static func is_valid_join_code(code: String) -> bool:
	if code.length() < MIN_JOIN_CODE_LENGTH or code.length() > MAX_JOIN_CODE_LENGTH:
		return false
	for i in range(code.length()):
		if JOIN_CODE_ALPHABET.find(code[i]) < 0:
			return false
	return true


## A fresh join code from OS randomness (Crypto), never from the sim RNG.
static func generate_join_code(length: int = JOIN_CODE_LENGTH) -> String:
	var crypto := Crypto.new()
	var n: int = JOIN_CODE_ALPHABET.length()
	var limit: int = 256 - (256 % n)  # rejection sampling keeps it unbiased
	var code := ""
	while code.length() < length:
		for b in crypto.generate_random_bytes(length * 2):
			if b < limit and code.length() < length:
				code += JOIN_CODE_ALPHABET[b % n]
	return code
