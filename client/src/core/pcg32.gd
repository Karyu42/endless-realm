class_name PCG32
extends RefCounted
## PCG-XSH-RR 64/32. Matches server/internal/sim and fixtures/README.md.
## GDScript ints are signed, so multiply and shifts are done as uint64.

# 6364136223846793005, which fits in signed int64.
const MULT: int = 6364136223846793005
const MASK32: int = 0xFFFFFFFF

var _state: int = 0
var _inc: int = 0


## Official pcg32_srandom. Pattern spawns use PCG32.new(seed, 1).
func _init(initstate: int = 0, initseq: int = 1) -> void:
	_state = 0
	_inc = _shl64(initseq, 1) | 1
	uint32()
	_state = _add64(_state, initstate)
	uint32()


func uint32() -> int:
	var old: int = _state
	_state = _add64(_mul64(old, MULT), _inc)
	var xorshifted: int = _lshr64(_xor64(_lshr64(old, 18), old), 27) & MASK32
	var rot: int = _lshr64(old, 59) & 31
	var left: int = _shl64(xorshifted, ((-rot) & 31)) & MASK32
	return ((_lshr64(xorshifted, rot) & MASK32) | left) & MASK32


static func _add64(a: int, b: int) -> int:
	# Signed wrap of two's complement is the same as uint64 wrap.
	return a + b


static func _xor64(a: int, b: int) -> int:
	return a ^ b


static func _shl64(a: int, n: int) -> int:
	if n <= 0:
		return a
	if n >= 64:
		return 0
	return a << n


static func _lshr64(a: int, n: int) -> int:
	if n <= 0:
		return a
	if n >= 64:
		return 0
	# Arithmetic >> sign-extends; mask back to a logical shift.
	return (a >> n) & ((1 << (64 - n)) - 1)


static func _mul64(a: int, b: int) -> int:
	# 64x64 -> low 64 using 32-bit limbs, so we never leave the integer domain.
	var a0: int = a & MASK32
	var a1: int = _lshr64(a, 32)
	var b0: int = b & MASK32
	var b1: int = _lshr64(b, 32)
	var lo: int = a0 * b0
	var mid: int = a0 * b1 + a1 * b0
	return lo + _shl64(mid & MASK32, 32)


## Parse a fixture u64 written as decimal or 0x hex. Returns the signed
## bit pattern of that u64 so values >= 2^63 stay exact (int("...") clamps).
static func parse_u64(text: String) -> int:
	var s := text.strip_edges()
	if s.begins_with("0x") or s.begins_with("0X"):
		return _parse_u64_digits(s.substr(2), 16)
	return _parse_u64_digits(s, 10)


static func _parse_u64_digits(s: String, base: int) -> int:
	if s.is_empty():
		push_error("PCG32.parse_u64: empty value")
		return 0
	var acc: int = 0
	for i in s.length():
		var c: int = s.unicode_at(i)
		var d: int = -1
		if c >= 48 and c <= 57:
			d = c - 48
		elif base == 16 and c >= 97 and c <= 102:
			d = c - 97 + 10
		elif base == 16 and c >= 65 and c <= 70:
			d = c - 65 + 10
		if d < 0 or d >= base:
			push_error("PCG32.parse_u64: bad digit in %s" % s)
			return 0
		acc = _add64(_mul64(acc, base), d)
	return acc
