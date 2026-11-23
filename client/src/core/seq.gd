class_name Seq
extends Object
## uint32 serial-number comparison for InputFrame.seq (RFC 1982 style).
##
## Client game_session.gd wraps _seq from 0xFFFFFFFF back to 1 (0 is skipped).
## A last value of 0 means nothing has been received yet.


## True when a is ahead of b: ((a - b) & 0xFFFFFFFF) is in [1, 2^31).
static func seq_newer(a: int, b: int) -> bool:
	if a == 0:
		return false
	var d: int = (a - b) & 0xFFFFFFFF
	return d >= 1 and d < 0x80000000


## True when seq should be applied after last. last == 0 accepts any seq >= 1.
static func seq_is_next(seq: int, last: int) -> bool:
	if seq == 0:
		return false
	if last == 0:
		return seq >= 1
	return seq_newer(seq, last)
