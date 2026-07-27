extends RefCounted

## Procedural demolition-site dressing: traffic cones, striped barriers,
## warning-tape runs, pallet stacks, a dumpster, streetlamps. Everything
## physical is a Box3DBody (group "prop") so blasts scatter the site like
## everything else; tape and lamp light are visual-only. No textures, no
## downloads — built from primitives so it ships regardless of asset fetch
## state. Realistic Poly Haven props (docs/research/asset-pipeline.md) layer
## on top once fetched.

const CONE_ORANGE := Color(0.95, 0.4, 0.08)
const STRIPE_RED := Color(0.85, 0.15, 0.12)
const STRIPE_WHITE := Color(0.94, 0.94, 0.9)
const TAPE_YELLOW := Color(1.0, 0.85, 0.1)

# Realistic Poly Haven prop models, decimated game-ready in Blender
# (docs/research/asset-pipeline.md §3). Each is spawned as a dynamic Box3DBody so it
# reacts to blasts like everything else -- see real_prop().
const CrateScene := preload("res://lib/fx/models/props/wooden_crate.glb")
const HydrantScene := preload("res://lib/fx/models/props/fire_hydrant.glb")


static func _mat(color: Color, rough := 0.8, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


static func _mesh_child(body: Node3D, mesh: Mesh, color: Color,
		at := Vector3.ZERO, unshaded := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(color, 0.8, unshaded)
	mi.position = at
	body.add_child(mi)
	return mi


## Combined AABB of a freshly-instantiated model, in the model's local space.
static func _model_aabb(root: Node) -> AABB:
	var acc := {"init": false, "box": AABB()}
	_aabb_walk(root, Transform3D.IDENTITY, acc)
	return acc["box"] if acc["init"] else AABB(Vector3(-0.3, -0.3, -0.3), Vector3.ONE * 0.6)


static func _aabb_walk(n: Node, xf: Transform3D, acc: Dictionary) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var a: AABB = t * (n as MeshInstance3D).mesh.get_aabb()
		if acc["init"]:
			acc["box"] = acc["box"].merge(a)
		else:
			acc["box"] = a
			acc["init"] = true
	for c in n.get_children():
		_aabb_walk(c, t, acc)


## Spawn a realistic prop model as a physics body: a Box3DBody with a box
## collision fitted to the model's AABB and the glb as its visual, base resting
## on the ground at `at`. Group "prop", so blasts scatter it like everything else.
static func real_prop(parent: Node3D, scene: PackedScene, at: Vector3, yaw: float,
		density: float, is_static := false) -> Box3DBody:
	var model: Node3D = scene.instantiate()
	var aabb := _model_aabb(model)
	var body := Box3DBody.new()
	body.box_size = Vector3(maxf(aabb.size.x, 0.05), maxf(aabb.size.y, 0.05),
			maxf(aabb.size.z, 0.05))
	body.density = density
	body.friction = 0.8
	if is_static:
		body.body_type = Box3DBody.STATIC
	body.position = Vector3(at.x, at.y + aabb.size.y * 0.5, at.z)
	body.rotation.y = yaw
	body.add_to_group("prop")
	parent.add_child(body)
	model.position = -aabb.get_center()  # centre the visual on the body origin
	body.add_child(model)
	return body


static func crate(parent: Node3D, at: Vector3, rng: RandomNumberGenerator) -> void:
	real_prop(parent, CrateScene, at, rng.randf() * TAU, 0.5)


static func hydrant(parent: Node3D, at: Vector3, yaw := 0.0) -> void:
	real_prop(parent, HydrantScene, at, yaw, 4.5)  # heavy: stands, topples under a blast


## A traffic cone: light dynamic body (cone collision), orange with a white
## band. Tips over and scatters delightfully.
static func cone(parent: Node3D, at: Vector3, rng: RandomNumberGenerator) -> void:
	var body := Box3DBody.new()
	body.shape_type = Box3DBody.CONE
	body.capsule_radius = 0.22
	body.capsule_height = 0.62
	body.density = 0.35
	body.friction = 0.8
	body.position = at + Vector3(0, 0.31, 0)
	body.rotation.y = rng.randf() * TAU
	body.add_to_group("prop")
	body.add_to_group("wind_blown")  # a real wind tips traffic cones
	body.set_meta("sail", 0.06)
	parent.add_child(body)
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.02
	cone_mesh.bottom_radius = 0.2
	cone_mesh.height = 0.56
	_mesh_child(body, cone_mesh, CONE_ORANGE, Vector3(0, 0.0, 0))
	var band := CylinderMesh.new()
	band.top_radius = 0.115
	band.bottom_radius = 0.145
	band.height = 0.1
	_mesh_child(body, band, STRIPE_WHITE, Vector3(0, 0.05, 0))
	var base := BoxMesh.new()
	base.size = Vector3(0.42, 0.045, 0.42)
	_mesh_child(body, base, CONE_ORANGE.darkened(0.25), Vector3(0, -0.285, 0))


## A striped wooden site barrier: one plank body on two legs (compound
## collision), the plank faced with alternating red/white segments.
static func barrier(parent: Node3D, at: Vector3, yaw: float) -> void:
	var body := Box3DBody.new()
	body.box_size = Vector3(1.8, 0.24, 0.05)
	body.density = 0.6
	body.friction = 0.7
	body.position = at + Vector3(0, 0.78, 0)
	body.rotation.y = yaw
	body.add_to_group("prop")
	var seg := 1.8 / 6.0
	for i in 6:
		var m := BoxMesh.new()
		m.size = Vector3(seg, 0.24, 0.055)
		_mesh_child(body, m, STRIPE_RED if i % 2 == 0 else STRIPE_WHITE,
				Vector3(-0.9 + seg * (i + 0.5), 0.0, 0.0))
	for side in [-1.0, 1.0]:
		var leg := Box3DCollisionShape.new()
		leg.shape_type = Box3DCollisionShape.BOX
		leg.box_size = Vector3(0.06, 0.78, 0.42)
		leg.position = Vector3(side * 0.8, -0.5, 0.0)
		body.add_child(leg)
		var leg_mesh := BoxMesh.new()
		leg_mesh.size = Vector3(0.06, 0.78, 0.42)
		_mesh_child(body, leg_mesh, Color(0.55, 0.5, 0.42),
				Vector3(side * 0.8, -0.5, 0.0))
	# Add to the world only once the compound body is fully built, so Box3D
	# registers the leg shapes in a settled tree (no mid-add transform query).
	parent.add_child(body)


## A run of warning tape between two posts (visual only — blasts don't need
## to simulate tape, and the posts are too thin to matter).
static func tape_run(parent: Node3D, from: Vector3, to: Vector3) -> void:
	for p in [from, to]:
		var post := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.025
		pm.bottom_radius = 0.025
		pm.height = 1.0
		post.mesh = pm
		post.material_override = _mat(Color(0.75, 0.75, 0.78), 0.5)
		post.position = p + Vector3(0, 0.5, 0)
		parent.add_child(post)
	var tape := MeshInstance3D.new()
	var mid := (from + to) * 0.5 + Vector3(0, 0.92, 0)
	var seg := to - from
	var tm := BoxMesh.new()
	tm.size = Vector3(seg.length(), 0.07, 0.006)
	tape.mesh = tm
	tape.material_override = _mat(TAPE_YELLOW, 0.9, true)
	tape.position = mid
	tape.rotation.y = atan2(-seg.z, seg.x)
	parent.add_child(tape)


## A stack of wooden pallets (each a thin body — forks of debris fly).
static func pallet_stack(parent: Node3D, at: Vector3, count: int,
		rng: RandomNumberGenerator) -> void:
	for i in count:
		var body := Box3DBody.new()
		body.box_size = Vector3(1.2, 0.14, 1.0)
		body.density = 0.5
		body.friction = 0.8
		body.position = at + Vector3(rng.randf_range(-0.04, 0.04),
				0.07 + i * 0.145, rng.randf_range(-0.04, 0.04))
		body.rotation.y = rng.randf_range(-0.08, 0.08)
		body.add_to_group("prop")
		parent.add_child(body)
		var deck := BoxMesh.new()
		deck.size = Vector3(1.2, 0.02, 1.0)
		_mesh_child(body, deck, Color(0.72, 0.6, 0.44), Vector3(0, 0.06, 0))
		for s in 3:
			var block := BoxMesh.new()
			block.size = Vector3(0.1, 0.12, 1.0)
			_mesh_child(body, block, Color(0.62, 0.5, 0.36),
					Vector3(-0.5 + s * 0.5, -0.01, 0))


## A steel dumpster with a half-open lid.
static func dumpster(parent: Node3D, at: Vector3, yaw: float) -> void:
	var body := Box3DBody.new()
	body.box_size = Vector3(1.9, 1.1, 1.1)
	body.density = 1.6
	body.friction = 0.7
	body.position = at + Vector3(0, 0.55, 0)
	body.rotation.y = yaw
	body.add_to_group("prop")
	parent.add_child(body)
	var green := Color(0.16, 0.34, 0.2)
	var shell := BoxMesh.new()
	shell.size = Vector3(1.9, 1.1, 1.1)
	_mesh_child(body, shell, green)
	var lid := BoxMesh.new()
	lid.size = Vector3(1.9, 0.04, 1.12)
	var lid_mi := _mesh_child(body, lid, green.darkened(0.2), Vector3(0, 0.62, -0.18))
	lid_mi.rotation.x = 0.5
	var rail := BoxMesh.new()
	rail.size = Vector3(1.96, 0.08, 1.16)
	_mesh_child(body, rail, Color(0.1, 0.12, 0.12), Vector3(0, 0.5, 0))


## A streetlamp: pole on a base plate + warm cone of light. Anchored (static) --
## a slim 4.6 m pole made dynamic just topples through the floor at spawn, and
## real lamps are bolted down; blasts still scatter everything else into it.
static func streetlamp(parent: Node3D, at: Vector3) -> void:
	var pole := Box3DBody.new()
	pole.body_type = Box3DBody.STATIC
	pole.shape_type = Box3DBody.CYLINDER
	pole.capsule_radius = 0.07
	pole.capsule_height = 4.6
	pole.position = at + Vector3(0, 2.3, 0)
	pole.add_to_group("prop")
	parent.add_child(pole)
	var foot_mesh := BoxMesh.new()
	foot_mesh.size = Vector3(0.52, 0.16, 0.52)
	_mesh_child(pole, foot_mesh, Color(0.18, 0.2, 0.22), Vector3(0, -2.22, 0))
	var pm := CylinderMesh.new()
	pm.top_radius = 0.05
	pm.bottom_radius = 0.08
	pm.height = 4.6
	_mesh_child(pole, pm, Color(0.2, 0.22, 0.25), Vector3.ZERO)
	var arm := BoxMesh.new()
	arm.size = Vector3(0.7, 0.06, 0.06)
	_mesh_child(pole, arm, Color(0.2, 0.22, 0.25), Vector3(0.32, 2.24, 0))
	var head := BoxMesh.new()
	head.size = Vector3(0.34, 0.1, 0.16)
	_mesh_child(pole, head, Color(0.9, 0.88, 0.8), Vector3(0.62, 2.2, 0), true)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.92, 0.75)
	light.light_energy = 1.6
	light.omni_range = 7.0
	light.shadow_enabled = false
	light.position = Vector3(0.62, 2.1, 0)
	pole.add_child(light)


# ---- Lived-in dressing -----------------------------------------------------
# Procedural, because no good CC0 source exists for any of it (laundry,
# planters, mailboxes, bins): primitives in the cone/tape/pallet style, so
# they ship regardless of asset fetch state. Small tended details like these
# are what make a block read as inhabited rather than as a set of targets.


## A laundry line: two anchored poles, a line, and swaying cloth (visual-only,
## vertex-shader wind — cloth_sway.gdshader). Poles are static like the
## streetlamp (slim dynamic poles topple through the floor at spawn); blasts
## still read: the sheets hang off whatever the site does around them.
static func laundry_line(parent: Node3D, from: Vector3, to: Vector3,
		rng: RandomNumberGenerator) -> void:
	var top := 1.9
	for p in [from, to]:
		var pole := Box3DBody.new()
		pole.body_type = Box3DBody.STATIC
		pole.shape_type = Box3DBody.CYLINDER
		pole.capsule_radius = 0.05
		pole.capsule_height = top
		pole.position = p + Vector3(0, top * 0.5, 0)
		pole.add_to_group("prop")
		parent.add_child(pole)
		var pm := CylinderMesh.new()
		pm.top_radius = 0.035
		pm.bottom_radius = 0.05
		pm.height = top
		_mesh_child(pole, pm, Color(0.5, 0.46, 0.4))
		var bar := BoxMesh.new()
		bar.size = Vector3(0.5, 0.05, 0.05)
		_mesh_child(pole, bar, Color(0.5, 0.46, 0.4), Vector3(0, top * 0.5 - 0.03, 0))
	var seg := to - from
	var line := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(seg.length(), 0.015, 0.015)
	line.mesh = lm
	line.material_override = _mat(Color(0.85, 0.85, 0.85), 0.9)
	line.position = (from + to) * 0.5 + Vector3(0, top - 0.04, 0)
	line.rotation.y = atan2(-seg.z, seg.x)
	parent.add_child(line)
	var cloth_colors := [Color(0.92, 0.92, 0.9), Color(0.65, 0.75, 0.9),
			Color(0.95, 0.8, 0.75), Color(0.75, 0.85, 0.7)]
	var n := 3 + (rng.randi() % 3)
	for i in n:
		var f := (i + 0.5) / float(n) + rng.randf_range(-0.05, 0.05)
		var w := rng.randf_range(0.35, 0.7)
		var h := rng.randf_range(0.5, 0.85)
		var quad := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(w, h)
		qm.orientation = PlaneMesh.FACE_Z
		quad.mesh = qm
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://lib/ambient/cloth_sway.gdshader")
		mat.set_shader_parameter("tint",
				cloth_colors[rng.randi() % cloth_colors.size()])
		quad.material_override = mat
		quad.position = from.lerp(to, clampf(f, 0.05, 0.95)) \
				+ Vector3(0, top - 0.06 - h * 0.5, 0)
		quad.rotation.y = atan2(-seg.z, seg.x)
		parent.add_child(quad)


## A terracotta planter with a few leaf cards: light dynamic body — a blast
## sends the neighbour's geraniums flying, which is exactly the guilt it
## should produce.
static func planter(parent: Node3D, at: Vector3, rng: RandomNumberGenerator,
		yaw := 0.0) -> void:
	var body := Box3DBody.new()
	body.box_size = Vector3(0.72, 0.3, 0.3)
	body.density = 1.1
	body.friction = 0.8
	body.position = at + Vector3(0, 0.15, 0)
	body.rotation.y = yaw
	body.add_to_group("prop")
	parent.add_child(body)
	var terracotta := Color(0.71, 0.4, 0.28)
	var box := BoxMesh.new()
	box.size = Vector3(0.72, 0.3, 0.3)
	_mesh_child(body, box, terracotta)
	var rim := BoxMesh.new()
	rim.size = Vector3(0.76, 0.05, 0.34)
	_mesh_child(body, rim, terracotta.darkened(0.15), Vector3(0, 0.135, 0))
	var soil := BoxMesh.new()
	soil.size = Vector3(0.66, 0.03, 0.24)
	_mesh_child(body, soil, Color(0.2, 0.14, 0.1), Vector3(0, 0.15, 0))
	var greens := [Color(0.25, 0.5, 0.22), Color(0.3, 0.55, 0.25)]
	var blooms := [Color(0.85, 0.25, 0.3), Color(0.95, 0.6, 0.2),
			Color(0.9, 0.85, 0.3)]
	for i in 4 + rng.randi() % 3:
		var x := rng.randf_range(-0.28, 0.28)
		var leaf := QuadMesh.new()
		leaf.size = Vector2(rng.randf_range(0.1, 0.16), rng.randf_range(0.14, 0.24))
		leaf.orientation = PlaneMesh.FACE_Z
		var mi := _mesh_child(body, leaf, greens[rng.randi() % greens.size()],
				Vector3(x, 0.16 + leaf.size.y * 0.5, rng.randf_range(-0.06, 0.06)))
		mi.rotation.y = rng.randf() * TAU
		mi.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED
		if rng.randf() < 0.6:
			var bloom := SphereMesh.new()
			bloom.radius = 0.03
			bloom.height = 0.05
			_mesh_child(body, bloom, blooms[rng.randi() % blooms.size()],
					Vector3(x, 0.18 + leaf.size.y, rng.randf_range(-0.05, 0.05)))


## A kerbside mailbox: post + box + little red flag. Somebody gets letters
## here — light enough that any blast worth a fine knocks it flat.
static func mailbox(parent: Node3D, at: Vector3, yaw := 0.0) -> void:
	var body := Box3DBody.new()
	body.box_size = Vector3(0.34, 1.15, 0.24)
	body.density = 0.7
	body.friction = 0.7
	body.position = at + Vector3(0, 0.575, 0)
	body.rotation.y = yaw
	body.add_to_group("prop")
	body.add_to_group("wind_blown")  # tall and light: rocks in gusts
	body.set_meta("sail", 0.025)
	parent.add_child(body)
	var post := BoxMesh.new()
	post.size = Vector3(0.06, 0.95, 0.06)
	_mesh_child(body, post, Color(0.4, 0.32, 0.24), Vector3(0, -0.1, 0))
	var box := BoxMesh.new()
	box.size = Vector3(0.34, 0.22, 0.24)
	_mesh_child(body, box, Color(0.25, 0.3, 0.55), Vector3(0, 0.46, 0))
	var lid := BoxMesh.new()
	lid.size = Vector3(0.36, 0.05, 0.26)
	_mesh_child(body, lid, Color(0.2, 0.24, 0.45), Vector3(0, 0.585, 0))
	var flag_pole := BoxMesh.new()
	flag_pole.size = Vector3(0.02, 0.16, 0.02)
	_mesh_child(body, flag_pole, Color(0.8, 0.15, 0.12), Vector3(0.19, 0.5, 0))
	var flag := BoxMesh.new()
	flag.size = Vector3(0.02, 0.06, 0.1)
	_mesh_child(body, flag, Color(0.8, 0.15, 0.12), Vector3(0.19, 0.56, 0.05))


## A kerbside trash bin with a lid — the humblest sign a street is serviced
## and lived on.
static func trash_bin(parent: Node3D, at: Vector3, rng: RandomNumberGenerator) -> void:
	var body := Box3DBody.new()
	body.shape_type = Box3DBody.CYLINDER
	body.capsule_radius = 0.26
	body.capsule_height = 0.72
	body.density = 0.5
	body.friction = 0.8
	body.position = at + Vector3(0, 0.36, 0)
	body.rotation.y = rng.randf() * TAU
	body.add_to_group("prop")
	body.add_to_group("wind_blown")  # bins rattle and topple in squalls
	body.set_meta("sail", 0.04)
	parent.add_child(body)
	var shade := Color(0.24, 0.3, 0.26) if rng.randf() < 0.5 else Color(0.28, 0.28, 0.3)
	var can := CylinderMesh.new()
	can.top_radius = 0.26
	can.bottom_radius = 0.22
	can.height = 0.68
	_mesh_child(body, can, shade)
	var lid := CylinderMesh.new()
	lid.top_radius = 0.2
	lid.bottom_radius = 0.28
	lid.height = 0.07
	_mesh_child(body, lid, shade.darkened(0.2), Vector3(0, 0.37, 0))
	var handle := BoxMesh.new()
	handle.size = Vector3(0.1, 0.03, 0.03)
	_mesh_child(body, handle, shade.darkened(0.35), Vector3(0, 0.42, 0))
