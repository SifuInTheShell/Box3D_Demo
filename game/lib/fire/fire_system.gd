extends Node3D

## The bridge between FireSim (systems/fire: pure, deterministic propagation
## model) and the physics gym -- water_fx.gd's pattern applied to fire.
##
## Sweeps bodies in the "flammable" group into the sim, mirrors their
## positions each sim tick, and turns sim events into engine effects:
## ignited bodies get burn_fx.gd flames and weaken via set_burn(); burnt-out
## bodies crumble via burned_out(); bodies that end up in water are doused.
## Heat sources from the rest of the gym pour in through two channels:
## explosions call blast_heat() via the "fire_system" group, and lingering
## ground pyres (fire_fx.gd, "ground_fire" group) radiate while they burn.
##
##   FireSystem.attach(world)           # once per gym, after the world exists
##   call_group("fire_system", "blast_heat", at, radius, impulse)

const _Self = preload("res://lib/fire/fire_system.gd")
const BurnFX = preload("res://lib/fire/burn_fx.gd")
const WaterFX = preload("res://lib/water/water_fx.gd")

const SIM_DT := 0.2    # 5 Hz, the survey's low-frequency global fire tick
const SIM_RATE := 0.44 # fire advances at this fraction of real time, so it
                       # visibly WALKS a structure instead of flashing it over
                       # in a second. Slows spread and burn-through together;
                       # heat pulses (torch/blast) are instant, so the ignition
                       # point still lights at once -- only propagation slows.
                       # Only the live gym is affected: fire_sim_test drives the
                       # sim directly at full rate, so its checks are unchanged.
const SWEEP := 0.5     # seconds between flammable-group registration sweeps
const BLAST_HEAT := 5200.0   # heat energy per unit of blast impulse
const TORCH_HEAT := 40000.0  # hand-ignition pulse (instant, small radius)
const DOUSE_RATE := 0.5      # douse amount per sim tick while underwater

var wind := Vector3.ZERO:
	set(v):
		wind = v
		_sim.wind = v

var _sim := FireSim.new()
var _bodies := {}   # sim id (instance_id) -> body
var _fx := {}       # sim id -> BurnFX node (only while one is attached)
var _acc := 0.0
var _sweep_t := 0.0


static func attach(world: Node3D) -> Node3D:
	var fs := _Self.new()
	world.add_child(fs)
	return fs


func _ready() -> void:
	add_to_group("fire_system")


func burning_count() -> int:
	var n := 0
	for id in _bodies:
		var s: int = _sim.state(id)
		if s == FireSim.BURNING or s == FireSim.SMOLDERING:
			n += 1
	return n


## XZ positions of everything currently burning -- for spatial checks that need
## to tell a fire inside the demolition area from one that has spread out into
## the surroundings.
func burning_positions() -> PackedVector2Array:
	var out := PackedVector2Array()
	for id in _bodies:
		var s: int = _sim.state(id)
		if s == FireSim.BURNING or s == FireSim.SMOLDERING:
			var b = _bodies[id]
			if is_instance_valid(b):
				out.append(Vector2(b.global_position.x, b.global_position.z))
	return out


func registered_count() -> int:
	return _bodies.size()


## Explosion coupling (ExplosionFX.blast broadcasts to the group): pour a
## radial heat pulse into everything flammable near the blast.
func blast_heat(at: Vector3, radius: float, impulse: float) -> void:
	_sim.add_heat(at, radius * 1.1, BLAST_HEAT * impulse)


## Hand-ignition (gym tools): a torch-sized pulse -- enough to light
## kindling on the spot, thick timber still needs a real fire around it.
func torch(at: Vector3, radius := 1.2) -> void:
	_sim.add_heat(at, radius, TORCH_HEAT)


## Water spray (gym tools): douse everything registered within the radius.
func douse_at(at: Vector3, radius: float, amount: float) -> void:
	for id in _bodies.keys():
		var body = _bodies[id]
		if not is_instance_valid(body) \
				or body.global_position.distance_to(at) > radius:
			continue
		_sim.douse(id, amount)
		var fx = _fx.get(id)
		if fx == null or not is_instance_valid(fx):
			continue
		var st: int = _sim.state(id)
		if st == FireSim.SMOLDERING:
			fx.smolder()
		elif st != FireSim.BURNING:
			fx.die()
			_fx.erase(id)


func _physics_process(delta: float) -> void:
	_sweep_t += delta
	if _sweep_t >= SWEEP:
		_sweep_t = 0.0
		_sweep()
	_acc += delta
	if _acc < SIM_DT:
		return
	_acc = fmod(_acc, SIM_DT)
	_tick()


## Registration: adopt new flammable bodies, drop freed ones.
func _sweep() -> void:
	for body in get_tree().get_nodes_in_group("flammable"):
		if body == null or not is_instance_valid(body) or not body is Node3D:
			continue
		var id: int = body.get_instance_id()
		if _bodies.has(id):
			continue
		var prof: Dictionary = body.fire_profile() if body.has_method("fire_profile") \
				else {"half": Vector3.ONE * 0.4, "moisture": 0.0, "fuel_scale": 1.0}
		_sim.add_item(id, body.global_position, prof["half"],
				prof.get("moisture", 0.0), prof.get("fuel_scale", 1.0),
				prof.get("thickness", 0.0))
		_bodies[id] = body
		# Debris of a burning wall arrives already alight (breakable_block
		# spawn handoff) -- restore its char so it doesn't burn from scratch.
		if body.has_meta("born_burning"):
			_sim.items[id]["char"] = clampf(body.get_meta("burn_char", 0.0), 0.0, 0.95)
			_sim.ignite(id)
			body.remove_meta("born_burning")
	# Retry FX attach for burning bodies that lost the visual-budget race.
	for id in _bodies:
		if _sim.state(id) == FireSim.BURNING and not _fx.has(id):
			var body = _bodies[id]
			if is_instance_valid(body):
				var fx = BurnFX.attach(body, _sim.items[id]["half"])
				if fx != null:
					_fx[id] = fx


func _tick() -> void:
	# Mirror positions in; drop freed bodies; douse anything in water.
	for id in _bodies.keys():
		var body = _bodies[id]
		if not is_instance_valid(body) or body.is_queued_for_deletion():
			_release(id)
			continue
		_sim.update_pos(id, body.global_position)
		if body.is_in_group(WaterFX.WET_GROUP):
			_sim.douse(id, DOUSE_RATE)

	# Ground pyres radiate: explosions leave fires that can light buildings.
	for pyre in get_tree().get_nodes_in_group("ground_fire"):
		if pyre != null and is_instance_valid(pyre) and pyre.has_method("heat_output"):
			var h: Dictionary = pyre.heat_output()
			if h["output"] > 0.0:
				_sim.add_heat(h["pos"], h["radius"], h["output"] * SIM_DT * SIM_RATE)

	_sim.step(SIM_DT * SIM_RATE)

	for e in _sim.events:
		var id: int = e["id"]
		var body = _bodies.get(id)
		if body == null or not is_instance_valid(body):
			continue
		match e["event"]:
			"ignited", "rekindled":
				body.set_meta("on_fire", true)
				body.add_to_group("on_fire")
				var fx = _fx.get(id)
				if fx != null and is_instance_valid(fx):
					fx.flame()
				else:
					fx = BurnFX.attach(body, _sim.items[id]["half"])
					if fx != null:
						_fx[id] = fx
			"smolder":
				var fx2 = _fx.get(id)
				if fx2 != null and is_instance_valid(fx2):
					fx2.smolder()
			"cold":
				body.remove_meta("on_fire")
				body.remove_from_group("on_fire")
				_drop_fx(id)
			"burnout":
				_drop_fx(id)
				_bodies.erase(id)
				_sim.remove_item(id)
				if body.has_method("burned_out"):
					body.burned_out()
				else:
					body.queue_free()

	# Weakening + FX intensity for everything still aflame. Metadata is
	# (re)stamped here rather than only on the ignition event: torch/blast
	# ignitions and douses can land between steps, whose events the next
	# step discards -- so cold cleanup lives here too.
	for id in _bodies:
		var body = _bodies[id]
		if not is_instance_valid(body):
			continue
		if _sim.state(id) != FireSim.BURNING:
			if _sim.state(id) == FireSim.COLD and body.has_meta("on_fire"):
				body.remove_meta("on_fire")
				body.remove_from_group("on_fire")
				_drop_fx(id)
			continue
		var char_frac: float = _sim.charring(id)
		body.set_meta("on_fire", true)
		body.set_meta("burn_char", char_frac)
		if body.has_method("set_burn"):
			body.set_burn(char_frac, _sim.strength(id))
		var fx = _fx.get(id)
		if fx != null and is_instance_valid(fx):
			fx.set_intensity(_sim.intensity(id))


func _release(id: int) -> void:
	_drop_fx(id)
	_bodies.erase(id)
	_sim.remove_item(id)


func _drop_fx(id: int) -> void:
	var fx = _fx.get(id)
	if fx != null and is_instance_valid(fx):
		fx.die()
	_fx.erase(id)
