extends Node3D

## Windsock — the site's diegetic wind gauge. A real instrument, not a HUD
## element: the sock swings to point downwind, fills and rises with speed
## (hanging limp in a calm, horizontal at ~8 m/s — the airfield standard),
## and flutters harder through squalls. Read the day at a glance, the way
## a real blaster would, before committing the plunger.
##
##   Windsock.attach(world, at, wind_system)
##
## The pole is a static Box3DBody (streetlamp reasoning: bolted down, slim
## dynamic poles fall through the floor at spawn) so debris interacts with
## it; the sock itself is pure visual and reads wind_system every frame.
## Cosmetic only — nothing here feeds physics or the sim results.

const _Self = preload("res://lib/wind/windsock.gd")

const POLE_H := 4.2
const SEGMENTS := 5
const SOCK_LEN := 1.15       # metres of sock
const FULL_SPEED := 8.0      # m/s at which the sock flies horizontal
const HANG_PITCH := -1.35    # boom pitch in a dead calm (radians)
const FLY_PITCH := -0.08     # boom pitch at FULL_SPEED
const RESPONSE := 3.0        # 1/s — the sock trails the wind, not snaps
const ORANGE := Color(0.95, 0.45, 0.1)
const WHITE := Color(0.93, 0.93, 0.9)

var _wind: Node
var _pivot: Node3D
var _boom: Node3D
var _segs: Array = []
var _t := 0.0


static func attach(world: Node3D, at: Vector3, wind_system: Node) -> Node3D:
	var sock := _Self.new()
	sock._wind = wind_system
	sock.position = at
	world.add_child(sock)
	return sock


func _ready() -> void:
	add_to_group("windsock")
	# The mast: anchored, like the streetlamp.
	var pole := Box3DBody.new()
	pole.body_type = Box3DBody.STATIC
	pole.shape_type = Box3DBody.CYLINDER
	pole.capsule_radius = 0.05
	pole.capsule_height = POLE_H
	pole.position = Vector3(0, POLE_H * 0.5, 0)
	pole.add_to_group("prop")
	add_child(pole)
	var foot := BoxMesh.new()
	foot.size = Vector3(0.4, 0.12, 0.4)
	_mesh(pole, foot, Color(0.18, 0.2, 0.22), Vector3(0, -POLE_H * 0.5 + 0.06, 0))
	var mast := CylinderMesh.new()
	mast.top_radius = 0.035
	mast.bottom_radius = 0.05
	mast.height = POLE_H
	_mesh(pole, mast, Color(0.75, 0.78, 0.82), Vector3.ZERO)

	# Swivel + boom: yaw follows the wind, pitch rises with its speed.
	_pivot = Node3D.new()
	_pivot.position = Vector3(0, POLE_H - 0.15, 0)
	add_child(_pivot)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.05
	ring.outer_radius = 0.09
	_mesh(_pivot, ring, Color(0.6, 0.62, 0.66), Vector3.ZERO)
	_boom = Node3D.new()
	_boom.rotation.x = HANG_PITCH
	_pivot.add_child(_boom)

	# The sock: tapering ring segments, orange-white-orange, along -Z.
	var r0 := 0.16
	var seg_len := SOCK_LEN / SEGMENTS
	for i in SEGMENTS:
		var seg := Node3D.new()
		seg.position = Vector3(0, 0, -(0.12 + seg_len * (i + 0.5)))
		_boom.add_child(seg)
		var cone := CylinderMesh.new()
		var wide := r0 * (1.0 - 0.13 * i)
		var narrow := r0 * (1.0 - 0.13 * (i + 1))
		cone.top_radius = wide      # +Y -> +Z after the tilt: wide end poleward
		cone.bottom_radius = narrow
		cone.height = seg_len
		var mi := _mesh(seg, cone, ORANGE if i % 2 == 0 else WHITE, Vector3.ZERO)
		mi.rotation.x = PI / 2.0
		_segs.append(seg)


func _process(delta: float) -> void:
	_t += delta
	var w: Vector3 = _wind.current() if _wind != null and is_instance_valid(_wind) \
			else Vector3.ZERO
	var speed := w.length()
	var k := clampf(RESPONSE * delta, 0.0, 1.0)
	if speed > 0.05:
		var target_yaw := atan2(-w.x, -w.z)  # -Z forward points downwind
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, target_yaw, k)
	var gust: float = _wind.gust01() if _wind != null and is_instance_valid(_wind) \
			else 0.0
	var fill := clampf(speed / FULL_SPEED, 0.0, 1.0)
	_boom.rotation.x = lerpf(_boom.rotation.x,
			lerpf(HANG_PITCH, FLY_PITCH, fill), k)
	# Flutter: the free end shakes hardest, and squalls shake everything.
	for i in _segs.size():
		var amp := (0.02 + 0.10 * gust) * (float(i + 1) / _segs.size())
		var seg: Node3D = _segs[i]
		seg.rotation.y = sin(_t * (7.0 + 1.3 * i) + i * 1.7) * amp
		seg.rotation.x = sin(_t * (5.2 + 0.9 * i) + i * 2.3) * amp * 0.6


static func _mesh(parent: Node3D, mesh: Mesh, color: Color, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	mi.material_override = m
	mi.position = at
	parent.add_child(mi)
	return mi
