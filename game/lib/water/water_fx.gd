extends Node3D

## Water behaviour for a rectangular strip (the Golden Gate's channel).
## Force-based coupling (docs/water-research.md §4): bodies that arrive in
## the strip get 8-point Archimedes buoyancy + quadratic drag summed into
## apply_central_force/apply_torque each tick, so wood floats and bobs,
## panels (density 1.2 vs water's 1.0) sink slowly, and the wrecking ball
## plummets. Fast arrivals take an entry-slam impulse -- the single event
## that triggers splash FX (and, later, ripple splats). Waterlogged bodies
## eventually lose collision, drift through the bed and are freed. Bodies
## already resting in the strip on the first sweep -- bridge piers,
## anchorages -- are amnestied forever.
##
##   WaterFX.zone(world, center_at_surface, Vector2(size_x, size_z))

const _Self = preload("res://lib/water/water_fx.gd")
const WaterSplash := preload("res://lib/water/water_splash.gd")
const WaterSim := preload("res://lib/water/water_sim.gd")
const Scenery := preload("res://lib/gen/scenery.gd")

const SWEEP := 0.15  # seconds between enter/exit sweeps
const SPLASH_SPEED := 1.6  # downward m/s below which arrivals slip in quietly

## Physics constants (game density units: water = 1.0, panels 1.2, wood 0.5).
const RHO_WATER := 1.0
const C_LIN := 1.0    # linear drag coefficient
const C_QUAD := 0.8   # quadratic drag; doubled for downward motion
const C_ANG := 1.5    # extra angular damping while wet
const C_SLAM := 0.3   # entry-slam impulse fraction of m * v_down
const SINK_CAP := 1.4  # max sink speed once fully submerged, m/s
const KILL_DEPTH := 7.0  # metres under the surface where bodies are freed
const WATERLOG_TIME := 22.0  # seconds in water before a floater gets scuttled
const FLOW := Vector3(0.45, 0.0, 0.0)  # gentle downstream current, +X

## CPU mirror of the wave table in fx/water.gdshader -- keep in lockstep.
## [direction, spatial frequency, speed], amplitudes sum to 1.
const WAVES := [
	[Vector2(0.995, 0.0995), 0.5, 1.2],
	[Vector2(0.9285, -0.3714), 0.85, 0.8],
	[Vector2(0.8, 0.6), 1.7, 1.6],
]
const WAVE_AMP := [0.45, 0.35, 0.2]
const WAVE_HEIGHT := 0.08

var center := Vector3.ZERO
var size := Vector2.ZERO

var _world: Box3DWorld
var _splash: Node3D
var _sim: Node3D
var _g := 9.81
var _t := 0.0
var _time := 0.0
## Bodies already in the water on the first sweep are STRUCTURE (bridge
## caissons, pier columns, anchorages) -- amnestied forever. Only bodies
## arriving later are debris the water may claim.
var _native := {}
var _native_known := false
var _wet := {}  # instance_id -> per-body coupling state

## Wet bodies join this group so the settle detector can treat them as
## dealt-with: a floater drifting on the current would otherwise keep a run
## from ever reading as settled.
const WET_GROUP := "in_water"


static func zone(world: Box3DWorld, at: Vector3, strip: Vector2) -> Node3D:
	var w := _Self.new()
	w.center = at
	w.size = strip
	w._world = world
	w._g = maxf(absf(world.get_gravity().y), 0.1)
	world.add_child(w)
	# Give the splash the water rectangle so foam rings clip to the surface
	# instead of drawing on the banks (same origin/span the ripple sim uses).
	w._splash = WaterSplash.attach(w,
			Vector2(at.x - strip.x * 0.5, at.z - strip.y * 0.5), strip)
	# Ripple heightfield: only when the strip has a rendered surface to
	# deform (Scenery.water ran) and a RenderingDevice exists.
	var mat := Scenery.water_material()
	if mat != null:
		w._sim = WaterSim.attach(w, mat, at, strip)
	return w


## World-space surface height -- the same sine sum the shader displaces
## with, so buoyancy samples bob on the rendered waves.
func water_height(x: float, z: float) -> float:
	var h := 0.0
	for i in WAVES.size():
		var dir: Vector2 = WAVES[i][0]
		var k: float = WAVES[i][1]
		h += WAVE_AMP[i] * sin((dir.x * x + dir.y * z) * k + _time * WAVES[i][2])
	return center.y + h * WAVE_HEIGHT


func _physics_process(delta: float) -> void:
	_time += delta
	_couple_wet_bodies(delta)

	_t += delta
	if _t < SWEEP:
		return
	_t = 0.0
	_sweep()


## The per-tick force loop: Archimedes + drag at up to 8 sample points,
## summed into one central force + torque (the binding has no
## force-at-point; for a rigid body the sum is equivalent).
func _couple_wet_bodies(delta: float) -> void:
	for id in _wet.keys():
		var st: Dictionary = _wet[id]
		var body = st.body
		if not is_instance_valid(body) or body.is_queued_for_deletion():
			_wet.erase(id)
			continue
		var p: Vector3 = body.global_position
		if absf(p.x - center.x) > size.x * 0.5 + 2.0 \
				or absf(p.z - center.z) > size.y * 0.5 + 2.0:
			body.remove_from_group(WET_GROUP)
			_wet.erase(id)  # drifted out of the strip
			continue
		if p.y < center.y - KILL_DEPTH:
			body.queue_free()  # slipped far under: leaves the sim
			_wet.erase(id)
			continue
		st.t_in += delta
		if st.t_in > WATERLOG_TIME and not st.scuttled:
			# Waterlogged: collision off, buoyancy off -- the body drifts
			# down through the riverbed under drag and is freed below.
			st.scuttled = true
			body.collision_layer = 0
			body.collision_mask = 0

		var v: Vector3 = body.get_linear_velocity()
		var w: Vector3 = body.get_angular_velocity()
		var body_basis: Basis = body.global_transform.basis
		var force := Vector3.ZERO
		var torque := Vector3.ZERO
		var wet_points := 0
		for c in st.corners:
			var r: Vector3 = body_basis * c
			var x: Vector3 = p + r
			var d: float = water_height(x.x, x.z) - x.y
			if d <= 0.0:
				continue
			wet_points += 1
			var k: float = clampf(d / st.point_r, 0.0, 1.0)
			var f := Vector3.ZERO
			if not st.scuttled:
				f = Vector3.UP * (RHO_WATER * _g * st.vol_i * k)
			var vr: Vector3 = v + w.cross(r) - FLOW
			var cq: float = C_QUAD * (2.0 if vr.y < 0.0 else 1.0)
			f += -(C_LIN * vr + cq * vr.length() * vr) * (k * st.area_i)
			force += f
			torque += r.cross(f)
		if wet_points == 0:
			st.dry += delta
			if st.dry > 1.0:
				body.remove_from_group(WET_GROUP)
				_wet.erase(id)  # launched clear of the water
			continue
		st.dry = 0.0
		# Wake: drifting surface bodies drip small trailing splats into the
		# ripple sim; the wave equation turns the trail into a V.
		if _sim != null and not st.scuttled:
			st.trail -= delta
			var hs := Vector2(v.x - FLOW.x, v.z - FLOW.z).length()
			if st.trail <= 0.0 and hs > 0.7 \
					and p.y > water_height(p.x, p.z) - st.point_r * 2.0:
				_sim.splat(p, st.r_h, -clampf(hs * 0.02, 0.008, 0.08))
				st.trail = 0.12
		var frac: float = float(wet_points) / float(st.corners.size())
		var depth_c := maxf(0.0, water_height(p.x, p.z) - p.y)
		force = force.limit_length(3.0 * st.m * _g)
		body.apply_central_force(force)
		# Depth-ramped angular damping on top of the emergent r x F: debris
		# does one lazy half-tumble, then stabilizes.
		torque += -C_ANG * (1.0 + 2.0 * depth_c) * frac * st.inertia * w
		body.apply_torque(torque)
		# Readability cap on sink speed: heavy but graceful.
		if frac >= 1.0 and v.y < -SINK_CAP:
			body.set_linear_velocity(Vector3(v.x, -SINK_CAP, v.z))


## Enter/exit bookkeeping at SWEEP cadence; forces run every tick above.
func _sweep() -> void:
	if _world == null or not is_instance_valid(_world):
		return
	var first_sweep := not _native_known
	var reach := maxf(size.x, size.y) * 0.6 + 4.0
	for body in _world.overlap_sphere(center, reach):
		if body == null or not is_instance_valid(body):
			continue
		if body.body_type != Box3DBody.DYNAMIC:
			continue
		var p: Vector3 = body.global_position
		if absf(p.x - center.x) > size.x * 0.5 or absf(p.z - center.z) > size.y * 0.5:
			continue
		# Capture band: anything whose centre is within ~a body-height of
		# the surface counts (debris rests with its centre above the plane).
		if p.y > center.y + 1.2:
			continue
		var id: int = body.get_instance_id()
		if not _native_known:
			_native[id] = true
			continue
		if _native.has(id) or _wet.has(id):
			continue
		_register(body)
	if first_sweep:
		_native_known = true


## A body just arrived in the water: build its coupling state and, for
## fast plunges, apply the entry slam + splash. This is THE entry event.
func _register(body) -> void:
	var m: float = maxf(body.get_mass(), 0.01)
	var density: float = maxf(body.get_density(), 0.05)
	var vol: float = m / density
	var corners: Array = []
	var half := Vector3.ONE * (pow(vol, 1.0 / 3.0) * 0.5)
	if body.shape_type == Box3DBody.BOX:
		half = body.get_box_size() * 0.5
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				corners.append(Vector3(half.x * sx, half.y * sy, half.z * sz))
	var side := pow(vol, 1.0 / 3.0)
	var r_h := maxf(half.x, half.z)
	body.add_to_group(WET_GROUP)
	_wet[body.get_instance_id()] = {
		"body": body,
		"corners": corners,
		"m": m,
		"vol_i": vol / 8.0,
		"area_i": side * side / 8.0,
		"point_r": maxf(half.y, 0.08),
		"inertia": m * side * side / 6.0,
		"r_h": r_h,
		"t_in": 0.0,
		"dry": 0.0,
		"trail": 0.0,
		"scuttled": false,
	}
	var v: Vector3 = body.get_linear_velocity()
	var v_down := -v.y
	if v_down < SPLASH_SPEED:
		return
	body.apply_central_impulse(Vector3.UP * C_SLAM * m * v_down)
	var p: Vector3 = body.global_position
	var at := Vector3(p.x, water_height(p.x, p.z) + 0.06, p.z)
	_splash.splash(at, v_down, r_h)
	if _sim != null:
		# The body punches the surface down; the sim rings it outward.
		_sim.splat(p, r_h * 1.4, -clampf(v_down * 0.06, 0.05, 0.5))
