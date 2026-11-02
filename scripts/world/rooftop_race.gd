extends Node3D
## Rooftop race against Mun (quest main_04_rooftop_trials, objective "race").
## Entering Trigger_RaceStart (reach_location "race_start") arms a timed run; reaching the
## "race_finish" quest marker (temple-hall roof) before the limit reports rooftop_race_won.
## Running out of time reports rooftop_race_lost and the race can be retried from the start.

const QUEST := &"main_04_rooftop_trials"
const START_ID := &"race_start"
const FINISH_ID := &"race_finish"
## Seconds added on top of the distance-based limit (route over the roofs is not a straight line).
const SLACK_S := 20.0
## Assumed average rooftop speed (m/s) for the limit; Cam's run is 4.5 m/s.
const AVG_SPEED := 2.2

var time_limit := 90.0
var running := false
var time_left := 0.0
var _finish: Area3D


func _ready() -> void:
	GameEvents.area_entered.connect(_on_area_entered)
	call_deferred(&"_setup")


func _setup() -> void:
	var start := _find_target(START_ID)
	var finish := _find_target(FINISH_ID)
	if start == null or finish == null:
		push_warning("RooftopRace: missing race_start / race_finish quest targets")
		return
	time_limit = start.global_position.distance_to(finish.global_position) / AVG_SPEED + SLACK_S
	_finish = Area3D.new()
	_finish.name = "RaceFinish"
	_finish.collision_layer = 1 << 9  # triggers
	_finish.collision_mask = 1 << 1  # player
	_finish.monitorable = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 4.0)
	cs.shape = box
	cs.position = Vector3(0.0, 1.5, 0.0)
	_finish.add_child(cs)
	add_child(_finish)
	_finish.global_position = finish.global_position
	_finish.body_entered.connect(_on_finish_entered)


func _find_target(id: StringName) -> Node3D:
	for n in get_tree().get_nodes_in_group(&"quest_target"):
		if StringName(str(n.get_meta(&"target_id", ""))) == id and n is Node3D:
			return n as Node3D
	return null


func _race_open() -> bool:
	return QuestManager.is_active(QUEST) and QuestManager.is_objective_active(QUEST, &"race") \
			and not QuestManager.is_objective_done(QUEST, &"race")


func _on_area_entered(id: StringName) -> void:
	if id != START_ID or running or not _race_open():
		return
	running = true
	time_left = time_limit
	GameEvents.notify.emit(tr("RACE_GO").format({"seconds": int(ceil(time_limit))}), &"race")


func _physics_process(delta: float) -> void:
	if not running:
		return
	time_left -= delta
	if time_left <= 0.0:
		running = false
		QuestManager.report(&"rooftop_race_lost", {"rival": "mun"})
		GameEvents.notify.emit(tr("RACE_LOST"), &"race")


func _on_finish_entered(body: Node3D) -> void:
	if not running or not body.is_in_group(&"player"):
		return
	running = false
	QuestManager.report(&"rooftop_race_won", {"rival": "mun", "target_id": String(START_ID), "time": time_limit - time_left})
	GameEvents.notify.emit(tr("RACE_WON"), &"race")
