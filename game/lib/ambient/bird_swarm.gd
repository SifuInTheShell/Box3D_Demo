extends Node3D

## A low cruising bird swarm: dozens of birds wheeling in a loose flock over the
## town, the whole wheel slowly wandering and leaning downwind so it reads as
## cruising, not spinning in place. A blast scatters the ones it reaches -- they
## break formation, fly out and climb, then a damped spring folds them back into
## the wheel. Cosmetic MultiMesh (reuses bird_flock's dart mesh + wing-flap
## shader) -- one draw call, no per-bird node, no bodies, no physics, no effect
## on the sim results or determinism. Unlike AmbientSim.Flock (perch / hop / scatter /
## resettle -- the birds that live ON the town), these never land; they cruise
## the sky above it and scatter over it.
##
##   BirdSwarm.attach(world, center, count, radius, seed)
## Joins group "ambient_life", so explosion_fx's disturb broadcast reaches it.

const _Self = preload("res://lib/ambient/bird_swarm.gd")
const BirdFlock = preload("res://lib/ambient/bird_flock.gd")

const MAX_DT := 0.05        # clamp catch-up so a hitch cannot teleport the swarm
const SCARE_MULT := 3.0     # a blast scatters birds within this x its radius
const FLEE_SPEED := 13.0    # m/s kick away from a blast
const CLIMB := 6.0          # m/s upward kick
const KICK_SPRING := 3.0    # 1/s^2 pull back into formation
const KICK_DAMP := 2.2      # 1/s damping on the return

var _mmi: MultiMeshInstance3D
var _birds: Array = []      # per-bird orbit + scatter state
var _center: Vector3        # base centre of the wheel
var _radius: float
var _t := 0.0
var _wind: Node


static func attach(world: Node3D, center: Vector3, count: int, radius: float,
		seed_v: int) -> Node3D:
	var s: Node3D = _Self.new()
	s._center = center
	s._radius = radius
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for i in count:
		s._birds.append({
			"phase": rng.randf() * TAU,               # position around the wheel
			"omega": rng.randf_range(0.16, 0.24),     # rad/s (loosely coherent)
			"r": radius * rng.randf_range(0.4, 1.1),  # own ring radius
			"h": rng.randf_range(-2.0, 5.0),          # height within the flock
			"bob_a": rng.randf_range(0.5, 1.3),       # vertical bob
			"bob_w": rng.randf_range(0.5, 1.1),
			"bob_p": rng.randf() * TAU,
			"flap": rng.randf() * TAU,                # per-bird flap phase (shader)
			"kick": Vector3.ZERO,                     # scatter displacement…
			"kickv": Vector3.ZERO,                    # …and its velocity
			"pos": center,                            # last world position
		})
	world.add_child(s)
	return s


func _ready() -> void:
	add_to_group("ambient_life")  # receive explosion_fx's disturb broadcast
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = BirdFlock._bird_mesh()
	mm.instance_count = _birds.size()
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.extra_cull_margin = 64.0  # the wheel is wide; never frustum-cull it
	add_child(_mmi)
	_update(0.0)


## A blast breaks the birds it reaches out of formation (explosion_fx broadcasts
## to the "ambient_life" group). Kick velocity away + up; the spring in _update
## reels them back into the wheel over the next second or two.
func disturb(at: Vector3, radius: float, impulse := 0.0) -> void:
	var reach := radius * SCARE_MULT
	for b in _birds:
		var p: Vector3 = b["pos"]
		if p.distance_to(at) > reach:
			continue
		var away: Vector3 = p - at
		away.y = 0.0
		if away.length() < 0.01:
			away = Vector3(1.0, 0.0, 0.0)
		away = away.normalized()
		var kv: Vector3 = b["kickv"]
		b["kickv"] = kv + away * (FLEE_SPEED + impulse * 0.4) + Vector3.UP * CLIMB


func _process(delta: float) -> void:
	_update(minf(delta, MAX_DT))


func _update(dt: float) -> void:
	_t += dt
	if _wind == null or not is_instance_valid(_wind):
		_wind = get_tree().get_first_node_in_group("wind_system")
	var wind: Vector3 = _wind.current() if _wind != null else Vector3.ZERO
	var wind_h := Vector3(wind.x, 0.0, wind.z)
	# The whole wheel wanders on a slow lissajous and leans downwind, so the
	# swarm cruises across the sky over the town instead of drilling one spot.
	var c := _center \
			+ Vector3(sin(_t * 0.075) * _radius * 0.55, sin(_t * 0.05) * 3.0,
					cos(_t * 0.06) * _radius * 0.55) \
			+ wind_h * 1.2
	var mm := _mmi.multimesh
	for i in _birds.size():
		var b: Dictionary = _birds[i]
		var om: float = b["omega"]
		var r: float = b["r"]
		var h: float = b["h"]
		var bob_a: float = b["bob_a"]
		var bob_w: float = b["bob_w"]
		var bob_p: float = b["bob_p"]
		var ang: float = b["phase"] + om * _t
		var ca := cos(ang)
		var sa := sin(ang)
		var op := c + Vector3(ca * r, h + bob_a * sin(_t * bob_w + bob_p), sa * r)
		# Scatter kick: a damped spring back to the formation point.
		var kick: Vector3 = b["kick"]
		var kickv: Vector3 = b["kickv"]
		kickv -= kick * (KICK_SPRING * dt)
		kickv *= maxf(0.0, 1.0 - KICK_DAMP * dt)
		kick += kickv * dt
		b["kick"] = kick
		b["kickv"] = kickv
		var pos := op + kick
		b["pos"] = pos
		# Tangential heading + the scatter velocity set the facing; the shader
		# flaps off custom.r, wings always out (custom.g = 1).
		var vel: Vector3 = Vector3(-sa, 0.0, ca) * (r * om) + wind_h * 0.3 + kickv
		var yaw: float = atan2(-vel.x, -vel.z) if vel.length() > 0.001 else 0.0
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaw), pos))
		mm.set_instance_custom_data(i, Color(b["flap"], 1.0, 0.0, 0.0))
