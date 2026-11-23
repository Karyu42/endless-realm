extends GutTest
## Lobby-browser portal multiplier selection (vision §11.4).


func test_five_or_fewer_are_shown_sorted() -> void:
	var five: Array[float] = [1.2, 0.5, 1.0, 0.8, 1.5]
	assert_eq(PortalPreview.select(five), [0.5, 0.8, 1.0, 1.2, 1.5])
	assert_eq(PortalPreview.overflow_count(5), 0)
	var two: Array[float] = [1.4, 0.6]
	assert_eq(PortalPreview.select(two), [0.6, 1.4])
	var empty: Array[float] = []
	assert_eq(PortalPreview.select(empty), [])


func test_more_than_five_uses_median_and_overflow_chip() -> void:
	# Vision §11.4 example: N=7 → 0.50, 0.80, 1.00 (position 3), 1.35, 1.50, "+2 more".
	var many: Array[float] = [0.50, 0.80, 1.00, 1.00, 1.20, 1.35, 1.50]
	var picked := PortalPreview.select(many)
	assert_eq(picked, [0.50, 0.80, 1.00, 1.35, 1.50])
	assert_eq(PortalPreview.overflow_count(many.size()), 2)


func test_median_position_is_floor_of_n_minus_one_over_two() -> void:
	var six: Array[float] = [0.5, 0.7, 0.9, 1.1, 1.3, 1.5]
	# positions 0, 1, floor(5/2)=2, 4, 5
	assert_eq(PortalPreview.select(six), [0.5, 0.7, 0.9, 1.3, 1.5])
	assert_eq(PortalPreview.overflow_count(6), 1)
