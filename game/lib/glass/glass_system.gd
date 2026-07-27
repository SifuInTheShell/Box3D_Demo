extends Node3D

## The bridge between GlassSim (systems/glass: overpressure, heat, ledger)
## and the gym -- fire_system.gd's pattern applied to glazing.
##
## Sweeps bodies in the "glass" group into the sim; explosions broadcast
## blast_wave() here and the sim decides which panes fail (overpressure
## reaches several times the structural radius -- the collateral indicator);
## breaks are staggered outward so big blasts read as a travelling wave of
## bursting windows. Fires pour heat onto nearby panes until they pop.
## The ledger (broken count/area per target/protected/neutral tag) feeds
## gym HUDs: broken protected glass is the visible "you rattled the
## neighbourhood" warning.
##
##   GlassSystem.attach(world)
##   call_group("glass_system", "blast_wave", at, radius, impulse)

const _Self = preload("res://lib/glass/glass_system.gd")

const SWEEP := 0.5          # registration / heat / cleanup cadence
const WAVE_SPEED := 55.0    # m/s the visual shatter wave travels at
const SHARD_LIFE_TICKS := 480  # cosmetic shard lifetime (physics frames)
const FIRE_HEAT := 26.0     # heat energy per sweep from an adjacent fire

var _sim := GlassSim.new()
var _panes := {}   # sim id (instance_id) -> pane body
var _sweep_t := 0.0


static func attach(world: Node3D) -> Node3D:
	var gs := _Self.new()
	world.add_child(gs)
	return gs


func _ready() -> void:
	add_to_group("glass_system")


## Ledger snapshot for HUDs: {"total": int, "protected": {...}, ...}.
func report() -> Dictionary:
	return {
		"total": _sim.total_broken(),
		"target": _sim.broken("target"),
		"protected": _sim.broken("protected"),
		"neutral": _sim.broken("neutral"),
	}


func pane_count() -> int:
	return _panes.size()


## The overpressure ring for a charge: planner UIs draw this as the
## glass-warning circle.
func warning_radius(w_kg: float) -> float:
	return GlassSim.break_distance(w_kg)


## Explosion coupling: radius -> TNT mass via the gym charge calibration,
## then let the sim break everything in the overpressure ring, staggered
## outward at WAVE_SPEED for the travelling-wave look.
func blast_wave(at: Vector3, radius: float, _impulse: float) -> void:
	var w := BlastPlan.w_for_radius(radius)
	var broken: Array = _sim.blast(at, w)
	for id in broken:
		var pane = _panes.get(id)
		_panes.erase(id)
		if pane == null or not is_instance_valid(pane):
			continue
		var dist: float = at.distance_to(pane.global_position)
		var energy := clampf(
				GlassSim.overpressure_kpa(w, dist) / (GlassSim.BREAK_KPA * 6.0),
				0.25, 1.0)
		var delay := dist / WAVE_SPEED
		if delay < 0.03:
			pane.shatter(at, energy)
			continue
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(pane):
				pane.shatter(at, energy))


## A pane reported a hard contact (or the blast inner sweep): the sim keeps
## the ledger, then the pane bursts at the reported point.
func pane_impact(pane: Node3D, rel_speed: float, at: Vector3) -> void:
	if pane == null or not is_instance_valid(pane):
		return
	var id := pane.get_instance_id()
	if not _sim.has_pane(id):
		return
	if _sim.impact(id, rel_speed):
		_panes.erase(id)
		pane.shatter(at, clampf(rel_speed / 8.0, 0.2, 1.0))


func _physics_process(delta: float) -> void:
	_sweep_t += delta
	if _sweep_t < SWEEP:
		return
	_sweep_t = 0.0
	_sweep()


func _sweep() -> void:
	# Register new panes, drop freed ones, mirror positions.
	for pane in get_tree().get_nodes_in_group("glass"):
		if pane == null or not is_instance_valid(pane) or not pane is Node3D:
			continue
		var id: int = pane.get_instance_id()
		if _panes.has(id):
			continue
		var size: Vector3 = pane.box_size
		var dims := [size.x, size.y, size.z]
		dims.sort()
		_sim.add_pane(id, pane.global_position, dims[1] * dims[2],
				pane.get("glass_tag") if pane.get("glass_tag") != null else "neutral")
		_panes[id] = pane
	for id in _panes.keys():
		var pane = _panes[id]
		if not is_instance_valid(pane) or pane.is_queued_for_deletion():
			_panes.erase(id)
			_sim.remove_pane(id)
			continue
		_sim.update_pos(id, pane.global_position)

	# Fire heat: pyres and burning bodies cook nearby panes until they pop.
	_sim.cool(SWEEP)
	var popped: Array = []
	for pyre in get_tree().get_nodes_in_group("ground_fire"):
		if pyre != null and is_instance_valid(pyre) and pyre.has_method("heat_output"):
			var h: Dictionary = pyre.heat_output()
			if h["output"] > 0.0:
				popped.append_array(_sim.add_heat(h["pos"], h["radius"], FIRE_HEAT))
	for burner in get_tree().get_nodes_in_group("on_fire"):
		if burner != null and is_instance_valid(burner) and burner is Node3D:
			popped.append_array(_sim.add_heat(
					burner.global_position, 3.2, FIRE_HEAT))
	for id in popped:
		var pane = _panes.get(id)
		_panes.erase(id)
		if pane != null and is_instance_valid(pane):
			pane.shatter(pane.global_position, 0.4)

	# Cosmetic shard cleanup past the lifetime budget. Tick-based, not
	# wall-clock: shard removal moves physical bodies, so it must be
	# deterministic (wall-clock culling diverged CI runs under --fixed-fps).
	var now := Engine.get_physics_frames()
	for shard in get_tree().get_nodes_in_group("glass_shard"):
		if shard != null and is_instance_valid(shard) \
				and now - int(shard.get_meta("born_tick", now)) > SHARD_LIFE_TICKS:
			shard.queue_free()
