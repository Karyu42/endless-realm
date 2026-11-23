extends GutTest
## Lobby-browser portal multiplier selection.


func test_five_or_fewer_are_shown_sorted() -> void:
	var five: Array[float] = [1.2, 0.5, 1.0, 0.8, 1.5]
	assert_eq(PortalPreview.select(five), [0.5, 0.8, 1.0, 1.2, 1.5])
	var two: Array[float] = [1.4, 0.6]
	assert_eq(PortalPreview.select(two), [0.6, 1.4])
	var empty: Array[float] = []
	assert_eq(PortalPreview.select(empty), [])


func test_more_than_five_keeps_two_lowest_and_two_highest() -> void:
	var many: Array[float] = [0.5, 0.6, 0.7, 0.8, 1.0, 1.2, 1.4, 1.5]
	var picked := PortalPreview.select(many)
	assert_eq(picked.size(), 5)
	assert_eq(picked[0], 0.5)
	assert_eq(picked[1], 0.6)
	assert_eq(picked[picked.size() - 2], 1.4)
	assert_eq(picked[picked.size() - 1], 1.5)
	assert_eq(picked[2], 1.0)


func test_mid_slot_is_closest_to_one() -> void:
	var six: Array[float] = [0.5, 0.7, 0.9, 1.1, 1.3, 1.5]
	var picked := PortalPreview.select(six)
	assert_eq(picked, [0.5, 0.7, 0.9, 1.3, 1.5])
