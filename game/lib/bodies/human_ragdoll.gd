extends Node3D
## A proper articulated humanoid ragdoll driven by Box3D bodies. Uses a rigged
## CC0 low-poly human (Quaternius, "Man") whose skinned mesh is deformed by its
## skeleton -- so the limbs bend at elbows and knees. Eleven Box3D bodies
## (pelvis, torso, head, upper/lower arms, upper/lower legs) are placed along
## the skeleton's bones and linked with ball joints. While standing it's frozen
## (kinematic) in the bind pose; when the chaos reaches it every body flips to
## dynamic, the joints take over, and each frame we write the body transforms
## back into the Skeleton3D so the character flops as one continuous mesh.
##
##   HumanRagdoll.spawn(world, Vector3(x, 0, z), rng, yaw)

const _Self = preload("res://lib/bodies/human_ragdoll.gd")
const CHAR := preload("res://lib/fx/models/humans/man.glb")

const HEIGHT := 1.8        # target standing height in metres
const RAW_HEIGHT := 4.22   # the model's native height (feet->head)
const ACTIVATE_SPEED := 4.0

# Each body spans two bones (a capsule, or a box for the trunk/head). Fields:
#   [from bone, to bone, radius (m), shape ("cap"/"box"), bone it drives]
# "^Head" is a synthetic point above the head (extends the neck->head line).
const SEGMENTS := [
	["pelvis", "Hips", "Abdomen", 0.135, "box", "Hips"],
	["torso", "Abdomen", "Neck", 0.135, "box", "Torso"],
	["head", "Head", "^Head", 0.115, "box", "Head"],
	["uarmL", "UpperArm.L", "LowerArm.L", 0.055, "cap", "UpperArm.L"],
	["larmL", "LowerArm.L", "Palm.L", 0.048, "cap", "LowerArm.L"],
	["uarmR", "UpperArm.R", "LowerArm.R", 0.055, "cap", "UpperArm.R"],
	["larmR", "LowerArm.R", "Palm.R", 0.048, "cap", "LowerArm.R"],
	["ulegL", "UpperLeg.L", "LowerLeg.L", 0.085, "cap", "UpperLeg.L"],
	["llegL", "LowerLeg.L", "Foot.L", 0.068, "cap", "LowerLeg.L"],
	["ulegR", "UpperLeg.R", "LowerLeg.R", 0.085, "cap", "UpperLeg.R"],
	["llegR", "LowerLeg.R", "Foot.R", 0.068, "cap", "LowerLeg.R"],
]

# EVERY skinned bone is driven by one body, so no vertex is left behind at the
# spawn point (which smears the mesh into a blade). Bones without their own body
# ride the nearest segment -- note Foot.L/R and the finger/pole bones hang off
# the rig root, not the limb, so they must be assigned explicitly.
const BONE_BODY := {
	"Bone": "pelvis", "Body": "pelvis", "Hips": "pelvis",
	"Abdomen": "torso", "Torso": "torso", "Neck": "torso", "Head": "head",
	"Shoulder.L": "torso", "UpperArm.L": "uarmL", "LowerArm.L": "larmL",
	"Palm.L": "larmL", "MiddleHand.L": "larmL", "Fingers.L": "larmL",
	"Thumb1.L": "larmL", "Thumb2.L": "larmL",
	"Shoulder.R": "torso", "UpperArm.R": "uarmR", "LowerArm.R": "larmR",
	"Palm.R": "larmR", "MiddleHand.R": "larmR", "Fingers.R": "larmR",
	"Thumb1.R": "larmR", "Thumb2.R": "larmR",
	"UpperLeg.L": "ulegL", "LowerLeg.L": "llegL", "Foot.L": "llegL", "PoleTarget.L": "llegL",
	"UpperLeg.R": "ulegR", "LowerLeg.R": "llegR", "Foot.R": "llegR", "PoleTarget.R": "llegR",
}

# [body a, body b, anchor bone, cone half-angle degrees]
const JOINTS := [
	["pelvis", "torso", "Abdomen", 40.0],
	["torso", "head", "Neck", 35.0],
	["torso", "uarmL", "UpperArm.L", 95.0],
	["uarmL", "larmL", "LowerArm.L", 95.0],   # elbow
	["torso", "uarmR", "UpperArm.R", 95.0],
	["uarmR", "larmR", "LowerArm.R", 95.0],   # elbow
	["pelvis", "ulegL", "UpperLeg.L", 65.0],
	["ulegL", "llegL", "LowerLeg.L", 75.0],   # knee
	["pelvis", "ulegR", "UpperLeg.R", 65.0],
	["ulegR", "llegR", "LowerLeg.R", 75.0],   # knee
]

var _skel: Skeleton3D
var _bodies := {}          # seg name -> Box3DBody
var _parts: Array = []     # all bodies
var _drive: Array = []     # [bone_idx, Box3DBody, offset] for skinning
var _joint_anchors := {}   # anchor bone name -> world position (rest)
var _activated := false


static func spawn(parent: Node3D, at: Vector3, rng: RandomNumberGenerator,
		yaw := 0.0) -> Node3D:
	var r: Node3D = _Self.new()
	r.position = at
	r.rotation.y = yaw
	parent.add_child(r)
	r._build(rng)
	return r


func _build(_rng: RandomNumberGenerator) -> void:
	add_to_group("ragdoll_ctrl")
	var s: float = HEIGHT / RAW_HEIGHT

	# The skinned character: scale it down and keep it standing in the bind pose.
	var char: Node3D = CHAR.instantiate()
	char.scale = Vector3(s, s, s)
	add_child(char)
	for n in _all_nodes(char):
		if n is AnimationPlayer:
			n.queue_free()  # don't let baked anims fight our bone driving
		if n is Skeleton3D:
			_skel = n
		if n is MeshInstance3D:
			n.extra_cull_margin = 16.0  # bones fly far; don't cull the mesh
	if _skel == null:
		push_error("human_ragdoll: no skeleton in model")
		return

	# Lift so the feet rest ON the ground: the lower-leg capsules must not dip
	# below y=0, or the feet get pinned in the floor when the ragdoll flops.
	var sg0 := _skel.global_transform
	var foot_y := minf(
			(sg0 * _skel.get_bone_global_pose(_skel.find_bone("Foot.L"))).origin.y,
			(sg0 * _skel.get_bone_global_pose(_skel.find_bone("Foot.R"))).origin.y)
	char.position.y += maxf(0.0, 0.10 - foot_y)  # 0.068 leg radius + margin

	var ci := global_transform.affine_inverse()
	var sg := _skel.global_transform

	# Bone rest transforms (world) we need for placement + driving.
	var bx := {}
	for seg in SEGMENTS:
		for nm in [seg[1], seg[2], seg[5]]:
			if not nm.begins_with("^") and not bx.has(nm):
				bx[nm] = sg * _skel.get_bone_global_pose(_skel.find_bone(nm))
	for jd in JOINTS:
		var nm: String = jd[2]
		if not bx.has(nm):
			bx[nm] = sg * _skel.get_bone_global_pose(_skel.find_bone(nm))

	for seg in SEGMENTS:
		var p_from: Vector3 = bx[seg[1]].origin
		var p_to: Vector3 = _point(seg[2], bx)
		_make_body(seg[0], p_from, p_to, seg[3], seg[4] == "box", ci)

	# Drive EVERY bone from its assigned body (offset captured at the bind pose).
	for bone_name in BONE_BODY:
		var body: Box3DBody = _bodies.get(BONE_BODY[bone_name])
		var bi := _skel.find_bone(bone_name)
		if body == null or bi < 0:
			continue
		var bone_world: Transform3D = sg * _skel.get_bone_global_pose(bi)
		var offset := body.global_transform.affine_inverse() * bone_world
		_drive.append([bi, body, offset])
	# Parent bones (lower index) first, so each child poses off an updated parent.
	_drive.sort_custom(func(x, y): return x[0] < y[0])

	for jd in JOINTS:
		_joint_anchors[jd[2]] = bx[jd[2]].origin


## World point for a segment's "to" field: a bone, or "^Head" above the head.
func _point(token: String, bx: Dictionary) -> Vector3:
	if token == "^Head":
		var h: Vector3 = bx["Head"].origin
		return h + (h - bx["Neck"].origin) * 1.1
	return bx[token].origin


## Build one kinematic body spanning two world points. Capsules for limbs, a
## box for the trunk/head. `ci` is the controller's inverse global transform.
func _make_body(seg_name: String, a: Vector3, b: Vector3, radius: float,
		as_box: bool, ci: Transform3D) -> Box3DBody:
	var mid := (a + b) * 0.5
	var axis := b - a
	var length := maxf(axis.length(), 0.02)
	var basis := Basis.IDENTITY
	if axis.normalized().dot(Vector3.UP) < 0.9999:
		basis = Basis(Quaternion(Vector3.UP, axis.normalized()))
	var body := Box3DBody.new()
	body.body_type = Box3DBody.KINEMATIC
	if as_box:
		body.shape_type = Box3DBody.BOX
		body.box_size = Vector3(radius * 2.0, length, radius * 2.0)
	else:
		body.shape_type = Box3DBody.CAPSULE
		body.capsule_radius = radius
		body.capsule_height = maxf(length, radius * 2.0)
	body.density = 1.0
	body.friction = 0.9
	body.add_to_group("ragdoll")
	body.add_to_group("prop")
	# Box3D snapshots the transform on READY (add_child), so set it first; it
	# lives under the controller, so convert the world pose to local.
	body.transform = ci * Transform3D(basis, mid)
	add_child(body)
	_bodies[seg_name] = body
	_parts.append(body)
	return body


func _all_nodes(root: Node) -> Array:
	var out: Array = [root]
	var stack := [root]
	while stack.size() > 0:
		var n = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


## While standing (kinematic) watch for a fast body entering our space and wake
## on contact. Once active, drive the skeleton from the physics bodies so the
## skinned mesh flops with them.
func _physics_process(_delta: float) -> void:
	if _activated:
		_drive_skeleton()
		return
	var w := get_parent()
	if not w is Box3DWorld:
		return
	for b in (w as Box3DWorld).overlap_sphere(global_position + Vector3(0, 0.9, 0), 1.4):
		if b == null or not (b is Box3DBody) or b.is_in_group("ragdoll"):
			continue
		if b.get_linear_velocity().length() >= ACTIVATE_SPEED:
			activate()
			return


func _drive_skeleton() -> void:
	var sgi := _skel.global_transform.affine_inverse()
	for d in _drive:
		var body: Box3DBody = d[1]
		if not is_instance_valid(body):
			continue
		# body world -> bone world -> skeleton-local pose
		_skel.set_bone_global_pose(d[0], sgi * (body.global_transform * d[2]))


## Wake: flip every body to dynamic, THEN wire the joints (a Box3D joint built
## against a kinematic body is inert once it turns dynamic).
func activate() -> void:
	if _activated:
		return
	_activated = true
	for p in _parts:
		p.body_type = Box3DBody.DYNAMIC
	_wire_joints()


func _wire_joints() -> void:
	var ci := global_transform.affine_inverse()
	for jd in JOINTS:
		if not (_bodies.has(jd[0]) and _bodies.has(jd[1])):
			continue
		var joint := Box3DBallJoint.new()
		joint.collide_connected = false
		joint.cone_limit_enabled = true
		joint.cone_angle = deg_to_rad(jd[3])
		joint.spring_enabled = true
		joint.spring_hertz = 6.0
		joint.spring_damping = 0.6
		# Anchor (world) -> controller-local; paths + transform set before add.
		joint.position = ci * _joint_anchors[jd[2]]
		joint.body_a = _bodies[jd[0]].get_path()
		joint.body_b = _bodies[jd[1]].get_path()
		add_child(joint)


## Blast coupling (ExplosionFX broadcasts to group "ragdoll_ctrl").
func blast(at: Vector3, radius: float, impulse: float) -> void:
	var reach := radius * 1.4
	if global_position.distance_to(at) > reach + 1.0:
		return
	activate()
	for p in _parts:
		var to: Vector3 = p.global_position - at
		var d := to.length()
		if d < reach:
			to.y += 0.4
			p.apply_central_impulse(to.normalized() * p.get_mass()
					* (4.0 + impulse * 1.6) * (1.0 - d / reach))
