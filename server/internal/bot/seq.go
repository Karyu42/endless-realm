package bot

// seqNewer reports whether a is ahead of b in uint32 serial-number space.
// It is true when uint32(a-b) is in [1, 2^31).
func seqNewer(a, b uint32) bool {
	if a == 0 {
		return false
	}
	d := a - b
	return d >= 1 && d < 1<<31
}

// seqIsNext reports whether seq should be applied after last. A last of 0
// means nothing has been received yet and any seq >= 1 is accepted.
func seqIsNext(seq, last uint32) bool {
	if seq == 0 {
		return false
	}
	if last == 0 {
		return seq >= 1
	}
	return seqNewer(seq, last)
}
