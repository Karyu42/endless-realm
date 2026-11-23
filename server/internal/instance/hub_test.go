package instance

import (
	"testing"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

func TestHubPartyCapAndOpenLimit(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(0, 0))
	def, err := New(1, 100, clk)
	if err != nil {
		t.Fatal(err)
	}
	h := NewHub(ctx, def)
	_, info, err := h.OpenAndJoin(105, 1, DefaultInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	id := info.ID
	for p := uint32(2); p <= uint32(MaxParty); p++ {
		if _, _, err := h.Join(id, p, DefaultInstanceID); err != nil {
			t.Fatalf("join player %d: %v", p, err)
		}
	}
	if _, _, err := h.Join(id, uint32(MaxParty+1), DefaultInstanceID); err != ErrFull {
		t.Fatalf("player %d: err=%v, want ErrFull", MaxParty+1, err)
	}
	// Opener already used their one open portal, even after leaving.
	if _, info, err := h.Join(DefaultInstanceID, 1, id); err != nil {
		t.Fatal(err)
	} else if !info.Default {
		t.Fatal("expected to be back on default")
	}
	if _, _, err := h.OpenAndJoin(50, 1, DefaultInstanceID); err != ErrOpenLimit {
		t.Fatalf("second open: %v, want ErrOpenLimit", err)
	}
	// Invalid m100 creates nothing.
	before := len(h.List())
	if _, _, err := h.OpenAndJoin(49, 2, DefaultInstanceID); err == nil {
		t.Fatal("want invalid m100 error")
	}
	if len(h.List()) != before {
		t.Fatal("invalid open created an instance")
	}
}
