package sim

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
)

const fixtureEps = 1e-9

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

func TestPCG32KnownVectors(t *testing.T) {
	root := repoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "fixtures", "pcg32", "known.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []struct {
			InitState string   `json:"initstate"`
			InitSeq   string   `json:"initseq"`
			Values    []uint32 `json:"values"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cases) == 0 {
		t.Fatal("no PCG32 cases")
	}
	for _, c := range doc.Cases {
		state, err := ParseU64(c.InitState)
		if err != nil {
			t.Fatal(err)
		}
		seq, err := ParseU64(c.InitSeq)
		if err != nil {
			t.Fatal(err)
		}
		rng := NewPCG32(state, seq)
		for i, want := range c.Values {
			got := rng.Uint32()
			if got != want {
				t.Fatalf("init(%s,%s) [%d]=%d, want %d", c.InitState, c.InitSeq, i, got, want)
			}
		}
	}
}

type patternCase struct {
	Name        string                     `json:"name"`
	PatternID   string                     `json:"pattern_id"`
	Seed        string                     `json:"seed"`
	SpawnTick   int                        `json:"spawn_tick"`
	Origin      []float64                  `json:"origin"`
	AimRad      float64                    `json:"aim_rad"`
	VolleyIndex int                        `json:"volley_index"`
	Ticks       []int                      `json:"ticks"`
	Expected    map[string][]expectedPoint `json:"expected"`
}

type expectedPoint struct {
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	Index *int    `json:"index"`
}

func TestPatternFixtures(t *testing.T) {
	root := repoRoot(t)
	patterns, err := LoadPatterns(root)
	if err != nil {
		t.Fatal(err)
	}
	extra, err := LoadPatternFile(filepath.Join(root, "fixtures", "patterns", "defs.json"))
	if err != nil {
		t.Fatal(err)
	}
	for id, def := range extra {
		patterns[id] = def
	}
	files, err := filepath.Glob(filepath.Join(root, "fixtures", "patterns", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no pattern fixtures")
	}
	for _, f := range files {
		if filepath.Base(f) == "defs.json" {
			// Fixtures-only pattern pack, not a case file.
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var doc struct {
			Cases []patternCase `json:"cases"`
		}
		if err := json.Unmarshal(raw, &doc); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		for _, c := range doc.Cases {
			c := c
			t.Run(c.Name, func(t *testing.T) {
				def, ok := patterns[c.PatternID]
				if !ok {
					t.Fatalf("unknown pattern %s", c.PatternID)
				}
				seed, err := ParseU64(c.Seed)
				if err != nil {
					t.Fatal(err)
				}
				ox, oy := c.Origin[0], c.Origin[1]
				bullets := EmitBullets(def, seed, ox, oy, c.AimRad, c.VolleyIndex)
				for _, tick := range c.Ticks {
					want := c.Expected[strconv.Itoa(tick)]
					var got []Bullet
					for _, b := range bullets {
						if b.AliveAt(c.SpawnTick, tick) {
							got = append(got, b)
						}
					}
					if len(got) != len(want) {
						t.Fatalf("tick %d: got %d bullets, want %d", tick, len(got), len(want))
					}
					for i, w := range want {
						if w.Index != nil && got[i].Index != *w.Index {
							t.Fatalf("tick %d bullet %d: index %d, want %d", tick, i, got[i].Index, *w.Index)
						}
						x, y := got[i].PositionAt(c.SpawnTick, float64(tick))
						if math.Abs(x-w.X) > fixtureEps || math.Abs(y-w.Y) > fixtureEps {
							t.Fatalf("tick %d bullet %d: got (%g,%g), want (%g,%g)", tick, i, x, y, w.X, w.Y)
						}
					}
				}
			})
		}
	}
}

func TestSweptHitCatchesTunneling(t *testing.T) {
	// A size-S bullet travelling 2 tiles in one tick through a 0.30-radius target at the midpoint.
	if !MovingCircles(0, 0, 2, 0, 0.15, 1, 0, 1, 0, 0.30) {
		t.Fatal("expected a hit on a target sitting on the path")
	}
	if MovingCircles(0, 0, 2, 0, 0.15, 1, 3, 1, 3, 0.30) {
		t.Fatal("did not expect a hit far off the path")
	}
}

func TestLifetimeTicks(t *testing.T) {
	if n := LifetimeTicks(6, 6); n != 20 {
		t.Fatalf("burr_spit lifetime %d, want 20", n)
	}
	if n := LifetimeTicks(7, 14); n != 10 {
		t.Fatalf("gleamwright-like lifetime %d, want 10", n)
	}
}

func TestParseU64(t *testing.T) {
	hexV, err := ParseU64("0x8000000000000001")
	if err != nil {
		t.Fatal(err)
	}
	decV, err := ParseU64("9223372036854775809")
	if err != nil {
		t.Fatal(err)
	}
	if hexV != decV || hexV != 0x8000000000000001 {
		t.Fatalf("got hex=%d dec=%d", hexV, decV)
	}
	fortyTwo, err := ParseU64("0x2a")
	if err != nil || fortyTwo != 42 {
		t.Fatalf("0x2a -> %d, %v", fortyTwo, err)
	}
}
