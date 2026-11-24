extends GutTest
## LocalSim player-source damage is refused in every zone; enemy-source
## damage still applies.

func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _new_sim() -> LocalSim:
	return LocalSim.new(SimConfig.new(), 5.0, 5.0, _catalog())


func _hearth() -> LocalSim:
	var sim := _new_sim()
	sim.configure_zone(LocalSim.ZONE_HEARTH)
	return sim


func _dungeon() -> LocalSim:
	var sim := _new_sim()
	var def: DungeonDef = _catalog().dungeon("hollowmere_vault")
	assert_not_null(def)
	sim.set_lobby_settings(LobbySettings.new())
	# Player 1 is spawned in LocalSim._init.
	sim.configure_dungeon(def, 42, 100, 1, 1, 1, 1, def.grants_persistent)
	return sim


func _player(sim: LocalSim) -> SimPlayerState:
	var p: SimPlayerState = sim.get_player(1)
	assert_not_null(p)
	if p.hp <= 0:
		p.hp = 100
	return p


func _assert_player_source_refused(sim: LocalSim) -> void:
	var p := _player(sim)
	var hp: int = p.hp
	assert_false(sim._hurt_player(p, 10, 1, LocalSim.DamageSource.PLAYER, 2))
	assert_eq(p.hp, hp, "player-source damage does not change HP")
	assert_push_error(LocalSim.PLAYER_DAMAGE_REFUSED_LOG)


func _assert_enemy_source_damages(sim: LocalSim) -> void:
	var p := _player(sim)
	var hp: int = p.hp
	assert_true(sim._hurt_player(p, 10, 1, LocalSim.DamageSource.ENEMY, 100))
	assert_eq(p.hp, hp - 10, "enemy-source damage still applies")


func test_player_source_hit_leaves_hp_unchanged_in_the_wilds() -> void:
	_assert_player_source_refused(_new_sim())


func test_player_source_hit_leaves_hp_unchanged_in_the_hearth() -> void:
	_assert_player_source_refused(_hearth())


func test_player_source_hit_leaves_hp_unchanged_in_a_dungeon() -> void:
	_assert_player_source_refused(_dungeon())


func test_enemy_source_hit_still_damages_in_each_zone() -> void:
	_assert_enemy_source_damages(_new_sim())
	_assert_enemy_source_damages(_hearth())
	_assert_enemy_source_damages(_dungeon())


func test_default_hurt_source_is_enemy() -> void:
	var sim := _new_sim()
	var p := _player(sim)
	var hp: int = p.hp
	assert_true(sim._hurt_player(p, 7))
	assert_eq(p.hp, hp - 7)


func test_player_source_refusal_logs_once_per_attacker_and_target() -> void:
	var sim := _new_sim()
	var p := _player(sim)
	var hp: int = p.hp
	for i in range(20):
		assert_false(sim._hurt_player(p, 10, 1, LocalSim.DamageSource.PLAYER, 2))
	assert_eq(p.hp, hp)
	assert_push_error(LocalSim.PLAYER_DAMAGE_REFUSED_LOG)
	# A different attacker is a new pair.
	assert_false(sim._hurt_player(p, 10, 1, LocalSim.DamageSource.PLAYER, 3))
	assert_eq(p.hp, hp)
	assert_push_error_count(2)
