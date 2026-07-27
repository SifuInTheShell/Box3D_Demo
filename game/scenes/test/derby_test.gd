extends "res://scenes/demo/car_gym.gd"

## Headless derby check: six AI cars (the player car on autopilot too) brawl
## in the bowl for 40 s. Proves the crash stack end to end:
##   contact  — cars actually hit each other (damage accumulated from real
##              body_hit approach speeds across the pack);
##   attrition— welds give: bodywork parts (or wheels) torn off;
##   containment — the arena wall holds every chassis inside the bowl;
##   sanity   — positions finite, and at least one car still drives.
##   Godot --headless --fixed-fps 60 --path game res://scenes/test/derby_test.tscn

const RUN_TICKS := 2400  # 40 s

var _tick_count := 0
var _parts_lost := 0
var _fails := 0


func _init() -> void:
	player_ai = true


func _ready() -> void:
	super()
	for car in _all_cars():
		car.part_lost.connect(func(_part: Box3DBody) -> void: _parts_lost += 1)


func _physics_process(delta: float) -> void:
	super(delta)
	_tick_count += 1
	if _tick_count % 600 == 0:
		var peak := 0.0
		for car in _all_cars():
			peak = maxf(peak, car.peak_weld_force)
		print("[derby] t=%2ds alive=%d/%d damage=%s parts_lost=%d peak_weld=%.0fkN" % [
			_tick_count / 60, _alive_count(), _pack_size,
			_damage_readout(), _parts_lost, peak / 1000.0])
	if _tick_count < RUN_TICKS:
		return

	var total_damage := 0.0
	var inside := true
	var finite := true
	for car in _all_cars():
		total_damage += car.damage
		var pos: Vector3 = car.chassis.global_position
		finite = finite and pos.is_finite()
		inside = inside and Vector2(pos.x, pos.z).length() < ARENA_RADIUS + 4.0
	_check(total_damage > 30.0,
			"the pack traded real hits (total damage %.0f)" % total_damage)
	_check(_parts_lost > 0, "welds gave: %d parts torn off" % _parts_lost)
	_check(inside, "arena wall contained every car")
	_check(finite, "all positions finite")
	_check(_alive_count() >= 1, "at least one car survives")
	print("[derby] RESULT -> %s" % ("PASS" if _fails == 0 else "FAIL (%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)


func _damage_readout() -> String:
	var out := PackedStringArray()
	for car in _all_cars():
		out.append("%.0f" % car.damage)
	return "/".join(out)


func _check(ok: bool, what: String) -> void:
	print("[derby]   %s -> %s" % [what, "ok" if ok else "FAIL"])
	if not ok:
		_fails += 1
