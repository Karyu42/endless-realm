class_name PortalPreview
extends RefCounted
## Lobby-browser selection of open portal multipliers.
## If more than 5 portals are open, show at least the 2 lowest and 2 highest.


static func select(multipliers: Array[float]) -> Array[float]:
	var sorted: Array[float] = multipliers.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n <= 5:
		return sorted
	var picked: Array[float] = [sorted[0], sorted[1]]
	# Fill up to 5 with the remaining value closest to 1.00, then the two highest.
	var mid: Array[float] = []
	for i in range(2, n - 2):
		mid.append(sorted[i])
	if not mid.is_empty():
		var best: float = mid[0]
		var best_d: float = absf(best - 1.0)
		for i in range(1, mid.size()):
			var d: float = absf(mid[i] - 1.0)
			if d < best_d:
				best = mid[i]
				best_d = d
		picked.append(best)
	picked.append(sorted[n - 2])
	picked.append(sorted[n - 1])
	return picked
