extends Node

## The bridge between WindSim (systems/wind: pure, seeded weather) and
## everything that feels it — fire_system's pattern applied to wind. One
## per site/gym:
##
##   WindSystem.attach(world, Vector3(4, 0, 0), 0.5, seed)
##
## Each physics tick it advances the sim and publishes the current vector:
##   - every "fire_system" gets .wind (spread skew, the sim coupling)
##   - the "wind_vec" global shader parameter (cloth sway, flame sheets)
##   - bodies in the opt-in "wind_blown" group get a real push — LIGHT
##     things only (cones, bins, mailboxes opt in with a per-prop "sail"
##     meta = m/s² of acceleration per m/s of wind). Nothing below
##     BLOW_MIN_SPEED, so props sleep through a breeze and only a real
##     wind (or a squall) shoves them. Heavy structure never opts in:
##     weather moves fire, dust, laundry and litter — not concrete.
## Driven from _physics_process: wind is a pure function of the tick, so
## every push replays bit-identically under the fixed-tick harness.

const _Self = preload("res://lib/wind/wind_system.gd")

const BLOWN_GROUP := "wind_blown"
const BLOW_MIN_SPEED := 3.0  # below this, light props get to sleep

var _sim: WindSim


static func attach(world: Node, base: Vector3, gust: float, seed_v: int) -> Node:
	var ws := _Self.new()
	ws._sim = WindSim.new(seed_v, base, gust)
	world.add_child(ws)
	return ws


func _ready() -> void:
	add_to_group("wind_system")
	_publish()


func _exit_tree() -> void:
	# The shader global outlives the site; a calm next scene must not
	# inherit our weather.
	RenderingServer.global_shader_parameter_set("wind_vec", Vector3.ZERO)


func set_base(base: Vector3, gust := -1.0) -> void:
	_sim.base = Vector3(base.x, 0.0, base.z)
	if gust >= 0.0:
		_sim.gust = clampf(gust, 0.0, 1.0)
	_publish()


func current() -> Vector3:
	return _sim.current()


func gust01() -> float:
	return _sim.gust01()


func _physics_process(delta: float) -> void:
	_sim.update(delta)
	_publish()
	_blow(delta)


## The physical coupling: shove opted-in light bodies. Impulse scales with
## the body's own mass (sail = acceleration per m/s of wind), so one sail
## value behaves the same across Box3D's mass range; squalls hit harder.
func _blow(delta: float) -> void:
	var w := _sim.current()
	var speed := w.length()
	if speed < BLOW_MIN_SPEED:
		return
	var boost := 0.5 + _sim.gust01()
	for body in get_tree().get_nodes_in_group(BLOWN_GROUP):
		if body is Box3DBody and is_instance_valid(body) \
				and body.body_type == Box3DBody.DYNAMIC:
			# Drag is QUADRATIC in wind speed (real aerodynamics, and the
			# game feel that matters: a breeze wobbles a cone, a squall
			# tips it). Applied ABOVE the centre so wind torque can beat
			# the friction-pinned base — a central push just loses to
			# friction. apply_impulse wakes sleeping bodies by itself.
			body.apply_impulse(w * speed * float(body.get_meta("sail", 0.02))
					* boost * body.get_mass() * delta,
					body.global_position + Vector3.UP * 0.25)


func _publish() -> void:
	var w := _sim.current()
	for fs in get_tree().get_nodes_in_group("fire_system"):
		fs.wind = w
	RenderingServer.global_shader_parameter_set("wind_vec", w)
