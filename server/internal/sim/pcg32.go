// Package sim is the shared combat-sim contract: PCG32, closed-form bullet
// patterns, and swept hit tests. Godot has a GDScript twin; golden fixtures
// in fixtures/ must match on both sides.
package sim

import (
	"strconv"
	"strings"
)

// PCG-XSH-RR 64/32 (Melissa O'Neill). State is uint64, output is uint32.
// Do not replace this with math/rand.

const pcgMult uint64 = 6364136223846793005

// PCG32 is a PCG-XSH-RR 64/32 generator.
type PCG32 struct {
	state uint64
	inc   uint64
}

// NewPCG32 is official pcg32_srandom: initseq selects the stream (must be
// used as (initseq<<1)|1). Pattern spawns use NewPCG32(seed, 1).
func NewPCG32(initstate, initseq uint64) *PCG32 {
	r := &PCG32{state: 0, inc: (initseq << 1) | 1}
	r.Uint32()
	r.state += initstate
	r.Uint32()
	return r
}

// Uint32 returns the next 32-bit output.
func (r *PCG32) Uint32() uint32 {
	old := r.state
	r.state = old*pcgMult + r.inc
	xorshifted := uint32(((old >> 18) ^ old) >> 27)
	rot := uint32(old >> 59)
	return (xorshifted >> rot) | (xorshifted << ((-rot) & 31))
}

// ParseU64 reads a fixture u64 written as a decimal string or as 0x hex.
// Both Go and GDScript use this format so values >= 2^63 stay bit-exact.
func ParseU64(s string) (uint64, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "0x") || strings.HasPrefix(s, "0X") {
		return strconv.ParseUint(s[2:], 16, 64)
	}
	return strconv.ParseUint(s, 10, 64)
}
