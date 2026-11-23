package sim

// SegmentCircle reports whether segment AB comes within radius of C.
func SegmentCircle(ax, ay, bx, by, cx, cy, radius float64) bool {
	abx, aby := bx-ax, by-ay
	acx, acy := cx-ax, cy-ay
	abLen2 := abx*abx + aby*aby
	t := 0.0
	if abLen2 > Eps {
		t = (acx*abx + acy*aby) / abLen2
		if t < 0 {
			t = 0
		} else if t > 1 {
			t = 1
		}
	}
	dx := ax + abx*t - cx
	dy := ay + aby*t - cy
	r := radius
	return dx*dx+dy*dy <= r*r
}

// MovingCircles is a swept circle-circle test from tick n-1 to n.
func MovingCircles(a0x, a0y, a1x, a1y, ra, b0x, b0y, b1x, b1y, rb float64) bool {
	return SegmentCircle(b0x-a0x, b0y-a0y, b1x-a1x, b1y-a1y, 0, 0, ra+rb)
}
