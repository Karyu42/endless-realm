class_name PortalPreview
extends RefCounted
## Lobby-browser selection of open portal multipliers (vision §11.4).
## Sorted by M ascending. N <= 5: show all. N > 5: chips at positions
## 0, 1, floor((N-1)/2) (the median), N-2, N-1, plus a "+N-5 more" chip.


static func select(multipliers: Array[float]) -> Array[float]:
	var sorted: Array[float] = multipliers.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n <= 5:
		return sorted
	var mid: int = int(floor(float(n - 1) / 2.0))
	return [sorted[0], sorted[1], sorted[mid], sorted[n - 2], sorted[n - 1]]


static func overflow_count(n: int) -> int:
	return maxi(0, n - 5)
