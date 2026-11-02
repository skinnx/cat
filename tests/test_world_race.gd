extends "res://tests/test_base.gd"
## Rooftop race (scripts/world/rooftop_race.gd): touching the start only arms the race;
## the quest objective completes at the finish, and a timeout resets it.

const RaceScript := preload("res://scripts/world/rooftop_race.gd")
const QUEST := &"main_04_rooftop_trials"


func _setup_world() -> Array:
	GameState.new_game()
	QuestManager.quest_dirs = PackedStringArray(["res://data/quests"])
	QuestManager.reload_definitions()
	TimeOfDay.set_hour(19.0)
	assert_true(QuestManager.start_quest(QUEST, true), "quest started")
	QuestManager.report(&"talk_to", {"npc_id": "mun"})
	assert_true(QuestManager.is_objective_active(QUEST, &"race"), "race objective active")
	var root := Node3D.new()
	tree.root.add_child(root)
	for t: Array in [["race_start", Vector3(0, 0, 0)], ["race_finish", Vector3(40, 0, 0)]]:
		var m := Marker3D.new()
		m.add_to_group(&"quest_target")
		m.set_meta(&"target_id", t[0])
		root.add_child(m)
		m.global_position = t[1]
	var race := Node3D.new()
	race.set_script(RaceScript)
	root.add_child(race)
	var cat := CharacterBody3D.new()
	cat.add_to_group(&"player")
	root.add_child(cat)
	await tree.process_frame
	return [root, race, cat]


func test_start_does_not_win_and_finish_does() -> void:
	var w: Array = await _setup_world()
	var race: Node3D = w[1]
	assert_true(float(race.get(&"time_limit")) > 40.0 / 2.2, "time limit from distance")
	race.call(&"_on_finish_entered", w[2])
	assert_false(QuestManager.is_objective_done(QUEST, &"race"), "finish without start does nothing")
	GameEvents.area_entered.emit(&"race_start")
	assert_true(bool(race.get(&"running")), "start arms the race")
	assert_false(QuestManager.is_objective_done(QUEST, &"race"), "touching the start never wins")
	race.call(&"_on_finish_entered", w[2])
	assert_true(QuestManager.is_objective_done(QUEST, &"race"), "finish in time wins")
	assert_false(bool(race.get(&"running")))
	(w[0] as Node).queue_free()


func test_timeout_resets_race() -> void:
	var w: Array = await _setup_world()
	var race: Node3D = w[1]
	GameEvents.area_entered.emit(&"race_start")
	race.call(&"_physics_process", float(race.get(&"time_limit")) + 1.0)
	assert_false(bool(race.get(&"running")), "timed out")
	race.call(&"_on_finish_entered", w[2])
	assert_false(QuestManager.is_objective_done(QUEST, &"race"), "late finish does not count")
	GameEvents.area_entered.emit(&"race_start")
	assert_true(bool(race.get(&"running")), "can retry from the start")
	(w[0] as Node).queue_free()
