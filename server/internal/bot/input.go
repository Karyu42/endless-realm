package bot

import (
	"fmt"
	"math"

	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

// Input modes for -input.
const (
	// InputStatic is the original smoke input: move +X, aim 0, fire held.
	InputStatic = "static"
	// InputWander makes each client walk a slowly turning heading, aim
	// perpendicular to it, and hold fire. Used by load tests so players
	// spread over the arena instead of piling against one wall.
	InputWander = "wander"
)

func validInputMode(m string) error {
	switch m {
	case InputStatic, InputWander:
		return nil
	}
	return fmt.Errorf("-input must be %q or %q, got %q", InputStatic, InputWander, m)
}

// inputFor builds the InputFrame for client index i at seq.
func inputFor(mode string, i int, seq uint32) *protocolv1.ClientMessage {
	if mode != InputWander {
		return inputMsg(seq)
	}
	// Golden-angle spread per client; ~0.6 rad/s turn at 20 Hz.
	h := float64(i)*2.399963 + float64(seq)*0.03
	return &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
			Seq:      seq,
			MoveX:    float32(math.Cos(h)),
			MoveY:    float32(math.Sin(h)),
			Aim:      float32(math.Mod(h+math.Pi/2, 2*math.Pi)),
			FireHeld: true,
		}},
	}
}
