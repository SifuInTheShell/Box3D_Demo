extends Node3D

## Lit windows: the habitation tell (research §5 — lit/unlit windows are the
## cheapest global "someone lives here" signal). Sweeps the "glass" group
## like fire_system sweeps "flammable"; each new pane draws its lit state
## once from AmbientSim.Windows (deterministic in insertion order) and a lit
## pane gets a warm emissive slab nested inside the glass. The glow is a
## child of the pane, so a shattered pane takes its light with it — going
## dark on breakage costs nothing and always reads as consequence.
##
##   WindowLife.attach(world, lit_fraction, seed)
##   darken_building(id)   # power loss; panes stamped meta "building_id"
##
## STRICTLY COSMETIC: no bodies, no sim input. Buildings default to
## building 0 until the generators stamp real ids (Stage B).

const _Self = preload("res://lib/ambient/window_life.gd")

const SWEEP := 0.7  # seconds between glass-group sweeps

# Collapse power-cut: when a building loses this fraction of its windows
# (shattered or carried down with the rubble), the survivors go dark at once.
const COLLAPSE_FRAC := 0.45
const COLLAPSE_MIN := 3      # ignore one/two-window structures
const COLLAPSE_MOVE := 1.5   # m a pane must shift to count as "down"

static var _glow_mats := {}

var _windows  # AmbientSim.Windows
var _glows := {}   # pane instance id -> glow MeshInstance3D
var _sweep_t := 0.0
var _bld_ids := {}   # building_id -> Array[int] of its pane instance ids
var _spawn := {}     # pane id -> spawn position
var _bld_dark := {}  # building_id -> true once its power is cut


static func attach(world: Node3D, lit_fraction: float, seed_v: int) -> Node3D:
	var wl := _Self.new()
	wl._windows = AmbientSim.Windows.new(seed_v, lit_fraction)
	world.add_child(wl)
	return wl


func lit_count() -> int:
	var n := 0
	for id in _glows:
		if is_instance_valid(instance_from_id(id)):
			n += 1
	return n


## Power loss: every lit pane of the building goes dark at once.
func darken_building(building: int) -> void:
	_windows.darken_building(building)
	for id in _glows.keys():
		var pane := instance_from_id(id)
		if pane == null or not is_instance_valid(pane):
			_glows.erase(id)
			continue
		if pane.get_meta("building_id", 0) == building:
			var glow: MeshInstance3D = _glows[id]
			if is_instance_valid(glow):
				glow.queue_free()
			_glows.erase(id)


func _ready() -> void:
	_sweep()


func _process(delta: float) -> void:
	_sweep_t += delta
	if _sweep_t < SWEEP:
		return
	_sweep_t = 0.0
	_sweep()
	_check_collapse()


func _sweep() -> void:
	for pane in get_tree().get_nodes_in_group("glass"):
		if pane == null or not is_instance_valid(pane) or not pane is Node3D:
			continue
		var id: int = pane.get_instance_id()
		if _windows.has_window(id):
			continue
		var bid: int = pane.get_meta("building_id", 0)
		var lit: bool = _windows.add_window(id, bid)
		# Track every pane (lit or not) so a collapse is measured against the
		# whole facade, then cut power to the survivors when it comes down.
		var lst: Array = _bld_ids.get(bid, [])
		lst.append(id)
		_bld_ids[bid] = lst
		_spawn[id] = (pane as Node3D).global_position
		if lit:
			_glows[id] = _attach_glow(pane)


## When a building loses most of its windows -- shattered, or carried off with
## the collapsing wall -- the ones still standing go dark at once: the structure
## lost power. Cosmetic and one-way, like the rest of the window layer.
func _check_collapse() -> void:
	for bid in _bld_ids:
		if _bld_dark.get(bid, false):
			continue
		var ids: Array = _bld_ids[bid]
		if ids.size() < COLLAPSE_MIN:
			continue
		var standing := 0
		for pid in ids:
			var pane = instance_from_id(pid)
			if pane != null and is_instance_valid(pane) and pane is Node3D \
					and (pane as Node3D).global_position.distance_to(_spawn[pid]) \
					< COLLAPSE_MOVE:
				standing += 1
		if standing <= int(ids.size() * COLLAPSE_FRAC):
			_bld_dark[bid] = true
			darken_building(bid)


func _attach_glow(pane: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	# Nested just inside the pane: visible through the glass from both sides,
	# gone the instant the pane shatters (it is the pane's child).
	var s: Vector3 = pane.box_size if "box_size" in pane else Vector3(1.0, 1.0, 0.03)
	mesh.size = Vector3(maxf(s.x - 0.04, 0.02), maxf(s.y - 0.04, 0.02),
			maxf(s.z - 0.04, 0.02)).min(s * 0.9)
	mi.mesh = mesh
	mi.material_override = _glow_material(pane.get_instance_id())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pane.add_child(mi)
	return mi


## Warm interior light, hue jittered per window off the id hash so a facade
## never glows uniformly. Deterministic — no RNG draw, so the Windows sim's
## lit sequence stays untouched.
static func _glow_material(id: int) -> StandardMaterial3D:
	var step_i := (hash(id) % 5 + 5) % 5
	if _glow_mats.has(step_i):
		return _glow_mats[step_i]
	var warm := Color(1.0, 0.82, 0.55).lerp(Color(1.0, 0.93, 0.78), step_i / 4.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = warm
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	m.emission = warm
	m.emission_energy_multiplier = 1.4
	_glow_mats[step_i] = m
	return m
