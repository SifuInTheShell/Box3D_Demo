extends Box3DBody

## A real 3D tree model (Kenney Nature Kit, CC0) riding one Box3D body with
## compound collision: a trunk cylinder and a wider canopy cylinder, both
## Box3DCollisionShape children fitted to the model's measured bounds. The
## whole tree topples, gets launched by blasts, and is fully destructible --
## anything past FRACTURE_SPEED (or the blast sweep) swaps it into trunk
## sections, leafy shards and a foliage burst.
##
## Set `model_scene`, `target_height` and `canopy_color` before add_child.

const Drum := preload("res://lib/bodies/drum.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")
const FractureQueue := preload("res://lib/fracture_queue.gd")
const FractureFX := preload("res://lib/fx/fracture_fx.gd")
const BoxVis := preload("res://lib/fx/box_visuals.gd")

const FRACTURE_SPEED := 7.0
const SPAWN_GRACE_TICKS := 21  # contacts ignored this long after spawn (depenetration)

var model_scene: PackedScene
var target_height := 5.0
var canopy_color := Color(0.3, 0.5, 0.26)
var bark_color := Color(0.42, 0.3, 0.2)
## Realistic (photoscanned) models keep their own PBR materials; the tint
## override below is only for the stylized Kenney fallback set.
var keep_materials := false

var _fractured := false
var _impact_speed := FRACTURE_SPEED
var _born_tick := 0  # physics frame at spawn; gates the grace window
# (tick-based, not wall-clock: fracture gating must be deterministic)
var _width := 2.0


func _init() -> void:
	contact_monitor = true
	density = 0.5  # wood
	friction = 0.7


func _ready() -> void:
	add_to_group("panel")
	add_to_group("flammable")
	_born_tick = Engine.get_physics_frames()
	body_entered.connect(_on_body_entered)

	var model := model_scene.instantiate()
	add_child(model)
	if not keep_materials:
		_fix_materials(model)
	var aabb := _combined_aabb(model)
	var s := target_height / maxf(aabb.size.y, 0.01)
	model.scale = Vector3.ONE * s
	# Body origin sits at mid-height; drop the model so its base is at the
	# bottom of the body.
	model.position = Vector3(0, -target_height * 0.5 - aabb.position.y * s, 0)
	_width = maxf(aabb.size.x, aabb.size.z) * s

	var trunk := Box3DCollisionShape.new()
	trunk.shape_type = Box3DCollisionShape.CYLINDER
	trunk.capsule_radius = maxf(_width * 0.08, 0.13)
	trunk.capsule_height = target_height * 0.45
	trunk.sides = 8
	trunk.position = Vector3(0, -target_height * 0.275, 0)
	add_child(trunk)
	var canopy := Box3DCollisionShape.new()
	canopy.shape_type = Box3DCollisionShape.CYLINDER
	canopy.capsule_radius = maxf(_width * 0.32, 0.4)
	canopy.capsule_height = target_height * 0.55
	canopy.sides = 8
	canopy.density = 0.15  # foliage is mostly air
	canopy.position = Vector3(0, target_height * 0.225, 0)
	add_child(canopy)


## Fuel description for the fire system: mostly canopy -- a torched tree is
## rich, fast fuel (crown fires), the trunk carries it.
func fire_profile() -> Dictionary:
	return {
		"half": Vector3(maxf(_width, 0.8) * 0.5, target_height * 0.5,
				maxf(_width, 0.8) * 0.5),
		"moisture": 0.15,
		"fuel_scale": 1.5,
		# Boughs, not a solid block: catches like brush, burns out in ~a minute.
		"thickness": 0.13,
	}


## Consumed by fire: the crown is gone -- shatter into charred wreckage.
func burned_out() -> void:
	if _fractured:
		queue_free()
		return
	canopy_color = Color(0.12, 0.1, 0.08)
	bark_color = Color(0.16, 0.13, 0.1)
	_fractured = true
	_impact_speed = FRACTURE_SPEED
	FractureQueue.enqueue(get_tree(), _shatter)


func blast_fracture(_at: Vector3, speed: float) -> void:
	if _fractured or speed < FRACTURE_SPEED * 0.7:
		return
	_fractured = true
	_impact_speed = speed
	FractureQueue.enqueue(get_tree(), _shatter)


func _on_body_entered(other: Box3DBody) -> void:
	if _fractured or other == null or not is_instance_valid(other):
		return
	# Spawn grace: a tree placed touching scenery must not be self-destructed by
	# the frame-1 depenetration impulse (see breakable_block).
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	var rel := (other.get_linear_velocity() - get_linear_velocity()).length()
	if rel < FRACTURE_SPEED:
		return
	_fractured = true
	_impact_speed = rel
	FractureQueue.enqueue(get_tree(), _shatter)


## Physicalise the tree's OWN geometry. The imported glb mesh has two surfaces
## (green crown, brown trunk); split each into a few convex chunks that fly
## apart as real trunk sections and canopy clumps, inheriting the tree's motion.
func _shatter() -> void:
	if not is_inside_tree():
		return
	var rng := BreakableBlock.shared_rng()
	var parent: Node = get_parent()
	while parent != null and not parent is Box3DWorld:
		parent = parent.get_parent()
	if parent == null:
		parent = get_parent()
	var vel := get_linear_velocity()
	var ang := get_angular_velocity()
	var mi := _find_mesh(self)
	if mi != null and mi.mesh != null and mi.mesh.get_surface_count() >= 2:
		var mesh: Mesh = mi.mesh
		var xf := mi.global_transform
		# Crown = the surface whose vertices sit higher; trunk = the other.
		var foliage_si := 0 if _surface_mean_y(mesh, 0, xf) > _surface_mean_y(mesh, 1, xf) else 1
		_split_surface(parent, mesh, foliage_si, xf, canopy_color, 0.18, 4, true, vel, ang, rng)
		_split_surface(parent, mesh, 1 - foliage_si, xf, bark_color, 0.5, 2, false, vel, ang, rng)
		FractureFX.burst(parent, xf.origin + Vector3(0, target_height * 0.25, 0),
				_width, canopy_color)
	else:
		FractureFX.burst(parent, global_position, _width * 1.2, canopy_color)
	queue_free()


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


func _surface_mean_y(mesh: Mesh, si: int, xf: Transform3D) -> float:
	var v: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
	if v.is_empty():
		return 0.0
	var sum := 0.0
	for p in v:
		sum += (xf * p).y
	return sum / v.size()


## Split one glb surface into `chunks` convex bodies. `by_angle` groups triangles
## into pie sectors around the vertical axis (crown clumps); otherwise it splits
## low/high (trunk stump + upper bole). Triangles are baked to world space.
func _split_surface(parent: Node, mesh: Mesh, si: int, xf: Transform3D,
		color: Color, dens: float, chunks: int, by_angle: bool,
		vel: Vector3, ang: Vector3, rng: RandomNumberGenerator) -> void:
	var arrays := mesh.surface_get_arrays(si)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.is_empty() or idx.size() < 9:
		return
	var center := Vector3.ZERO
	for p in verts:
		center += xf * p
	center /= verts.size()
	var groups: Array = []
	for i in chunks:
		groups.append([])  # plain Array (reference) -- push_back is O(1); a
		# PackedVector3Array here copies-on-write each push (was O(n^2)).
	@warning_ignore("integer_division")
	var tri_count := idx.size() / 3
	for ti in tri_count:
		var a := xf * verts[idx[ti * 3]]
		var b := xf * verts[idx[ti * 3 + 1]]
		var c := xf * verts[idx[ti * 3 + 2]]
		var mid := (a + b + c) / 3.0
		var gi := 0
		if by_angle:
			gi = int((atan2(mid.z - center.z, mid.x - center.x) + PI) / TAU * chunks) % chunks
		elif mid.y > center.y:
			gi = mini(1, chunks - 1)
		var g: Array = groups[gi]
		g.push_back(a); g.push_back(b); g.push_back(c)
	for g in groups:
		if g.size() < 9:  # fewer than 3 triangles -- skip
			continue
		var cen := Vector3.ZERO
		for p in g:
			cen += p
		cen /= g.size()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var kept := 0
		for i in range(0, g.size(), 3):
			var a: Vector3 = g[i] - cen
			var b: Vector3 = g[i + 1] - cen
			var c: Vector3 = g[i + 2] - cen
			var nrm := (b - a).cross(c - a)
			if nrm.length() < 1e-7:
				continue
			nrm = nrm.normalized()
			st.set_normal(nrm); st.add_vertex(a)
			st.set_normal(nrm); st.add_vertex(b)
			st.set_normal(nrm); st.add_vertex(c)
			kept += 1
		if kept < 2:
			continue
		var chunk := st.commit()
		var body := Box3DBody.new()
		# Cheap box collision from the chunk's AABB -- building a convex HULL per
		# chunk cost ~350 ms per tree (a visible hitch). The real mesh is still
		# the VISUAL below, so debris looks like tree parts but collides as boxes.
		var ab: Vector3 = chunk.get_aabb().size
		body.box_size = Vector3(maxf(ab.x, 0.08), maxf(ab.y, 0.08), maxf(ab.z, 0.08))
		body.density = dens
		body.friction = 0.7
		body.add_to_group("fragment")
		body.position = cen
		parent.add_child(body)
		BoxVis.custom(body, chunk, color.darkened(rng.randf() * 0.15), false, null)
		body.set_linear_velocity(vel + ang.cross(cen - xf.origin)
				+ Vector3(rng.randf() - 0.5, rng.randf() * 0.6, rng.randf() - 0.5)
				* (1.0 + _impact_speed * 0.12))
		body.set_angular_velocity(ang + Vector3(rng.randf() - 0.5,
				rng.randf() - 0.5, rng.randf() - 0.5) * 2.5)


static var _demetal := {}


## Kenney's GLTF exports carry metallicFactor 1 (sky-mirror leaves) and
## their base colors import washed out. Override every surface with a
## shared non-metal copy carrying OUR palette: leaf materials get this
## tree's canopy tint, wood gets bark brown -- debris then matches too.
func _fix_materials(model: Node) -> void:
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not n is MeshInstance3D or n.mesh == null:
			continue
		for s in n.mesh.get_surface_count():
			var src: Material = n.get_active_material(s)
			if src == null:
				continue
			var is_leaf := src.resource_name.to_lower().contains("leaf")
			var tint := canopy_color if is_leaf else bark_color
			var key := "%d|%s" % [src.get_instance_id(), tint.to_html(false)]
			if not _demetal.has(key):
				var fixed: Material = src.duplicate()
				if fixed is BaseMaterial3D:
					fixed.metallic = 0.0
					fixed.roughness = 1.0
					fixed.albedo_color = tint
				_demetal[key] = fixed
			n.set_surface_override_material(s, _demetal[key])


static func _combined_aabb(root: Node) -> AABB:
	var total := AABB()
	var found := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var box: AABB = n.transform * n.get_aabb()
			total = box if not found else total.merge(box)
			found = true
		for c in n.get_children():
			stack.append(c)
	return total if found else AABB(Vector3.ZERO, Vector3.ONE)
