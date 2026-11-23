package sim

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
)

const (
	TickHz = 20
	TickDT = 1.0 / 20.0
	// Bullet radii in tiles, one place for both languages.
	RadiusS = 0.15
	RadiusM = 0.25
	RadiusL = 0.40
	Eps     = 1e-12
)

// SizeRadius maps pattern size letters to tiles.
func SizeRadius(size string) float64 {
	switch size {
	case "S":
		return RadiusS
	case "M":
		return RadiusM
	case "L":
		return RadiusL
	default:
		return RadiusS
	}
}

// LifetimeTicks is ceil(range / speed * TickHz).
func LifetimeTicks(rangeTiles, speed float64) int {
	if speed <= Eps {
		return 1
	}
	return int(math.Ceil(rangeTiles / speed * float64(TickHz)))
}

// SkipSpec is the optional ring skip block.
type SkipSpec struct {
	Consecutive int             `json:"consecutive"`
	Start       json.RawMessage `json:"start"`
}

// PatternDef is one entry from data/patterns.json.
type PatternDef struct {
	ID                    string    `json:"id"`
	Type                  string    `json:"type"`
	Count                 int       `json:"count"`
	SpreadDeg             float64   `json:"spread_deg"`
	Aim                   string    `json:"aim"`
	StartAngleDeg         float64   `json:"start_angle_deg"`
	RotatePerFireDeg      float64   `json:"rotate_per_fire_deg"`
	AngleOffsetCycleDeg   []float64 `json:"angle_offset_cycle_deg"`
	Skip                  *SkipSpec `json:"skip"`
	Speed                 float64   `json:"speed"`
	Range                 float64   `json:"range"`
	Size                  string    `json:"size"`
	DamageKey             string    `json:"damage_key"`
	Trigger               string    `json:"trigger"`
	IntervalTicks         int       `json:"interval_ticks"`
}

type patternFile struct {
	Patterns []PatternDef `json:"patterns"`
}

// Bullet is one emitted shot from a pattern spawn (closed-form).
type Bullet struct {
	Index          int
	AngleRad       float64
	OriginX        float64
	OriginY        float64
	Speed          float64
	RangeTiles     float64
	LifetimeTicks  int
	RadiusTiles    float64
}

// DirX/DirY are Godot 2D: +X = 0, +Y down, clockwise positive.
func DirX(angleRad float64) float64 { return math.Cos(angleRad) }
func DirY(angleRad float64) float64 { return math.Sin(angleRad) }

// PositionAt returns the bullet position at tick time (may be fractional).
func (b Bullet) PositionAt(spawnTick int, timeTicks float64) (x, y float64) {
	elapsed := timeTicks - float64(spawnTick)
	if elapsed < 0 {
		elapsed = 0
	}
	dist := b.Speed * elapsed * TickDT
	return b.OriginX + DirX(b.AngleRad)*dist, b.OriginY + DirY(b.AngleRad)*dist
}

// AliveAt is true if the bullet has not reached lifetime or range at tick.
func (b Bullet) AliveAt(spawnTick, tick int) bool {
	elapsed := tick - spawnTick
	if elapsed < 0 || elapsed >= b.LifetimeTicks {
		return false
	}
	dist := b.Speed * float64(elapsed) * TickDT
	return dist < b.RangeTiles
}

// DegToRad converts data-file degrees to Godot-convention radians.
func DegToRad(deg float64) float64 { return deg * math.Pi / 180.0 }

// LoadPatterns reads data/patterns.json from a repo-root path.
func LoadPatterns(repoRoot string) (map[string]PatternDef, error) {
	raw, err := os.ReadFile(filepath.Join(repoRoot, "data", "patterns.json"))
	if err != nil {
		return nil, err
	}
	var file patternFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	out := make(map[string]PatternDef, len(file.Patterns))
	for _, p := range file.Patterns {
		if p.Count <= 0 {
			p.Count = 1
		}
		if p.Aim == "" {
			p.Aim = "aimed"
		}
		out[p.ID] = p
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no patterns in data/patterns.json")
	}
	return out, nil
}

// EmitBullets evaluates one PatternSpawn into closed-form bullets.
// seed is PatternSpawn.seed; stream is always 1 (see fixtures/README.md).
func EmitBullets(def PatternDef, seed uint64, originX, originY, aimRad float64, volleyIndex int) []Bullet {
	rng := NewPCG32(seed, 1)
	base := baseAngle(def, aimRad, volleyIndex)
	switch def.Type {
	case "fan":
		return emitFan(def, originX, originY, base)
	case "ring":
		return emitRing(def, rng, originX, originY, base)
	default:
		return nil
	}
}

func baseAngle(def PatternDef, aimRad float64, volleyIndex int) float64 {
	angle := aimRad
	if def.Aim == "fixed" {
		angle = DegToRad(def.StartAngleDeg)
	}
	angle += DegToRad(def.RotatePerFireDeg * float64(volleyIndex))
	if n := len(def.AngleOffsetCycleDeg); n > 0 {
		angle += DegToRad(def.AngleOffsetCycleDeg[volleyIndex%n])
	}
	return angle
}

func emitFan(def PatternDef, ox, oy, base float64) []Bullet {
	n := def.Count
	if n < 1 {
		n = 1
	}
	out := make([]Bullet, 0, n)
	if n == 1 {
		out = append(out, newBullet(def, 0, base, ox, oy))
		return out
	}
	spread := DegToRad(def.SpreadDeg)
	step := spread / float64(n-1)
	start := base - spread/2
	for i := 0; i < n; i++ {
		out = append(out, newBullet(def, i, start+float64(i)*step, ox, oy))
	}
	return out
}

func emitRing(def PatternDef, rng *PCG32, ox, oy, base float64) []Bullet {
	n := def.Count
	if n < 1 {
		n = 1
	}
	skipN := 0
	skipStart := 0
	if def.Skip != nil {
		skipN = def.Skip.Consecutive
		skipStart = skipStartIndex(def.Skip, rng, n)
	}
	step := 2 * math.Pi / float64(n)
	out := make([]Bullet, 0, n)
	for i := 0; i < n; i++ {
		if skipN > 0 && inSkip(i, skipStart, skipN, n) {
			continue
		}
		out = append(out, newBullet(def, i, base+float64(i)*step, ox, oy))
	}
	return out
}

func skipStartIndex(skip *SkipSpec, rng *PCG32, count int) int {
	if len(skip.Start) == 0 {
		return 0
	}
	s := string(skip.Start)
	if s == `"rng"` {
		if count <= 0 {
			return 0
		}
		return int(rng.Uint32() % uint32(count))
	}
	var n int
	if err := json.Unmarshal(skip.Start, &n); err != nil {
		return 0
	}
	return n
}

func inSkip(i, start, consecutive, count int) bool {
	for k := 0; k < consecutive; k++ {
		if i == (start+k)%count {
			return true
		}
	}
	return false
}

func newBullet(def PatternDef, index int, angle, ox, oy float64) Bullet {
	return Bullet{
		Index:         index,
		AngleRad:      angle,
		OriginX:       ox,
		OriginY:       oy,
		Speed:         def.Speed,
		RangeTiles:    def.Range,
		LifetimeTicks: LifetimeTicks(def.Range, def.Speed),
		RadiusTiles:   SizeRadius(def.Size),
	}
}
