extends Node3D

## Real cable physics: a chain of small capsule Box3D link bodies pinned
## end-to-end with Box3DBallJoint, optionally pinned at either end to an
## existing body (or to the world when none is given). Slack > 1 lays the
## chain along a parabola and gravity finds the true catenary on its own.
## Overstretched joints snap, so cables tear instead of rubber-banding.
##
## Lessons inherited from box3d-godot's rope_builder: keep the chain's total
## mass at ~5-10% of a heavy end body's mass or the last pin stretches badly
## (extreme mass-ratio joints defeat iterative solvers), and give links
## collision_mask 0 so ropes stay contact-free and cheap.
##
##   var cable := Cable.spawn(world, from_pos, to_pos, {
##       slack = 1.08,            # arc length / straight distance
##       radius = 0.07,           # link capsule radius
##       segment = 1.2,           # target link length
##       color = Color(...),
##       density = 2.0,           # link density (bump for heavy end bodies)
##       body_a = <Box3DBody>,    # pin start to this body (null = world)
##       body_b = <Box3DBody>,    # pin end to this body (null = world)
##       pin_b = true,            # false: end b dangles free
##       collide = false,         # true: links collide with the scene
##       break_stretch = 2.2,     # snap factor (0 = unbreakable)
##   })
##   cable.links  # the Box3DBody chain, e.g. to hang suspenders from

const _Self = preload("res://lib/bodies/cable.gd")

static var _link_meshes := {}
static var _link_mats := {}

var links: Array[Node] = []
var _joints: Array[Node] = []
var _rest: Array[float] = []
var _break_stretch := 2.2
var _check_t := 0.0


static func spawn(world: Box3DWorld, from: Vector3, to: Vector3,
		opts: Dictionary = {}) -> Node3D:
	var slack: float = maxf(opts.get("slack", 1.0), 1.0)
	var radius: float = opts.get("radius", 0.07)
	var segment: float = opts.get("segment", 1.2)
	var color: Color = opts.get("color", Color(0.16, 0.16, 0.18))
	var density: float = opts.get("density", 2.0)
	var collide: bool = opts.get("collide", false)

	var cable := _Self.new()
	cable._break_stretch = opts.get("break_stretch", 2.2)
	world.add_child(cable)

	var dist := from.distance_to(to)
	var n := maxi(int(round(dist * slack / segment)), 2)
	var sag := dist * sqrt(3.0 * (slack - 1.0) / 8.0) if slack > 1.001 else 0.0
	var pts: Array[Vector3] = []
	for i in n + 1:
		var t := float(i) / float(n)
		pts.append(from.lerp(to, t) - Vector3(0.0, sag * 4.0 * t * (1.0 - t), 0.0))

	for i in n:
		var a := pts[i]
		var b := pts[i + 1]
		var seg_len := a.distance_to(b)
		var link := Box3DBody.new()
		link.name = "L%d" % i
		link.shape_type = Box3DBody.CAPSULE
		link.capsule_radius = radius
		link.capsule_height = seg_len * 0.85
		link.density = density
		link.friction = 0.5
		link.collision_layer = 1 if collide else 4
		link.collision_mask = 1 if collide else 0
		link.position = (a + b) * 0.5
		var dir := (b - a) / seg_len
		if absf(dir.dot(Vector3.UP)) < 0.9999:
			link.basis = Basis(Quaternion(Vector3.UP, dir))
		var mi := MeshInstance3D.new()
		mi.mesh = _link_mesh(radius, seg_len * 0.95)
		mi.material_override = _link_mat(color)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		link.add_child(mi)
		cable.add_child(link)
		cable.links.append(link)
		cable._rest.append(seg_len)

	# Joints: [world/body_a] -> L0 -> L1 -> ... -> L(n-1) -> [world/body_b].
	# Body paths must be set BEFORE add_child: the joint creates itself on
	# READY, which fires the moment it enters the already-running tree.
	cable._add_joint(pts[0], "L0", opts.get("body_a", null))
	for i in range(1, n):
		cable._add_joint(pts[i], "L%d" % i, null, "L%d" % (i - 1))
	if opts.get("pin_b", true):
		cable._add_joint(pts[n], "L%d" % (n - 1), opts.get("body_b", null))
	return cable


func _add_joint(at: Vector3, link_a: String, external: Node,
		link_b: String = "") -> void:
	var jt := Box3DBallJoint.new()
	jt.body_a = NodePath("../" + link_a)
	if external != null and is_instance_valid(external) and external.is_inside_tree():
		# Absolute path: the joint isn't in the tree yet, so it can't compute
		# a relative path -- and NodePaths only resolve at READY anyway.
		jt.body_b = external.get_path()
	elif link_b != "":
		jt.body_b = NodePath("../" + link_b)
	jt.position = at
	add_child(jt)
	_joints.append(jt)


## Overstretch check, a few times a second: a cable segment pulled past
## break_stretch times its rest length tears at that joint.
func _physics_process(delta: float) -> void:
	if _break_stretch <= 0.0:
		return
	_check_t += delta
	if _check_t < 0.25:
		return
	_check_t = 0.0
	for i in range(1, links.size()):
		if not is_instance_valid(links[i]) or not is_instance_valid(links[i - 1]):
			continue
		var d: float = links[i].global_position.distance_to(links[i - 1].global_position)
		var rest: float = (_rest[i] + _rest[i - 1]) * 0.5
		if d > rest * _break_stretch and i < _joints.size():
			var jt: Node = _joints[i]
			if is_instance_valid(jt):
				jt.queue_free()


static func _link_mesh(radius: float, height: float) -> CapsuleMesh:
	var key := "%.3f|%.3f" % [radius, height]
	if not _link_meshes.has(key):
		var mesh := CapsuleMesh.new()
		mesh.radius = radius
		mesh.height = maxf(height, radius * 2.1)
		mesh.radial_segments = 8
		mesh.rings = 2
		_link_meshes[key] = mesh
	return _link_meshes[key]


static func _link_mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html(false)
	if not _link_mats.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.55
		mat.metallic = 0.4
		_link_mats[key] = mat
	return _link_mats[key]
