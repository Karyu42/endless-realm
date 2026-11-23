extends GutTest
## Bag view pool must not reuse a gold view for a brown bag.


func test_released_gold_bag_view_does_not_tint_a_brown_bag() -> void:
	var arena_script := load("res://src/render/arena.gd")
	var arena: Node2D = arena_script.new()
	add_child_autofree(arena)
	var parent := Node2D.new()
	arena.add_child(parent)
	var pool: Dictionary = {}
	var free: Array[Polygon2D] = []
	var gold: Color = arena_script.BAG_GOLD
	var brown: Color = arena_script.BAG_BROWN
	var gold_view: Polygon2D = arena._acquire_view(parent, pool, free, 10, gold, 6.0, "diamond")
	assert_eq(gold_view.color, gold)
	arena._release_unused(pool, free, {})
	assert_eq(free.size(), 1)
	var brown_view: Polygon2D = arena._acquire_view(parent, pool, free, 11, brown, 6.0, "diamond")
	assert_eq(brown_view.color, brown, "a recycled gold bag must not render brown as gold")
	assert_ne(brown_view.color, gold)
