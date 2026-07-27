extends Box3DBody

## A REAL round structural piece: Box3D's native CYLINDER / CONE hull
## collision (capsule_radius + capsule_height + cylinder_sides) with a
## matching cylinder mesh -- silo drums, tank shells, columns, chimney
## sections, cone roofs. No more many-sided panel polygons.
##
## Builders set shape_type/capsule_radius/capsule_height (plus drum_color /
## facade_tex) before add_child; _ready derives the visual from them.
## Fractures like a wall panel: anything past FRACTURE_SPEED (or the blast
## sweep at 0.7x) breaks the drum into masonry shards -- roundness is gone
## once it's rubble anyway.

const BoxVis := preload("res://lib/fx/box_visuals.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")
const FractureQueue := preload("res://lib/fracture_queue.gd")
const FractureFX := preload("res://lib/fx/fracture_fx.gd")

const FRACTURE_SPEED := 7.5
const SPAWN_GRACE_TICKS := 21  # contacts ignored this long after spawn (depenetration)

var drum_color := Color(0.8, 0.8, 0.8)
var facade_tex: Texture2D = null

var _fractured := false
var _impact_speed := FRACTURE_SPEED
var _impact_local := Vector3.ZERO
var _born_tick := 0  # physics frame at spawn; gates the grace window
# (tick-based, not wall-clock: fracture gating must be deterministic)

static var _meshes := {}


func _init() -> void:
	contact_monitor = true


func _ready() -> void:
	add_to_group("panel")
	_born_tick = Engine.get_physics_frames()
	body_entered.connect(_on_body_entered)
	BoxVis.custom(self, _mesh(capsule_radius, capsule_height, shape_type == CONE),
			drum_color, true, facade_tex)


func blast_fracture(at: Vector3, speed: float) -> void:
	if _fractured or speed < FRACTURE_SPEED * 0.7:
		return
	_fractured = true
	_impact_speed = speed
	_impact_local = to_local(at).clamp(-_box_equiv() * 0.5, _box_equiv() * 0.5)
	FractureQueue.enqueue(get_tree(), _shatter)


func _on_body_entered(other: Box3DBody) -> void:
	if _fractured or other == null or not is_instance_valid(other):
		return
	# Spawn grace: don't let a snug placement's frame-1 depenetration impulse
	# self-destruct the drum (see breakable_block).
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	var rel := (other.get_linear_velocity() - get_linear_velocity()).length()
	if rel < FRACTURE_SPEED:
		return
	_fractured = true
	_impact_speed = rel
	_impact_local = to_local(other.global_position).clamp(
			-_box_equiv() * 0.5, _box_equiv() * 0.5)
	FractureQueue.enqueue(get_tree(), _shatter)


## The bounding box the shard splitter works in; shards poking slightly past
## the round silhouette read as broken edges, not errors.
func _box_equiv() -> Vector3:
	var w := capsule_radius * 1.5
	return Vector3(w, capsule_height, w)


func _shatter() -> void:
	if not is_inside_tree():
		return
	if get_tree().get_nodes_in_group("block").size() >= 3000:
		return
	var rng := BreakableBlock.shared_rng()
	var budget := clampi(4 + int((_impact_speed - FRACTURE_SPEED) * 0.5), 4, 9)
	var pieces: Array = BreakableBlock.split_box_uneven(
			_box_equiv(), budget, 0.25, rng, _impact_local)
	# Under the WORLD, never a rotated parent -- see wall_panel._shatter.
	var parent: Node = get_parent()
	while parent != null and not parent is Box3DWorld:
		parent = parent.get_parent()
	if parent == null:
		parent = get_parent()
	var xf := global_transform
	var vel := get_linear_velocity()
	var ang := get_angular_velocity()
	var scatter := 0.4 + _impact_speed * 0.05
	for piece in pieces:
		var off: Vector3 = piece.off
		BreakableBlock.spawn_piece(parent, self, Transform3D(xf.basis, xf * off),
				piece.size, drum_color.darkened(rng.randf() * 0.12), 1,
				vel + ang.cross(xf.basis * off)
				+ Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * scatter,
				ang, facade_tex)
	FractureFX.burst(parent, xf.origin, capsule_radius * 1.4, drum_color)
	queue_free()


static func _mesh(radius: float, height: float, is_cone: bool) -> CylinderMesh:
	var key := "%.3f|%.3f|%s" % [radius, height, is_cone]
	if not _meshes.has(key):
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.0 if is_cone else radius
		mesh.bottom_radius = radius
		mesh.height = height
		mesh.radial_segments = 20
		mesh.rings = 1
		_meshes[key] = mesh
	return _meshes[key]
