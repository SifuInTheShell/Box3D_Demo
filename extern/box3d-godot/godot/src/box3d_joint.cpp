// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_joint.h"

#include "box3d_body.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cfloat>

using namespace godot;

// ---------------------------------------------------------------------------
// Box3DJoint (base)
// ---------------------------------------------------------------------------

Box3DJoint::Box3DJoint() {}

Box3DJoint::~Box3DJoint() {}

Box3DWorld *Box3DJoint::find_world() {
	Node *node = get_parent();
	while (node != nullptr) {
		Box3DWorld *w = Object::cast_to<Box3DWorld>(node);
		if (w != nullptr) {
			return w;
		}
		node = node->get_parent();
	}
	return nullptr;
}

Box3DBody *Box3DJoint::resolve_body(const NodePath &p_path) {
	if (p_path.is_empty()) {
		return nullptr;
	}
	return Object::cast_to<Box3DBody>(get_node_or_null(p_path));
}

b3Transform Box3DJoint::local_frame(const Transform3D &p_body, const Transform3D &p_joint) const {
	return to_b3_transform(p_body.affine_inverse() * p_joint);
}

bool Box3DJoint::is_joint_valid() const {
	return joint_live();
}

// Validity check that also syncs with an in-flight async world step: touching
// the b3 API while the solver thread runs would race, so wait it out first
// (a single atomic load when nothing is in flight).
bool Box3DJoint::joint_live() const {
	if (world != nullptr) {
		world->join_async_step();
	}
	return b3Joint_IsValid(joint_id);
}

void Box3DJoint::create_joint() {
	if (Engine::get_singleton()->is_editor_hint() || joint_live()) {
		return;
	}
	world = find_world();
	if (world == nullptr) {
		UtilityFunctions::push_warning("Box3DJoint has no Box3DWorld ancestor; it will not be created.");
		return;
	}
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		return;
	}

	Box3DBody *body_a = resolve_body(body_a_path);
	if (body_a == nullptr || !b3Body_IsValid(body_a->get_body_id())) {
		UtilityFunctions::push_warning("Box3DJoint requires a valid body_a.");
		return;
	}
	b3BodyId id_a = body_a->get_body_id();
	// Body frames come from the solver, not the Godot nodes: a node can lag a
	// tick behind (async stepping) or be frozen at its spawn pose entirely
	// (sync_node_transform off under Box3DMultiMeshRenderer), and a joint
	// anchored to a stale frame grabs the body in the wrong place.
	b3WorldTransform b3_xf_a = b3Body_GetTransform(id_a);
	Transform3D xf_a(Basis(to_gd(b3_xf_a.q)), to_gd_pos(b3_xf_a.p));

	Transform3D joint_xf = get_global_transform();

	b3BodyId id_b;
	Transform3D xf_b;
	Box3DBody *body_b = resolve_body(body_b_path);
	if (body_b != nullptr && b3Body_IsValid(body_b->get_body_id())) {
		id_b = body_b->get_body_id();
		b3WorldTransform b3_xf_b = b3Body_GetTransform(id_b);
		xf_b = Transform3D(Basis(to_gd(b3_xf_b.q)), to_gd_pos(b3_xf_b.p));
	} else {
		// No body_b: anchor to the world with a static body at the joint origin.
		b3BodyDef def = b3DefaultBodyDef();
		def.type = b3_staticBody;
		def.position = to_b3_pos(joint_xf.origin);
		anchor_id = b3CreateBody(world_id, &def);
		id_b = anchor_id;
		xf_b = Transform3D(Basis(), joint_xf.origin);
	}

	joint_id = create_specific(world_id, id_a, id_b, xf_a, xf_b, joint_xf);

	// --- Extended core access III: the node is the joint's b3 user data, so a
	// raw b3JointId (joint events, b3Body_GetJoints) maps back via from_joint_id.
	if (b3Joint_IsValid(joint_id)) {
		b3Joint_SetUserData(joint_id, this);
	}

	// Joints are created deferred, so the connected bodies may have already
	// collided — jointed bodies legitimately overlap (e.g. wheels inside a
	// chassis). b3CreateJoint does NOT remove a pre-existing contact between
	// the pair, and with collide_connected off that stale deep contact keeps
	// shoving the bodies apart and fights the joint forever (a wheel pinned
	// into its chassis can't even spin). The live toggle is the one box3d API
	// that purges those contacts, and it early-outs unless the value changes,
	// so bounce it through true -> false.
	// (Extended core access III: read the engine-side flag, so joints that
	// force it, like Box3DFilterJoint, purge too.)
	if (joint_live() && !b3Joint_GetCollideConnected(joint_id)) {
		b3Joint_SetCollideConnected(joint_id, true);
		b3Joint_SetCollideConnected(joint_id, false);
	}
}

void Box3DJoint::destroy_joint() {
	if (joint_live()) {
		b3DestroyJoint(joint_id, true);
	}
	joint_id = b3_nullJointId;
	if (b3Body_IsValid(anchor_id)) {
		b3DestroyBody(anchor_id);
	}
	anchor_id = b3_nullBodyId;
}

void Box3DJoint::rebuild_if_alive() {
	if (joint_live()) {
		destroy_joint();
		create_joint();
	}
}

void Box3DJoint::wake_bodies() {
	if (joint_live()) {
		b3Joint_WakeBodies(joint_id);
	}
}

void Box3DJoint::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				// Create NOW if the referenced bodies already exist. A deferred
				// create leaves a window where a physics tick steps the bodies
				// unjointed — for a ragdoll spawned at runtime mid-session the
				// bones scatter for that tick and the late joint then freezes
				// the scattered pose in as its rest frame. Bodies earlier in
				// tree order (the common case) are ready before the joint, so
				// this path is immediate; only when a referenced body has not
				// been created yet (scene-load order places it after the
				// joint) fall back to the deferred retry the old behavior
				// existed for.
				Box3DBody *a = resolve_body(body_a_path);
				Box3DBody *b = resolve_body(body_b_path);
				bool a_ready = a != nullptr && a->is_body_valid();
				bool b_ready = body_b_path.is_empty() || (b != nullptr && b->is_body_valid());
				if (a_ready && b_ready) {
					create_joint();
				} else {
					callable_mp(this, &Box3DJoint::create_joint).call_deferred();
				}
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			destroy_joint();
			world = nullptr;
		} break;
	}
}

void Box3DJoint::set_body_a(const NodePath &p_path) {
	body_a_path = p_path;
	rebuild_if_alive();
}

NodePath Box3DJoint::get_body_a() const {
	return body_a_path;
}

void Box3DJoint::set_body_b(const NodePath &p_path) {
	body_b_path = p_path;
	rebuild_if_alive();
}

NodePath Box3DJoint::get_body_b() const {
	return body_b_path;
}

void Box3DJoint::set_collide_connected(bool p_enabled) {
	collide_connected = p_enabled;
	rebuild_if_alive();
}

bool Box3DJoint::get_collide_connected() const {
	return collide_connected;
}

// --- Extended core access -----------------------------------------------------

Vector3 Box3DJoint::get_constraint_force() const {
	if (!joint_live()) {
		return Vector3();
	}
	return to_gd(b3Joint_GetConstraintForce(joint_id));
}

Vector3 Box3DJoint::get_constraint_torque() const {
	if (!joint_live()) {
		return Vector3();
	}
	return to_gd(b3Joint_GetConstraintTorque(joint_id));
}

double Box3DJoint::get_linear_separation() const {
	if (!joint_live()) {
		return 0.0;
	}
	return b3Joint_GetLinearSeparation(joint_id);
}

double Box3DJoint::get_angular_separation() const {
	if (!joint_live()) {
		return 0.0;
	}
	return b3Joint_GetAngularSeparation(joint_id);
}

void Box3DJoint::set_force_threshold(double p_force) {
	if (joint_live()) {
		b3Joint_SetForceThreshold(joint_id, (float)p_force);
	}
}

double Box3DJoint::get_force_threshold() const {
	if (!joint_live()) {
		return 0.0;
	}
	return b3Joint_GetForceThreshold(joint_id);
}

void Box3DJoint::set_torque_threshold(double p_torque) {
	if (joint_live()) {
		b3Joint_SetTorqueThreshold(joint_id, (float)p_torque);
	}
}

double Box3DJoint::get_torque_threshold() const {
	if (!joint_live()) {
		return 0.0;
	}
	return b3Joint_GetTorqueThreshold(joint_id);
}

int Box3DJoint::get_joint_type() const {
	if (!joint_live()) {
		return -1;
	}
	return (int)b3Joint_GetType(joint_id);
}

// Frame A/B always mean the frames on this node's body_a/body_b; for joints
// whose b3 body order is swapped (mover / pogo) that is b3's frame B/A.
Transform3D Box3DJoint::get_local_frame_a() const {
	if (!joint_live()) {
		return Transform3D();
	}
	return to_gd_transform(swaps_bodies() ? b3Joint_GetLocalFrameB(joint_id) : b3Joint_GetLocalFrameA(joint_id));
}

void Box3DJoint::set_local_frame_a(const Transform3D &p_frame) {
	if (joint_live()) {
		if (swaps_bodies()) {
			b3Joint_SetLocalFrameB(joint_id, to_b3_transform(p_frame));
		} else {
			b3Joint_SetLocalFrameA(joint_id, to_b3_transform(p_frame));
		}
	}
}

Transform3D Box3DJoint::get_local_frame_b() const {
	if (!joint_live()) {
		return Transform3D();
	}
	return to_gd_transform(swaps_bodies() ? b3Joint_GetLocalFrameA(joint_id) : b3Joint_GetLocalFrameB(joint_id));
}

void Box3DJoint::set_local_frame_b(const Transform3D &p_frame) {
	if (joint_live()) {
		if (swaps_bodies()) {
			b3Joint_SetLocalFrameA(joint_id, to_b3_transform(p_frame));
		} else {
			b3Joint_SetLocalFrameB(joint_id, to_b3_transform(p_frame));
		}
	}
}

Dictionary Box3DJoint::get_constraint_tuning() const {
	Dictionary d;
	if (!joint_live()) {
		return d;
	}
	float hertz = 0.0f;
	float damping = 0.0f;
	b3Joint_GetConstraintTuning(joint_id, &hertz, &damping);
	d["hertz"] = hertz;
	d["damping"] = damping;
	return d;
}

void Box3DJoint::set_constraint_tuning(double p_hertz, double p_damping) {
	if (joint_live()) {
		b3Joint_SetConstraintTuning(joint_id, (float)p_hertz, (float)p_damping);
	}
}

// --- Extended core access III: identity, sleep state, live readback ---------

bool Box3DJoint::is_awake() const {
	return joint_live() ? b3Joint_IsAwake(joint_id) : false;
}

void Box3DJoint::wake_connected_bodies() {
	wake_bodies();
}

Box3DBody *Box3DJoint::get_body_a_node() const {
	if (!joint_live()) {
		return nullptr;
	}
	b3BodyId id = swaps_bodies() ? b3Joint_GetBodyB(joint_id) : b3Joint_GetBodyA(joint_id);
	// Box3DBody stores itself as body user data; the world anchor has none.
	return b3Body_IsValid(id) ? static_cast<Box3DBody *>(b3Body_GetUserData(id)) : nullptr;
}

Box3DBody *Box3DJoint::get_body_b_node() const {
	if (!joint_live()) {
		return nullptr;
	}
	b3BodyId id = swaps_bodies() ? b3Joint_GetBodyA(joint_id) : b3Joint_GetBodyB(joint_id);
	return b3Body_IsValid(id) ? static_cast<Box3DBody *>(b3Body_GetUserData(id)) : nullptr;
}

Box3DWorld *Box3DJoint::get_world_node() const {
	if (!joint_live() || world == nullptr) {
		return nullptr;
	}
	b3WorldId jw = b3Joint_GetWorld(joint_id);
	b3WorldId ww = world->get_world_id();
	return (jw.index1 == ww.index1 && jw.generation == ww.generation) ? world : nullptr;
}

Dictionary Box3DJoint::get_live_settings() const {
	Dictionary d;
	if (!joint_live()) {
		return d;
	}
	d["joint_type"] = (int)b3Joint_GetType(joint_id);
	d["collide_connected"] = b3Joint_GetCollideConnected(joint_id);
	d["force_threshold"] = b3Joint_GetForceThreshold(joint_id);
	d["torque_threshold"] = b3Joint_GetTorqueThreshold(joint_id);
	float hertz = 0.0f;
	float damping = 0.0f;
	b3Joint_GetConstraintTuning(joint_id, &hertz, &damping);
	d["constraint_hertz"] = hertz;
	d["constraint_damping"] = damping;
	fill_live_settings(d);
	return d;
}

Box3DJoint *Box3DJoint::from_joint_id(b3JointId p_id) {
	if (!b3Joint_IsValid(p_id)) {
		return nullptr;
	}
	return static_cast<Box3DJoint *>(b3Joint_GetUserData(p_id));
}

void Box3DJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_joint_valid"), &Box3DJoint::is_joint_valid);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("is_awake"), &Box3DJoint::is_awake);
	ClassDB::bind_method(D_METHOD("wake_connected_bodies"), &Box3DJoint::wake_connected_bodies);
	ClassDB::bind_method(D_METHOD("get_body_a_node"), &Box3DJoint::get_body_a_node);
	ClassDB::bind_method(D_METHOD("get_body_b_node"), &Box3DJoint::get_body_b_node);
	ClassDB::bind_method(D_METHOD("get_world_node"), &Box3DJoint::get_world_node);
	ClassDB::bind_method(D_METHOD("get_live_settings"), &Box3DJoint::get_live_settings);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_PARALLEL", b3_parallelJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_DISTANCE", b3_distanceJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_FILTER", b3_filterJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_MOTOR", b3_motorJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_PRISMATIC", b3_prismaticJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_REVOLUTE", b3_revoluteJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_SPHERICAL", b3_sphericalJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_WELD", b3_weldJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_WHEEL", b3_wheelJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_MOVER", b3_moverJoint);
	ClassDB::bind_integer_constant(get_class_static(), "", "JOINT_TYPE_POGO", b3_pogoJoint);

	ClassDB::bind_method(D_METHOD("get_constraint_force"), &Box3DJoint::get_constraint_force);
	ClassDB::bind_method(D_METHOD("get_constraint_torque"), &Box3DJoint::get_constraint_torque);
	ClassDB::bind_method(D_METHOD("get_linear_separation"), &Box3DJoint::get_linear_separation);
	ClassDB::bind_method(D_METHOD("get_angular_separation"), &Box3DJoint::get_angular_separation);
	ClassDB::bind_method(D_METHOD("set_force_threshold", "force"), &Box3DJoint::set_force_threshold);
	ClassDB::bind_method(D_METHOD("get_force_threshold"), &Box3DJoint::get_force_threshold);
	ClassDB::bind_method(D_METHOD("set_torque_threshold", "torque"), &Box3DJoint::set_torque_threshold);
	ClassDB::bind_method(D_METHOD("get_torque_threshold"), &Box3DJoint::get_torque_threshold);
	ClassDB::bind_method(D_METHOD("get_joint_type"), &Box3DJoint::get_joint_type);
	ClassDB::bind_method(D_METHOD("get_local_frame_a"), &Box3DJoint::get_local_frame_a);
	ClassDB::bind_method(D_METHOD("set_local_frame_a", "frame"), &Box3DJoint::set_local_frame_a);
	ClassDB::bind_method(D_METHOD("get_local_frame_b"), &Box3DJoint::get_local_frame_b);
	ClassDB::bind_method(D_METHOD("set_local_frame_b", "frame"), &Box3DJoint::set_local_frame_b);
	ClassDB::bind_method(D_METHOD("get_constraint_tuning"), &Box3DJoint::get_constraint_tuning);
	ClassDB::bind_method(D_METHOD("set_constraint_tuning", "hertz", "damping"), &Box3DJoint::set_constraint_tuning);
	ClassDB::bind_method(D_METHOD("set_body_a", "path"), &Box3DJoint::set_body_a);
	ClassDB::bind_method(D_METHOD("get_body_a"), &Box3DJoint::get_body_a);
	ClassDB::bind_method(D_METHOD("set_body_b", "path"), &Box3DJoint::set_body_b);
	ClassDB::bind_method(D_METHOD("get_body_b"), &Box3DJoint::get_body_b);
	ClassDB::bind_method(D_METHOD("set_collide_connected", "enabled"), &Box3DJoint::set_collide_connected);
	ClassDB::bind_method(D_METHOD("get_collide_connected"), &Box3DJoint::get_collide_connected);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "body_a", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Box3DBody"), "set_body_a", "get_body_a");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "body_b", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Box3DBody"), "set_body_b", "get_body_b");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collide_connected"), "set_collide_connected", "get_collide_connected");
}

// ---------------------------------------------------------------------------
// Box3DHingeJoint (revolute)
// ---------------------------------------------------------------------------

b3JointId Box3DHingeJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.enableLimit = limit_enabled;
	def.lowerAngle = (float)lower_limit;
	def.upperAngle = (float)upper_limit;
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorTorque = (float)max_motor_torque;
	// Angular spring toward the spawn pose (frames coincide at creation, so the
	// rest angle is 0 = the authored pose). Ragdolls use this to hold a stance.
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.targetAngle = (float)CLAMP(target_angle, -Math_PI, Math_PI);
	return b3CreateRevoluteJoint(p_world, &def);
}

// Extended core access III: limit / torque / spring settings use the live b3
// setters instead of rebuilding (a rebuild re-anchors the joint at the
// current pose, which silently moved the spring rest angle).
void Box3DHingeJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableLimit(joint_id, p_v);
	}
}
bool Box3DHingeJoint::get_limit_enabled() const { return limit_enabled; }
void Box3DHingeJoint::set_lower_limit(double p_v) {
	lower_limit = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
}
double Box3DHingeJoint::get_lower_limit() const { return lower_limit; }
void Box3DHingeJoint::set_upper_limit(double p_v) {
	upper_limit = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
}
double Box3DHingeJoint::get_upper_limit() const { return upper_limit; }

void Box3DHingeJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableMotor(joint_id, p_v);
	}
}
bool Box3DHingeJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DHingeJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DHingeJoint::get_motor_speed() const { return motor_speed; }

void Box3DHingeJoint::set_max_motor_torque(double p_v) {
	max_motor_torque = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetMaxMotorTorque(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DHingeJoint::get_max_motor_torque() const { return max_motor_torque; }

void Box3DHingeJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3RevoluteJoint_EnableSpring(joint_id, p_v);
		wake_bodies();
	}
}
bool Box3DHingeJoint::get_spring_enabled() const { return spring_enabled; }
void Box3DHingeJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetSpringHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DHingeJoint::get_spring_hertz() const { return spring_hertz; }
void Box3DHingeJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetSpringDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DHingeJoint::get_spring_damping() const { return spring_damping; }

// --- Extended core access III ---
void Box3DHingeJoint::set_target_angle(double p_v) {
	bool changed = p_v != target_angle;
	target_angle = p_v;
	if (joint_live()) {
		b3RevoluteJoint_SetTargetAngle(joint_id, (float)CLAMP(p_v, -Math_PI, Math_PI));
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DHingeJoint::get_target_angle() const { return target_angle; }
double Box3DHingeJoint::get_current_angle() const {
	return joint_live() ? b3RevoluteJoint_GetAngle(joint_id) : 0.0;
}
double Box3DHingeJoint::get_current_motor_torque() const {
	return joint_live() ? b3RevoluteJoint_GetMotorTorque(joint_id) : 0.0;
}

void Box3DHingeJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["limit_enabled"] = b3RevoluteJoint_IsLimitEnabled(joint_id);
	r_d["lower_limit"] = b3RevoluteJoint_GetLowerLimit(joint_id);
	r_d["upper_limit"] = b3RevoluteJoint_GetUpperLimit(joint_id);
	r_d["motor_enabled"] = b3RevoluteJoint_IsMotorEnabled(joint_id);
	r_d["motor_speed"] = b3RevoluteJoint_GetMotorSpeed(joint_id);
	r_d["max_motor_torque"] = b3RevoluteJoint_GetMaxMotorTorque(joint_id);
	r_d["spring_enabled"] = b3RevoluteJoint_IsSpringEnabled(joint_id);
	r_d["spring_hertz"] = b3RevoluteJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3RevoluteJoint_GetSpringDampingRatio(joint_id);
	r_d["target_angle"] = b3RevoluteJoint_GetTargetAngle(joint_id);
}

void Box3DHingeJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DHingeJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DHingeJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_limit", "radians"), &Box3DHingeJoint::set_lower_limit);
	ClassDB::bind_method(D_METHOD("get_lower_limit"), &Box3DHingeJoint::get_lower_limit);
	ClassDB::bind_method(D_METHOD("set_upper_limit", "radians"), &Box3DHingeJoint::set_upper_limit);
	ClassDB::bind_method(D_METHOD("get_upper_limit"), &Box3DHingeJoint::get_upper_limit);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DHingeJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DHingeJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "radians_per_sec"), &Box3DHingeJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DHingeJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_torque", "torque"), &Box3DHingeJoint::set_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_max_motor_torque"), &Box3DHingeJoint::get_max_motor_torque);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DHingeJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DHingeJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DHingeJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DHingeJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DHingeJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DHingeJoint::get_spring_damping);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("set_target_angle", "radians"), &Box3DHingeJoint::set_target_angle);
	ClassDB::bind_method(D_METHOD("get_target_angle"), &Box3DHingeJoint::get_target_angle);
	ClassDB::bind_method(D_METHOD("get_current_angle"), &Box3DHingeJoint::get_current_angle);
	ClassDB::bind_method(D_METHOD("get_current_motor_torque"), &Box3DHingeJoint::get_current_motor_torque);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_limit", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_lower_limit", "get_lower_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_limit", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_upper_limit", "get_upper_limit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-50,50,0.1"), "set_motor_speed", "get_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_torque", PROPERTY_HINT_RANGE, "0,10000,1,or_greater"), "set_max_motor_torque", "get_max_motor_torque");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,30,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,4,0.05,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_angle", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_target_angle", "get_target_angle");
}

// ---------------------------------------------------------------------------
// Box3DSliderJoint (prismatic)
// ---------------------------------------------------------------------------

b3JointId Box3DSliderJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3PrismaticJointDef def = b3DefaultPrismaticJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.enableLimit = limit_enabled;
	def.lowerTranslation = (float)lower_limit;
	def.upperTranslation = (float)upper_limit;
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorForce = (float)max_motor_force;
	// Extended core access III: linear spring toward target_translation.
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.targetTranslation = (float)target_translation;
	return b3CreatePrismaticJoint(p_world, &def);
}

void Box3DSliderJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableLimit(joint_id, p_v);
	}
}
bool Box3DSliderJoint::get_limit_enabled() const { return limit_enabled; }
void Box3DSliderJoint::set_lower_limit(double p_v) {
	lower_limit = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
}
double Box3DSliderJoint::get_lower_limit() const { return lower_limit; }
void Box3DSliderJoint::set_upper_limit(double p_v) {
	upper_limit = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetLimits(joint_id, (float)lower_limit, (float)upper_limit);
	}
}
double Box3DSliderJoint::get_upper_limit() const { return upper_limit; }

void Box3DSliderJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableMotor(joint_id, p_v);
	}
}
bool Box3DSliderJoint::get_motor_enabled() const { return motor_enabled; }

void Box3DSliderJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DSliderJoint::get_motor_speed() const { return motor_speed; }

void Box3DSliderJoint::set_max_motor_force(double p_v) {
	max_motor_force = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetMaxMotorForce(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DSliderJoint::get_max_motor_force() const { return max_motor_force; }

// --- Extended core access III ---
void Box3DSliderJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3PrismaticJoint_EnableSpring(joint_id, p_v);
		wake_bodies();
	}
}
bool Box3DSliderJoint::get_spring_enabled() const { return spring_enabled; }
void Box3DSliderJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetSpringHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DSliderJoint::get_spring_hertz() const { return spring_hertz; }
void Box3DSliderJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetSpringDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DSliderJoint::get_spring_damping() const { return spring_damping; }
void Box3DSliderJoint::set_target_translation(double p_v) {
	bool changed = p_v != target_translation;
	target_translation = p_v;
	if (joint_live()) {
		b3PrismaticJoint_SetTargetTranslation(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DSliderJoint::get_target_translation() const { return target_translation; }
double Box3DSliderJoint::get_current_translation() const {
	return joint_live() ? b3PrismaticJoint_GetTranslation(joint_id) : 0.0;
}
double Box3DSliderJoint::get_current_speed() const {
	return joint_live() ? b3PrismaticJoint_GetSpeed(joint_id) : 0.0;
}
double Box3DSliderJoint::get_current_motor_force() const {
	return joint_live() ? b3PrismaticJoint_GetMotorForce(joint_id) : 0.0;
}

void Box3DSliderJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["limit_enabled"] = b3PrismaticJoint_IsLimitEnabled(joint_id);
	r_d["lower_limit"] = b3PrismaticJoint_GetLowerLimit(joint_id);
	r_d["upper_limit"] = b3PrismaticJoint_GetUpperLimit(joint_id);
	r_d["motor_enabled"] = b3PrismaticJoint_IsMotorEnabled(joint_id);
	r_d["motor_speed"] = b3PrismaticJoint_GetMotorSpeed(joint_id);
	r_d["max_motor_force"] = b3PrismaticJoint_GetMaxMotorForce(joint_id);
	r_d["spring_enabled"] = b3PrismaticJoint_IsSpringEnabled(joint_id);
	r_d["spring_hertz"] = b3PrismaticJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3PrismaticJoint_GetSpringDampingRatio(joint_id);
	r_d["target_translation"] = b3PrismaticJoint_GetTargetTranslation(joint_id);
}

void Box3DSliderJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DSliderJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DSliderJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_limit", "meters"), &Box3DSliderJoint::set_lower_limit);
	ClassDB::bind_method(D_METHOD("get_lower_limit"), &Box3DSliderJoint::get_lower_limit);
	ClassDB::bind_method(D_METHOD("set_upper_limit", "meters"), &Box3DSliderJoint::set_upper_limit);
	ClassDB::bind_method(D_METHOD("get_upper_limit"), &Box3DSliderJoint::get_upper_limit);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DSliderJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DSliderJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "meters_per_sec"), &Box3DSliderJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DSliderJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_force", "force"), &Box3DSliderJoint::set_max_motor_force);
	ClassDB::bind_method(D_METHOD("get_max_motor_force"), &Box3DSliderJoint::get_max_motor_force);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DSliderJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DSliderJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DSliderJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DSliderJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DSliderJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DSliderJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_target_translation", "meters"), &Box3DSliderJoint::set_target_translation);
	ClassDB::bind_method(D_METHOD("get_target_translation"), &Box3DSliderJoint::get_target_translation);
	ClassDB::bind_method(D_METHOD("get_current_translation"), &Box3DSliderJoint::get_current_translation);
	ClassDB::bind_method(D_METHOD("get_current_speed"), &Box3DSliderJoint::get_current_speed);
	ClassDB::bind_method(D_METHOD("get_current_motor_force"), &Box3DSliderJoint::get_current_motor_force);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater"), "set_lower_limit", "get_lower_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater"), "set_upper_limit", "get_upper_limit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-20,20,0.1"), "set_motor_speed", "get_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_force", PROPERTY_HINT_RANGE, "0,10000,1,or_greater"), "set_max_motor_force", "get_max_motor_force");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_translation", PROPERTY_HINT_RANGE, "-10,10,0.01,or_less,or_greater"), "set_target_translation", "get_target_translation");
}

// ---------------------------------------------------------------------------
// Box3DDistanceJoint
// ---------------------------------------------------------------------------

b3JointId Box3DDistanceJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3DistanceJointDef def = b3DefaultDistanceJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	// Anchor at each body's origin, so the joint spans body centers.
	def.base.localFrameA = b3Transform_identity;
	def.base.localFrameB = b3Transform_identity;
	def.base.collideConnected = collide_connected;
	double len = length;
	if (len < 0.0) {
		len = p_xf_a.origin.distance_to(p_xf_b.origin);
	}
	def.length = (float)len;
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	def.enableLimit = limit_enabled;
	def.minLength = (float)min_length;
	def.maxLength = (float)max_length;
	// Extended core access III: spring force range + motor.
	def.lowerSpringForce = std::isfinite(lower_spring_force) ? (float)lower_spring_force : -FLT_MAX;
	def.upperSpringForce = std::isfinite(upper_spring_force) ? (float)upper_spring_force : FLT_MAX;
	if (def.lowerSpringForce > def.upperSpringForce) {
		def.lowerSpringForce = def.upperSpringForce;
	}
	def.enableMotor = motor_enabled;
	def.motorSpeed = (float)motor_speed;
	def.maxMotorForce = (float)max_motor_force;
	return b3CreateDistanceJoint(p_world, &def);
}

void Box3DDistanceJoint::set_length(double p_v) {
	length = p_v;
	if (joint_live() && p_v >= 0.0) {
		b3DistanceJoint_SetLength(joint_id, (float)p_v);
	} else {
		rebuild_if_alive();
	}
}
double Box3DDistanceJoint::get_length() const { return length; }
// Extended core access III: spring / limit settings use the live b3 setters.
void Box3DDistanceJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableSpring(joint_id, p_v);
		wake_bodies();
	}
}
bool Box3DDistanceJoint::get_spring_enabled() const { return spring_enabled; }
void Box3DDistanceJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetSpringHertz(joint_id, (float)p_v);
	}
}
double Box3DDistanceJoint::get_spring_hertz() const { return spring_hertz; }
void Box3DDistanceJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetSpringDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DDistanceJoint::get_spring_damping() const { return spring_damping; }
void Box3DDistanceJoint::set_limit_enabled(bool p_v) {
	limit_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableLimit(joint_id, p_v);
	}
}
bool Box3DDistanceJoint::get_limit_enabled() const { return limit_enabled; }
void Box3DDistanceJoint::set_min_length(double p_v) {
	min_length = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetLengthRange(joint_id, (float)min_length, (float)max_length);
	}
}
double Box3DDistanceJoint::get_min_length() const { return min_length; }
void Box3DDistanceJoint::set_max_length(double p_v) {
	max_length = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetLengthRange(joint_id, (float)min_length, (float)max_length);
	}
}
double Box3DDistanceJoint::get_max_length() const { return max_length; }

// --- Extended core access III ---
void Box3DDistanceJoint::apply_spring_force_range() {
	if (!joint_live()) {
		return;
	}
	float lower = std::isfinite(lower_spring_force) ? (float)lower_spring_force : -FLT_MAX;
	float upper = std::isfinite(upper_spring_force) ? (float)upper_spring_force : FLT_MAX;
	b3DistanceJoint_SetSpringForceRange(joint_id, MIN(lower, upper), upper);
}
void Box3DDistanceJoint::set_lower_spring_force(double p_v) { lower_spring_force = p_v; apply_spring_force_range(); }
double Box3DDistanceJoint::get_lower_spring_force() const { return lower_spring_force; }
void Box3DDistanceJoint::set_upper_spring_force(double p_v) { upper_spring_force = p_v; apply_spring_force_range(); }
double Box3DDistanceJoint::get_upper_spring_force() const { return upper_spring_force; }

void Box3DDistanceJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	if (joint_live()) {
		b3DistanceJoint_EnableMotor(joint_id, p_v);
		wake_bodies();
	}
}
bool Box3DDistanceJoint::get_motor_enabled() const { return motor_enabled; }
void Box3DDistanceJoint::set_motor_speed(double p_v) {
	bool changed = p_v != motor_speed;
	motor_speed = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DDistanceJoint::get_motor_speed() const { return motor_speed; }
void Box3DDistanceJoint::set_max_motor_force(double p_v) {
	max_motor_force = p_v;
	if (joint_live()) {
		b3DistanceJoint_SetMaxMotorForce(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DDistanceJoint::get_max_motor_force() const { return max_motor_force; }
double Box3DDistanceJoint::get_current_length() const {
	return joint_live() ? b3DistanceJoint_GetCurrentLength(joint_id) : 0.0;
}
double Box3DDistanceJoint::get_current_motor_force() const {
	return joint_live() ? b3DistanceJoint_GetMotorForce(joint_id) : 0.0;
}

void Box3DDistanceJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["length"] = b3DistanceJoint_GetLength(joint_id);
	r_d["spring_enabled"] = b3DistanceJoint_IsSpringEnabled(joint_id);
	r_d["spring_hertz"] = b3DistanceJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3DistanceJoint_GetSpringDampingRatio(joint_id);
	float lower = 0.0f;
	float upper = 0.0f;
	b3DistanceJoint_GetSpringForceRange(joint_id, &lower, &upper);
	r_d["lower_spring_force"] = lower;
	r_d["upper_spring_force"] = upper;
	r_d["limit_enabled"] = b3DistanceJoint_IsLimitEnabled(joint_id);
	r_d["min_length"] = b3DistanceJoint_GetMinLength(joint_id);
	r_d["max_length"] = b3DistanceJoint_GetMaxLength(joint_id);
	r_d["motor_enabled"] = b3DistanceJoint_IsMotorEnabled(joint_id);
	r_d["motor_speed"] = b3DistanceJoint_GetMotorSpeed(joint_id);
	r_d["max_motor_force"] = b3DistanceJoint_GetMaxMotorForce(joint_id);
}

void Box3DDistanceJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_length", "length"), &Box3DDistanceJoint::set_length);
	ClassDB::bind_method(D_METHOD("get_length"), &Box3DDistanceJoint::get_length);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DDistanceJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DDistanceJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DDistanceJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DDistanceJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DDistanceJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DDistanceJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_limit_enabled", "enabled"), &Box3DDistanceJoint::set_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_limit_enabled"), &Box3DDistanceJoint::get_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_min_length", "length"), &Box3DDistanceJoint::set_min_length);
	ClassDB::bind_method(D_METHOD("get_min_length"), &Box3DDistanceJoint::get_min_length);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &Box3DDistanceJoint::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &Box3DDistanceJoint::get_max_length);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("set_lower_spring_force", "force"), &Box3DDistanceJoint::set_lower_spring_force);
	ClassDB::bind_method(D_METHOD("get_lower_spring_force"), &Box3DDistanceJoint::get_lower_spring_force);
	ClassDB::bind_method(D_METHOD("set_upper_spring_force", "force"), &Box3DDistanceJoint::set_upper_spring_force);
	ClassDB::bind_method(D_METHOD("get_upper_spring_force"), &Box3DDistanceJoint::get_upper_spring_force);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DDistanceJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DDistanceJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_speed", "meters_per_sec"), &Box3DDistanceJoint::set_motor_speed);
	ClassDB::bind_method(D_METHOD("get_motor_speed"), &Box3DDistanceJoint::get_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_motor_force", "force"), &Box3DDistanceJoint::set_max_motor_force);
	ClassDB::bind_method(D_METHOD("get_max_motor_force"), &Box3DDistanceJoint::get_max_motor_force);
	ClassDB::bind_method(D_METHOD("get_current_length"), &Box3DDistanceJoint::get_current_length);
	ClassDB::bind_method(D_METHOD("get_current_motor_force"), &Box3DDistanceJoint::get_current_motor_force);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "length", PROPERTY_HINT_RANGE, "-1,100,0.01,or_greater"), "set_length", "get_length");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "limit_enabled"), "set_limit_enabled", "get_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_length", PROPERTY_HINT_RANGE, "0,100,0.01,or_greater"), "set_min_length", "get_min_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_length", PROPERTY_HINT_RANGE, "0,100,0.01,or_greater"), "set_max_length", "get_max_length");
	// Spring force range: lower (<= 0) caps tension, upper caps compression;
	// +/-INF (the defaults) = unbounded.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_spring_force", PROPERTY_HINT_RANGE, "-10000,0,1,or_less"), "set_lower_spring_force", "get_lower_spring_force");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_spring_force", PROPERTY_HINT_RANGE, "0,10000,1,or_greater"), "set_upper_spring_force", "get_upper_spring_force");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "motor_speed", PROPERTY_HINT_RANGE, "-20,20,0.1,or_less,or_greater"), "set_motor_speed", "get_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_force", PROPERTY_HINT_RANGE, "0,10000,1,or_greater"), "set_max_motor_force", "get_max_motor_force");
}

// ---------------------------------------------------------------------------
// Box3DBallJoint (spherical)
// ---------------------------------------------------------------------------

b3JointId Box3DBallJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3SphericalJointDef def = b3DefaultSphericalJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.enableConeLimit = cone_limit_enabled;
	def.coneAngle = (float)cone_angle;
	def.enableTwistLimit = twist_limit_enabled;
	def.lowerTwistAngle = (float)twist_lower;
	def.upperTwistAngle = (float)twist_upper;
	// Angular spring toward the spawn pose (frames coincide at creation).
	def.enableSpring = spring_enabled;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	// A zero-velocity motor with a torque cap acts as dry friction, the same
	// trick box3d's own human prefab uses to keep ragdoll limbs from flailing.
	// Extended core access III: an explicit velocity motor overrides that.
	if (motor_enabled) {
		def.enableMotor = true;
		def.maxMotorTorque = (float)MAX(max_motor_torque, 0.0);
		def.motorVelocity = to_b3(motor_velocity);
	} else if (friction_torque > 0.0) {
		def.enableMotor = true;
		def.maxMotorTorque = (float)friction_torque;
	}
	def.targetRotation = to_b3(target_rotation.normalized());
	return b3CreateSphericalJoint(p_world, &def);
}

// Extended core access III: limit / spring / friction settings use the live
// b3 setters instead of rebuilding (which re-anchored at the current pose).
// b3's live cone setter only accepts [0, PI/2] (creation clamps the same way).
void Box3DBallJoint::set_cone_limit_enabled(bool p_v) {
	cone_limit_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableConeLimit(joint_id, p_v);
	}
}
bool Box3DBallJoint::get_cone_limit_enabled() const { return cone_limit_enabled; }
void Box3DBallJoint::set_cone_angle(double p_v) {
	cone_angle = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetConeLimit(joint_id, (float)CLAMP(p_v, 0.0, 0.5 * Math_PI));
	}
}
double Box3DBallJoint::get_cone_angle() const { return cone_angle; }
void Box3DBallJoint::set_twist_limit_enabled(bool p_v) {
	twist_limit_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableTwistLimit(joint_id, p_v);
	}
}
bool Box3DBallJoint::get_twist_limit_enabled() const { return twist_limit_enabled; }
void Box3DBallJoint::set_twist_lower(double p_v) {
	twist_lower = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTwistLimits(joint_id, (float)twist_lower, (float)twist_upper);
	}
}
double Box3DBallJoint::get_twist_lower() const { return twist_lower; }
void Box3DBallJoint::set_twist_upper(double p_v) {
	twist_upper = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTwistLimits(joint_id, (float)twist_lower, (float)twist_upper);
	}
}
double Box3DBallJoint::get_twist_upper() const { return twist_upper; }

void Box3DBallJoint::set_spring_enabled(bool p_v) {
	spring_enabled = p_v;
	if (joint_live()) {
		b3SphericalJoint_EnableSpring(joint_id, p_v);
		wake_bodies();
	}
}
bool Box3DBallJoint::get_spring_enabled() const { return spring_enabled; }
void Box3DBallJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetSpringHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DBallJoint::get_spring_hertz() const { return spring_hertz; }
void Box3DBallJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetSpringDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DBallJoint::get_spring_damping() const { return spring_damping; }
void Box3DBallJoint::set_friction_torque(double p_v) { friction_torque = p_v; apply_motor(); }
double Box3DBallJoint::get_friction_torque() const { return friction_torque; }

// --- Extended core access III ---
void Box3DBallJoint::apply_motor() {
	if (!joint_live()) {
		return;
	}
	if (motor_enabled) {
		b3SphericalJoint_SetMaxMotorTorque(joint_id, (float)MAX(max_motor_torque, 0.0));
		b3SphericalJoint_SetMotorVelocity(joint_id, to_b3(motor_velocity));
		b3SphericalJoint_EnableMotor(joint_id, true);
	} else {
		b3SphericalJoint_SetMaxMotorTorque(joint_id, (float)MAX(friction_torque, 0.0));
		b3SphericalJoint_SetMotorVelocity(joint_id, b3Vec3_zero);
		b3SphericalJoint_EnableMotor(joint_id, friction_torque > 0.0);
	}
}

void Box3DBallJoint::set_target_rotation(const Quaternion &p_v) {
	bool changed = p_v != target_rotation;
	target_rotation = p_v;
	if (joint_live()) {
		b3SphericalJoint_SetTargetRotation(joint_id, to_b3(p_v.normalized()));
		if (changed) {
			wake_bodies();
		}
	}
}
Quaternion Box3DBallJoint::get_target_rotation() const { return target_rotation; }
void Box3DBallJoint::set_motor_enabled(bool p_v) {
	motor_enabled = p_v;
	apply_motor();
	wake_bodies();
}
bool Box3DBallJoint::get_motor_enabled() const { return motor_enabled; }
void Box3DBallJoint::set_motor_velocity(const Vector3 &p_v) {
	bool changed = p_v != motor_velocity;
	motor_velocity = p_v;
	if (motor_enabled && joint_live()) {
		b3SphericalJoint_SetMotorVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
}
Vector3 Box3DBallJoint::get_motor_velocity() const { return motor_velocity; }
void Box3DBallJoint::set_max_motor_torque(double p_v) {
	max_motor_torque = p_v;
	if (motor_enabled && joint_live()) {
		b3SphericalJoint_SetMaxMotorTorque(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DBallJoint::get_max_motor_torque() const { return max_motor_torque; }
double Box3DBallJoint::get_current_twist_angle() const {
	return joint_live() ? b3SphericalJoint_GetTwistAngle(joint_id) : 0.0;
}
double Box3DBallJoint::get_current_cone_angle() const {
	return joint_live() ? b3SphericalJoint_GetConeAngle(joint_id) : 0.0;
}
Vector3 Box3DBallJoint::get_current_motor_torque() const {
	return joint_live() ? to_gd(b3SphericalJoint_GetMotorTorque(joint_id)) : Vector3();
}

void Box3DBallJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["cone_limit_enabled"] = b3SphericalJoint_IsConeLimitEnabled(joint_id);
	r_d["cone_angle"] = b3SphericalJoint_GetConeLimit(joint_id);
	r_d["twist_limit_enabled"] = b3SphericalJoint_IsTwistLimitEnabled(joint_id);
	r_d["twist_lower"] = b3SphericalJoint_GetLowerTwistLimit(joint_id);
	r_d["twist_upper"] = b3SphericalJoint_GetUpperTwistLimit(joint_id);
	r_d["spring_enabled"] = b3SphericalJoint_IsSpringEnabled(joint_id);
	r_d["spring_hertz"] = b3SphericalJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3SphericalJoint_GetSpringDampingRatio(joint_id);
	r_d["target_rotation"] = to_gd(b3SphericalJoint_GetTargetRotation(joint_id));
	// The engine-side motor state (friction_torque is a zero-velocity motor).
	r_d["motor_enabled"] = b3SphericalJoint_IsMotorEnabled(joint_id);
	r_d["motor_velocity"] = to_gd(b3SphericalJoint_GetMotorVelocity(joint_id));
	r_d["max_motor_torque"] = b3SphericalJoint_GetMaxMotorTorque(joint_id);
}

void Box3DBallJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_cone_limit_enabled", "enabled"), &Box3DBallJoint::set_cone_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_cone_limit_enabled"), &Box3DBallJoint::get_cone_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_cone_angle", "radians"), &Box3DBallJoint::set_cone_angle);
	ClassDB::bind_method(D_METHOD("get_cone_angle"), &Box3DBallJoint::get_cone_angle);
	ClassDB::bind_method(D_METHOD("set_twist_limit_enabled", "enabled"), &Box3DBallJoint::set_twist_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_twist_limit_enabled"), &Box3DBallJoint::get_twist_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_twist_lower", "radians"), &Box3DBallJoint::set_twist_lower);
	ClassDB::bind_method(D_METHOD("get_twist_lower"), &Box3DBallJoint::get_twist_lower);
	ClassDB::bind_method(D_METHOD("set_twist_upper", "radians"), &Box3DBallJoint::set_twist_upper);
	ClassDB::bind_method(D_METHOD("get_twist_upper"), &Box3DBallJoint::get_twist_upper);
	ClassDB::bind_method(D_METHOD("set_spring_enabled", "enabled"), &Box3DBallJoint::set_spring_enabled);
	ClassDB::bind_method(D_METHOD("get_spring_enabled"), &Box3DBallJoint::get_spring_enabled);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DBallJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DBallJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DBallJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DBallJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_friction_torque", "torque"), &Box3DBallJoint::set_friction_torque);
	ClassDB::bind_method(D_METHOD("get_friction_torque"), &Box3DBallJoint::get_friction_torque);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("set_target_rotation", "rotation"), &Box3DBallJoint::set_target_rotation);
	ClassDB::bind_method(D_METHOD("get_target_rotation"), &Box3DBallJoint::get_target_rotation);
	ClassDB::bind_method(D_METHOD("set_motor_enabled", "enabled"), &Box3DBallJoint::set_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_motor_enabled"), &Box3DBallJoint::get_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_motor_velocity", "radians_per_sec"), &Box3DBallJoint::set_motor_velocity);
	ClassDB::bind_method(D_METHOD("get_motor_velocity"), &Box3DBallJoint::get_motor_velocity);
	ClassDB::bind_method(D_METHOD("set_max_motor_torque", "torque"), &Box3DBallJoint::set_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_max_motor_torque"), &Box3DBallJoint::get_max_motor_torque);
	ClassDB::bind_method(D_METHOD("get_current_twist_angle"), &Box3DBallJoint::get_current_twist_angle);
	ClassDB::bind_method(D_METHOD("get_current_cone_angle"), &Box3DBallJoint::get_current_cone_angle);
	ClassDB::bind_method(D_METHOD("get_current_motor_torque"), &Box3DBallJoint::get_current_motor_torque);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "cone_limit_enabled"), "set_cone_limit_enabled", "get_cone_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cone_angle", PROPERTY_HINT_RANGE, "0,180,0.1,radians_as_degrees"), "set_cone_angle", "get_cone_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "twist_limit_enabled"), "set_twist_limit_enabled", "get_twist_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "twist_lower", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_twist_lower", "get_twist_lower");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "twist_upper", PROPERTY_HINT_RANGE, "-180,180,0.1,radians_as_degrees"), "set_twist_upper", "get_twist_upper");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spring_enabled"), "set_spring_enabled", "get_spring_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,30,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,4,0.05,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction_torque", PROPERTY_HINT_RANGE, "0,100,0.1,or_greater"), "set_friction_torque", "get_friction_torque");
	ADD_PROPERTY(PropertyInfo(Variant::QUATERNION, "target_rotation"), "set_target_rotation", "get_target_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "motor_enabled"), "set_motor_enabled", "get_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "motor_velocity"), "set_motor_velocity", "get_motor_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_motor_torque", PROPERTY_HINT_RANGE, "0,10000,0.1,or_greater"), "set_max_motor_torque", "get_max_motor_torque");
}

// ---------------------------------------------------------------------------
// Box3DFixedJoint (weld)
// ---------------------------------------------------------------------------

b3JointId Box3DFixedJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3WeldJointDef def = b3DefaultWeldJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.linearHertz = (float)linear_hertz;
	def.angularHertz = (float)angular_hertz;
	def.linearDampingRatio = (float)linear_damping; // Extended core access III
	def.angularDampingRatio = (float)angular_damping;
	return b3CreateWeldJoint(p_world, &def);
}

// Extended core access III: live b3 setters instead of rebuilding.
void Box3DFixedJoint::set_linear_hertz(double p_v) {
	linear_hertz = p_v;
	if (joint_live()) {
		b3WeldJoint_SetLinearHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DFixedJoint::get_linear_hertz() const { return linear_hertz; }
void Box3DFixedJoint::set_angular_hertz(double p_v) {
	angular_hertz = p_v;
	if (joint_live()) {
		b3WeldJoint_SetAngularHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DFixedJoint::get_angular_hertz() const { return angular_hertz; }

// --- Extended core access III ---
void Box3DFixedJoint::set_linear_damping(double p_v) {
	linear_damping = p_v;
	if (joint_live()) {
		b3WeldJoint_SetLinearDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DFixedJoint::get_linear_damping() const { return linear_damping; }
void Box3DFixedJoint::set_angular_damping(double p_v) {
	angular_damping = p_v;
	if (joint_live()) {
		b3WeldJoint_SetAngularDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DFixedJoint::get_angular_damping() const { return angular_damping; }

void Box3DFixedJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["linear_hertz"] = b3WeldJoint_GetLinearHertz(joint_id);
	r_d["angular_hertz"] = b3WeldJoint_GetAngularHertz(joint_id);
	r_d["linear_damping"] = b3WeldJoint_GetLinearDampingRatio(joint_id);
	r_d["angular_damping"] = b3WeldJoint_GetAngularDampingRatio(joint_id);
}

void Box3DFixedJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_linear_hertz", "hertz"), &Box3DFixedJoint::set_linear_hertz);
	ClassDB::bind_method(D_METHOD("get_linear_hertz"), &Box3DFixedJoint::get_linear_hertz);
	ClassDB::bind_method(D_METHOD("set_angular_hertz", "hertz"), &Box3DFixedJoint::set_angular_hertz);
	ClassDB::bind_method(D_METHOD("get_angular_hertz"), &Box3DFixedJoint::get_angular_hertz);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("set_linear_damping", "ratio"), &Box3DFixedJoint::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DFixedJoint::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "ratio"), &Box3DFixedJoint::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DFixedJoint::get_angular_damping);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_hertz", PROPERTY_HINT_RANGE, "0,120,0.5,or_greater"), "set_linear_hertz", "get_linear_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_hertz", PROPERTY_HINT_RANGE, "0,120,0.5,or_greater"), "set_angular_hertz", "get_angular_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
}

// ---------------------------------------------------------------------------
// Box3DWheelJoint
// ---------------------------------------------------------------------------

b3JointId Box3DWheelJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3WheelJointDef def = b3DefaultWheelJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	// box3d's wheel joint suspends/steers along frame A's local X and spins the
	// wheel about frame B's local Z. This node exposes Y as the suspension axis
	// and Z as the axle, so frame A gets the node basis with (X,Y) rotated to
	// put b3's X on the node's Y; frame B takes the node basis directly (its Z
	// is already the axle). Same relative frames as upstream's Driving sample.
	Transform3D frame_a = p_joint;
	frame_a.basis = p_joint.basis * Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1));
	def.base.localFrameA = local_frame(p_xf_a, frame_a);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.enableSuspensionSpring = suspension_enabled;
	def.suspensionHertz = (float)suspension_hertz;
	def.suspensionDampingRatio = (float)suspension_damping;
	def.enableSuspensionLimit = suspension_limit_enabled;
	def.lowerSuspensionLimit = (float)lower_suspension_limit;
	def.upperSuspensionLimit = (float)upper_suspension_limit;
	def.enableSpinMotor = spin_motor_enabled;
	def.spinSpeed = (float)spin_motor_speed;
	def.maxSpinTorque = (float)max_spin_torque;
	def.enableSteering = steering_enabled;
	def.steeringHertz = (float)steering_hertz;
	def.steeringDampingRatio = (float)steering_damping;
	def.targetSteeringAngle = (float)target_steering_angle;
	def.maxSteeringTorque = (float)max_steering_torque;
	def.enableSteeringLimit = steering_limit_enabled;
	def.lowerSteeringLimit = (float)lower_steering_limit;
	def.upperSteeringLimit = (float)upper_steering_limit;
	return b3CreateWheelJoint(p_world, &def);
}

void Box3DWheelJoint::set_suspension_enabled(bool p_v) {
	suspension_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSuspension(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_suspension_enabled() const { return suspension_enabled; }

void Box3DWheelJoint::set_suspension_hertz(double p_v) {
	suspension_hertz = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionHertz(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_suspension_hertz() const { return suspension_hertz; }

void Box3DWheelJoint::set_suspension_damping(double p_v) {
	suspension_damping = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_suspension_damping() const { return suspension_damping; }

void Box3DWheelJoint::set_suspension_limit_enabled(bool p_v) {
	suspension_limit_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSuspensionLimit(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_suspension_limit_enabled() const { return suspension_limit_enabled; }

void Box3DWheelJoint::set_lower_suspension_limit(double p_v) {
	lower_suspension_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionLimits(joint_id, (float)lower_suspension_limit, (float)upper_suspension_limit);
	}
}
double Box3DWheelJoint::get_lower_suspension_limit() const { return lower_suspension_limit; }

void Box3DWheelJoint::set_upper_suspension_limit(double p_v) {
	upper_suspension_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSuspensionLimits(joint_id, (float)lower_suspension_limit, (float)upper_suspension_limit);
	}
}
double Box3DWheelJoint::get_upper_suspension_limit() const { return upper_suspension_limit; }

void Box3DWheelJoint::set_spin_motor_enabled(bool p_v) {
	spin_motor_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSpinMotor(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_spin_motor_enabled() const {
	return joint_live() ? b3WheelJoint_IsSpinMotorEnabled(joint_id) : spin_motor_enabled;
}

void Box3DWheelJoint::set_spin_motor_speed(double p_v) {
	bool changed = p_v != spin_motor_speed;
	spin_motor_speed = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSpinMotorSpeed(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DWheelJoint::get_spin_motor_speed() const {
	return joint_live() ? b3WheelJoint_GetSpinMotorSpeed(joint_id) : spin_motor_speed;
}

void Box3DWheelJoint::set_max_spin_torque(double p_v) {
	max_spin_torque = p_v;
	if (joint_live()) {
		b3WheelJoint_SetMaxSpinTorque(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_max_spin_torque() const {
	return joint_live() ? b3WheelJoint_GetMaxSpinTorque(joint_id) : max_spin_torque;
}

void Box3DWheelJoint::set_steering_enabled(bool p_v) {
	steering_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSteering(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_steering_enabled() const { return steering_enabled; }

void Box3DWheelJoint::set_steering_hertz(double p_v) {
	steering_hertz = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringHertz(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_steering_hertz() const { return steering_hertz; }

void Box3DWheelJoint::set_steering_damping(double p_v) {
	steering_damping = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_steering_damping() const { return steering_damping; }

void Box3DWheelJoint::set_target_steering_angle(double p_v) {
	bool changed = p_v != target_steering_angle;
	target_steering_angle = p_v;
	if (joint_live()) {
		b3WheelJoint_SetTargetSteeringAngle(joint_id, (float)p_v);
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DWheelJoint::get_target_steering_angle() const { return target_steering_angle; }

void Box3DWheelJoint::set_max_steering_torque(double p_v) {
	max_steering_torque = p_v;
	if (joint_live()) {
		b3WheelJoint_SetMaxSteeringTorque(joint_id, (float)p_v);
	}
}
double Box3DWheelJoint::get_max_steering_torque() const { return max_steering_torque; }

void Box3DWheelJoint::set_steering_limit_enabled(bool p_v) {
	steering_limit_enabled = p_v;
	if (joint_live()) {
		b3WheelJoint_EnableSteeringLimit(joint_id, p_v);
	}
}
bool Box3DWheelJoint::get_steering_limit_enabled() const { return steering_limit_enabled; }

void Box3DWheelJoint::set_lower_steering_limit(double p_v) {
	lower_steering_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringLimits(joint_id, (float)lower_steering_limit, (float)upper_steering_limit);
	}
}
double Box3DWheelJoint::get_lower_steering_limit() const { return lower_steering_limit; }

void Box3DWheelJoint::set_upper_steering_limit(double p_v) {
	upper_steering_limit = p_v;
	if (joint_live()) {
		b3WheelJoint_SetSteeringLimits(joint_id, (float)lower_steering_limit, (float)upper_steering_limit);
	}
}
double Box3DWheelJoint::get_upper_steering_limit() const { return upper_steering_limit; }

double Box3DWheelJoint::get_spin_speed() const {
	return joint_live() ? b3WheelJoint_GetSpinSpeed(joint_id) : 0.0;
}

double Box3DWheelJoint::get_steering_angle() const {
	return joint_live() ? b3WheelJoint_GetSteeringAngle(joint_id) : 0.0;
}

// --- Extended core access III ---
double Box3DWheelJoint::get_current_spin_torque() const {
	return joint_live() ? b3WheelJoint_GetSpinTorque(joint_id) : 0.0;
}
double Box3DWheelJoint::get_current_steering_torque() const {
	return joint_live() ? b3WheelJoint_GetSteeringTorque(joint_id) : 0.0;
}

void Box3DWheelJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["suspension_enabled"] = b3WheelJoint_IsSuspensionEnabled(joint_id);
	r_d["suspension_hertz"] = b3WheelJoint_GetSuspensionHertz(joint_id);
	r_d["suspension_damping"] = b3WheelJoint_GetSuspensionDampingRatio(joint_id);
	r_d["suspension_limit_enabled"] = b3WheelJoint_IsSuspensionLimitEnabled(joint_id);
	r_d["lower_suspension_limit"] = b3WheelJoint_GetLowerSuspensionLimit(joint_id);
	r_d["upper_suspension_limit"] = b3WheelJoint_GetUpperSuspensionLimit(joint_id);
	r_d["spin_motor_enabled"] = b3WheelJoint_IsSpinMotorEnabled(joint_id);
	r_d["spin_motor_speed"] = b3WheelJoint_GetSpinMotorSpeed(joint_id);
	r_d["max_spin_torque"] = b3WheelJoint_GetMaxSpinTorque(joint_id);
	r_d["steering_enabled"] = b3WheelJoint_IsSteeringEnabled(joint_id);
	r_d["steering_hertz"] = b3WheelJoint_GetSteeringHertz(joint_id);
	r_d["steering_damping"] = b3WheelJoint_GetSteeringDampingRatio(joint_id);
	r_d["target_steering_angle"] = b3WheelJoint_GetTargetSteeringAngle(joint_id);
	r_d["max_steering_torque"] = b3WheelJoint_GetMaxSteeringTorque(joint_id);
	r_d["steering_limit_enabled"] = b3WheelJoint_IsSteeringLimitEnabled(joint_id);
	r_d["lower_steering_limit"] = b3WheelJoint_GetLowerSteeringLimit(joint_id);
	r_d["upper_steering_limit"] = b3WheelJoint_GetUpperSteeringLimit(joint_id);
}

void Box3DWheelJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_suspension_enabled", "enabled"), &Box3DWheelJoint::set_suspension_enabled);
	ClassDB::bind_method(D_METHOD("get_suspension_enabled"), &Box3DWheelJoint::get_suspension_enabled);
	ClassDB::bind_method(D_METHOD("set_suspension_hertz", "hertz"), &Box3DWheelJoint::set_suspension_hertz);
	ClassDB::bind_method(D_METHOD("get_suspension_hertz"), &Box3DWheelJoint::get_suspension_hertz);
	ClassDB::bind_method(D_METHOD("set_suspension_damping", "ratio"), &Box3DWheelJoint::set_suspension_damping);
	ClassDB::bind_method(D_METHOD("get_suspension_damping"), &Box3DWheelJoint::get_suspension_damping);
	ClassDB::bind_method(D_METHOD("set_suspension_limit_enabled", "enabled"), &Box3DWheelJoint::set_suspension_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_suspension_limit_enabled"), &Box3DWheelJoint::get_suspension_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_suspension_limit", "meters"), &Box3DWheelJoint::set_lower_suspension_limit);
	ClassDB::bind_method(D_METHOD("get_lower_suspension_limit"), &Box3DWheelJoint::get_lower_suspension_limit);
	ClassDB::bind_method(D_METHOD("set_upper_suspension_limit", "meters"), &Box3DWheelJoint::set_upper_suspension_limit);
	ClassDB::bind_method(D_METHOD("get_upper_suspension_limit"), &Box3DWheelJoint::get_upper_suspension_limit);
	ClassDB::bind_method(D_METHOD("set_spin_motor_enabled", "enabled"), &Box3DWheelJoint::set_spin_motor_enabled);
	ClassDB::bind_method(D_METHOD("get_spin_motor_enabled"), &Box3DWheelJoint::get_spin_motor_enabled);
	ClassDB::bind_method(D_METHOD("set_spin_motor_speed", "radians_per_sec"), &Box3DWheelJoint::set_spin_motor_speed);
	ClassDB::bind_method(D_METHOD("get_spin_motor_speed"), &Box3DWheelJoint::get_spin_motor_speed);
	ClassDB::bind_method(D_METHOD("set_max_spin_torque", "torque"), &Box3DWheelJoint::set_max_spin_torque);
	ClassDB::bind_method(D_METHOD("get_max_spin_torque"), &Box3DWheelJoint::get_max_spin_torque);
	ClassDB::bind_method(D_METHOD("set_steering_enabled", "enabled"), &Box3DWheelJoint::set_steering_enabled);
	ClassDB::bind_method(D_METHOD("get_steering_enabled"), &Box3DWheelJoint::get_steering_enabled);
	ClassDB::bind_method(D_METHOD("set_steering_hertz", "hertz"), &Box3DWheelJoint::set_steering_hertz);
	ClassDB::bind_method(D_METHOD("get_steering_hertz"), &Box3DWheelJoint::get_steering_hertz);
	ClassDB::bind_method(D_METHOD("set_steering_damping", "ratio"), &Box3DWheelJoint::set_steering_damping);
	ClassDB::bind_method(D_METHOD("get_steering_damping"), &Box3DWheelJoint::get_steering_damping);
	ClassDB::bind_method(D_METHOD("set_target_steering_angle", "radians"), &Box3DWheelJoint::set_target_steering_angle);
	ClassDB::bind_method(D_METHOD("get_target_steering_angle"), &Box3DWheelJoint::get_target_steering_angle);
	ClassDB::bind_method(D_METHOD("set_max_steering_torque", "torque"), &Box3DWheelJoint::set_max_steering_torque);
	ClassDB::bind_method(D_METHOD("get_max_steering_torque"), &Box3DWheelJoint::get_max_steering_torque);
	ClassDB::bind_method(D_METHOD("set_steering_limit_enabled", "enabled"), &Box3DWheelJoint::set_steering_limit_enabled);
	ClassDB::bind_method(D_METHOD("get_steering_limit_enabled"), &Box3DWheelJoint::get_steering_limit_enabled);
	ClassDB::bind_method(D_METHOD("set_lower_steering_limit", "radians"), &Box3DWheelJoint::set_lower_steering_limit);
	ClassDB::bind_method(D_METHOD("get_lower_steering_limit"), &Box3DWheelJoint::get_lower_steering_limit);
	ClassDB::bind_method(D_METHOD("set_upper_steering_limit", "radians"), &Box3DWheelJoint::set_upper_steering_limit);
	ClassDB::bind_method(D_METHOD("get_upper_steering_limit"), &Box3DWheelJoint::get_upper_steering_limit);
	ClassDB::bind_method(D_METHOD("get_spin_speed"), &Box3DWheelJoint::get_spin_speed);
	ClassDB::bind_method(D_METHOD("get_steering_angle"), &Box3DWheelJoint::get_steering_angle);
	// --- Extended core access III ---
	ClassDB::bind_method(D_METHOD("get_current_spin_torque"), &Box3DWheelJoint::get_current_spin_torque);
	ClassDB::bind_method(D_METHOD("get_current_steering_torque"), &Box3DWheelJoint::get_current_steering_torque);

	ADD_GROUP("Suspension", "suspension_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "suspension_enabled"), "set_suspension_enabled", "get_suspension_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "suspension_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_suspension_hertz", "get_suspension_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "suspension_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_suspension_damping", "get_suspension_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "suspension_limit_enabled"), "set_suspension_limit_enabled", "get_suspension_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_suspension_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater"), "set_lower_suspension_limit", "get_lower_suspension_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_suspension_limit", PROPERTY_HINT_RANGE, "-10,10,0.01,or_greater"), "set_upper_suspension_limit", "get_upper_suspension_limit");
	ADD_GROUP("Spin Motor", "spin_motor_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "spin_motor_enabled"), "set_spin_motor_enabled", "get_spin_motor_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spin_motor_speed", PROPERTY_HINT_RANGE, "-100,100,0.1"), "set_spin_motor_speed", "get_spin_motor_speed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spin_torque", PROPERTY_HINT_RANGE, "0,10000,0.1,or_greater"), "set_max_spin_torque", "get_max_spin_torque");
	ADD_GROUP("Steering", "steering_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "steering_enabled"), "set_steering_enabled", "get_steering_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steering_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_steering_hertz", "get_steering_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steering_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_steering_damping", "get_steering_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_steering_angle", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_target_steering_angle", "get_target_steering_angle");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_steering_torque", PROPERTY_HINT_RANGE, "0,10000,0.1,or_greater"), "set_max_steering_torque", "get_max_steering_torque");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "steering_limit_enabled"), "set_steering_limit_enabled", "get_steering_limit_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lower_steering_limit", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_lower_steering_limit", "get_lower_steering_limit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upper_steering_limit", PROPERTY_HINT_RANGE, "-90,90,0.1,radians_as_degrees"), "set_upper_steering_limit", "get_upper_steering_limit");
}

// ---------------------------------------------------------------------------
// Box3DParallelJoint
// ---------------------------------------------------------------------------

b3JointId Box3DParallelJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3ParallelJointDef def = b3DefaultParallelJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.hertz = (float)spring_hertz;
	def.dampingRatio = (float)spring_damping;
	if (max_torque > 0.0) {
		def.maxTorque = (float)max_torque;
	}
	return b3CreateParallelJoint(p_world, &def);
}

void Box3DParallelJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3ParallelJoint_SetSpringHertz(joint_id, (float)p_v);
	}
}
double Box3DParallelJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DParallelJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3ParallelJoint_SetSpringDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DParallelJoint::get_spring_damping() const { return spring_damping; }

void Box3DParallelJoint::set_max_torque(double p_v) {
	max_torque = p_v;
	if (joint_live() && p_v > 0.0) {
		b3ParallelJoint_SetMaxTorque(joint_id, (float)p_v);
	} else {
		rebuild_if_alive(); // back to 0 = unlimited needs the def default
	}
}
double Box3DParallelJoint::get_max_torque() const { return max_torque; }

// --- Extended core access III ---
void Box3DParallelJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["spring_hertz"] = b3ParallelJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3ParallelJoint_GetSpringDampingRatio(joint_id);
	r_d["max_torque"] = b3ParallelJoint_GetMaxTorque(joint_id);
}

void Box3DParallelJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DParallelJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DParallelJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DParallelJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DParallelJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_max_torque", "torque"), &Box3DParallelJoint::set_max_torque);
	ClassDB::bind_method(D_METHOD("get_max_torque"), &Box3DParallelJoint::get_max_torque);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_torque", PROPERTY_HINT_RANGE, "0,10000,0.1,or_greater"), "set_max_torque", "get_max_torque");
}

// ---------------------------------------------------------------------------
// Box3DMotorJoint
// ---------------------------------------------------------------------------

b3JointId Box3DMotorJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3MotorJointDef def = b3DefaultMotorJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = collide_connected;
	def.linearVelocity = to_b3(linear_velocity);
	def.maxVelocityForce = (float)max_force;
	def.angularVelocity = to_b3(angular_velocity);
	def.maxVelocityTorque = (float)max_torque;
	def.linearHertz = (float)linear_hertz;
	def.linearDampingRatio = (float)linear_damping;
	def.maxSpringForce = (float)max_spring_force;
	def.angularHertz = (float)angular_hertz;
	def.angularDampingRatio = (float)angular_damping;
	def.maxSpringTorque = (float)max_spring_torque;
	return b3CreateMotorJoint(p_world, &def);
}

void Box3DMotorJoint::set_linear_velocity(const Vector3 &p_v) {
	bool changed = p_v != linear_velocity;
	linear_velocity = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
}
Vector3 Box3DMotorJoint::get_linear_velocity() const { return linear_velocity; }

void Box3DMotorJoint::set_max_force(double p_v) {
	max_force = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxVelocityForce(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_max_force() const { return max_force; }

void Box3DMotorJoint::set_angular_velocity(const Vector3 &p_v) {
	bool changed = p_v != angular_velocity;
	angular_velocity = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
}
Vector3 Box3DMotorJoint::get_angular_velocity() const { return angular_velocity; }

void Box3DMotorJoint::set_max_torque(double p_v) {
	max_torque = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxVelocityTorque(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_max_torque() const { return max_torque; }

void Box3DMotorJoint::set_linear_hertz(double p_v) {
	linear_hertz = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearHertz(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_linear_hertz() const { return linear_hertz; }

void Box3DMotorJoint::set_linear_damping(double p_v) {
	linear_damping = p_v;
	if (joint_live()) {
		b3MotorJoint_SetLinearDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_linear_damping() const { return linear_damping; }

void Box3DMotorJoint::set_max_spring_force(double p_v) {
	max_spring_force = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxSpringForce(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_max_spring_force() const { return max_spring_force; }

void Box3DMotorJoint::set_angular_hertz(double p_v) {
	angular_hertz = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularHertz(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_angular_hertz() const { return angular_hertz; }

void Box3DMotorJoint::set_angular_damping(double p_v) {
	angular_damping = p_v;
	if (joint_live()) {
		b3MotorJoint_SetAngularDampingRatio(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_angular_damping() const { return angular_damping; }

void Box3DMotorJoint::set_max_spring_torque(double p_v) {
	max_spring_torque = p_v;
	if (joint_live()) {
		b3MotorJoint_SetMaxSpringTorque(joint_id, (float)p_v);
	}
}
double Box3DMotorJoint::get_max_spring_torque() const { return max_spring_torque; }

// --- Extended core access III ---
void Box3DMotorJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["linear_velocity"] = to_gd(b3MotorJoint_GetLinearVelocity(joint_id));
	r_d["max_force"] = b3MotorJoint_GetMaxVelocityForce(joint_id);
	r_d["angular_velocity"] = to_gd(b3MotorJoint_GetAngularVelocity(joint_id));
	r_d["max_torque"] = b3MotorJoint_GetMaxVelocityTorque(joint_id);
	r_d["linear_hertz"] = b3MotorJoint_GetLinearHertz(joint_id);
	r_d["linear_damping"] = b3MotorJoint_GetLinearDampingRatio(joint_id);
	r_d["max_spring_force"] = b3MotorJoint_GetMaxSpringForce(joint_id);
	r_d["angular_hertz"] = b3MotorJoint_GetAngularHertz(joint_id);
	r_d["angular_damping"] = b3MotorJoint_GetAngularDampingRatio(joint_id);
	r_d["max_spring_torque"] = b3MotorJoint_GetMaxSpringTorque(joint_id);
}

void Box3DMotorJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DMotorJoint::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DMotorJoint::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_max_force", "force"), &Box3DMotorJoint::set_max_force);
	ClassDB::bind_method(D_METHOD("get_max_force"), &Box3DMotorJoint::get_max_force);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "velocity"), &Box3DMotorJoint::set_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_angular_velocity"), &Box3DMotorJoint::get_angular_velocity);
	ClassDB::bind_method(D_METHOD("set_max_torque", "torque"), &Box3DMotorJoint::set_max_torque);
	ClassDB::bind_method(D_METHOD("get_max_torque"), &Box3DMotorJoint::get_max_torque);

	ClassDB::bind_method(D_METHOD("set_linear_hertz", "hertz"), &Box3DMotorJoint::set_linear_hertz);
	ClassDB::bind_method(D_METHOD("get_linear_hertz"), &Box3DMotorJoint::get_linear_hertz);
	ClassDB::bind_method(D_METHOD("set_linear_damping", "ratio"), &Box3DMotorJoint::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DMotorJoint::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_max_spring_force", "force"), &Box3DMotorJoint::set_max_spring_force);
	ClassDB::bind_method(D_METHOD("get_max_spring_force"), &Box3DMotorJoint::get_max_spring_force);
	ClassDB::bind_method(D_METHOD("set_angular_hertz", "hertz"), &Box3DMotorJoint::set_angular_hertz);
	ClassDB::bind_method(D_METHOD("get_angular_hertz"), &Box3DMotorJoint::get_angular_hertz);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "ratio"), &Box3DMotorJoint::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DMotorJoint::get_angular_damping);
	ClassDB::bind_method(D_METHOD("set_max_spring_torque", "torque"), &Box3DMotorJoint::set_max_spring_torque);
	ClassDB::bind_method(D_METHOD("get_max_spring_torque"), &Box3DMotorJoint::get_max_spring_torque);

	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "linear_velocity"), "set_linear_velocity", "get_linear_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_force", "get_max_force");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "angular_velocity"), "set_angular_velocity", "get_angular_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_torque", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_torque", "get_max_torque");
	ADD_GROUP("Position Spring", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_linear_hertz", "get_linear_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spring_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_spring_force", "get_max_spring_force");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_angular_hertz", "get_angular_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_spring_torque", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_spring_torque", "get_max_spring_torque");
}

// ---------------------------------------------------------------------------
// --- Extended core access III: Box3DMoverJoint / Box3DPogoJoint / Box3DFilterJoint
// ---------------------------------------------------------------------------

// Box3DMoverJoint ------------------------------------------------------------

Box3DMoverJoint::Box3DMoverJoint() {
	// The character must keep colliding with the ground it moves on.
	collide_connected = true;
}

b3JointId Box3DMoverJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3MoverJointDef def = b3DefaultMoverJointDef();
	// b3 order: A = ground/base (this node's body_b or the world anchor),
	// B = driven character (this node's body_a). Force acts in frame B's XZ.
	def.base.bodyIdA = p_b;
	def.base.bodyIdB = p_a;
	def.base.localFrameA = local_frame(p_xf_b, p_joint);
	def.base.localFrameB = local_frame(p_xf_a, p_joint);
	def.base.collideConnected = collide_connected;
	def.linearVelocity = to_b3(linear_velocity);
	def.maxForce = (float)MAX(max_force, 0.0);
	return b3CreateMoverJoint(p_world, &def);
}

void Box3DMoverJoint::set_linear_velocity(const Vector3 &p_v) {
	bool changed = p_v != linear_velocity;
	linear_velocity = p_v;
	if (joint_live()) {
		b3MoverJoint_SetLinearVelocity(joint_id, to_b3(p_v));
		if (changed) {
			wake_bodies();
		}
	}
}
Vector3 Box3DMoverJoint::get_linear_velocity() const { return linear_velocity; }

void Box3DMoverJoint::set_max_force(double p_v) {
	max_force = p_v;
	if (joint_live()) {
		b3MoverJoint_SetMaxVelocityForce(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DMoverJoint::get_max_force() const { return max_force; }

void Box3DMoverJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["linear_velocity"] = to_gd(b3MoverJoint_GetLinearVelocity(joint_id));
	r_d["max_force"] = b3MoverJoint_GetMaxVelocityForce(joint_id);
}

void Box3DMoverJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DMoverJoint::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DMoverJoint::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_max_force", "force"), &Box3DMoverJoint::set_max_force);
	ClassDB::bind_method(D_METHOD("get_max_force"), &Box3DMoverJoint::get_max_force);

	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "linear_velocity"), "set_linear_velocity", "get_linear_velocity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_force", "get_max_force");
}

// Box3DPogoJoint -------------------------------------------------------------

Box3DPogoJoint::Box3DPogoJoint() {
	// The character must keep colliding with the ground it stands on.
	collide_connected = true;
}

// b3 asserts a unit normal; fall back to world up for a degenerate one.
b3Vec3 Box3DPogoJoint::safe_normal(const Vector3 &p_n) {
	if (p_n.length_squared() < 1e-12) {
		return b3Vec3_axisY;
	}
	return to_b3(p_n.normalized());
}

b3JointId Box3DPogoJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3PogoJointDef def = b3DefaultPogoJointDef();
	// b3 order: A = ground (this node's body_b or the world anchor), B = the
	// character (body_a). The pogo axis is frame B's Y = this node's Y.
	def.base.bodyIdA = p_b;
	def.base.bodyIdB = p_a;
	def.base.localFrameA = local_frame(p_xf_b, p_joint);
	def.base.localFrameB = local_frame(p_xf_a, p_joint);
	def.base.collideConnected = collide_connected;
	def.normal = safe_normal(normal);
	def.hertz = (float)MAX(spring_hertz, 0.0);
	def.dampingRatio = (float)MAX(spring_damping, 0.0);
	def.restLength = (float)MAX(rest_length, 0.0);
	def.maxTensionForce = (float)MAX(max_tension_force, 0.0);
	def.maxCompressionForce = (float)MAX(max_compression_force, 0.0);
	def.impulse = (float)initial_impulse;
	def.velocity = (float)initial_speed;
	return b3CreatePogoJoint(p_world, &def);
}

void Box3DPogoJoint::set_normal(const Vector3 &p_v) {
	normal = p_v;
	if (joint_live()) {
		b3PogoJoint_SetNormal(joint_id, safe_normal(p_v));
	}
}
Vector3 Box3DPogoJoint::get_normal() const { return normal; }

void Box3DPogoJoint::set_spring_hertz(double p_v) {
	spring_hertz = p_v;
	if (joint_live()) {
		b3PogoJoint_SetSpringHertz(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DPogoJoint::get_spring_hertz() const { return spring_hertz; }

void Box3DPogoJoint::set_spring_damping(double p_v) {
	spring_damping = p_v;
	if (joint_live()) {
		b3PogoJoint_SetSpringDampingRatio(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DPogoJoint::get_spring_damping() const { return spring_damping; }

void Box3DPogoJoint::set_rest_length(double p_v) {
	bool changed = p_v != rest_length;
	rest_length = p_v;
	if (joint_live()) {
		b3PogoJoint_SetRestLength(joint_id, (float)MAX(p_v, 0.0));
		if (changed) {
			wake_bodies();
		}
	}
}
double Box3DPogoJoint::get_rest_length() const { return rest_length; }

void Box3DPogoJoint::set_max_tension_force(double p_v) {
	max_tension_force = p_v;
	if (joint_live()) {
		b3PogoJoint_SetMaxTensionForce(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DPogoJoint::get_max_tension_force() const { return max_tension_force; }

void Box3DPogoJoint::set_max_compression_force(double p_v) {
	max_compression_force = p_v;
	if (joint_live()) {
		b3PogoJoint_SetMaxCompressionForce(joint_id, (float)MAX(p_v, 0.0));
	}
}
double Box3DPogoJoint::get_max_compression_force() const { return max_compression_force; }

// Creation-only warm start (b3PogoJointDef::impulse / ::velocity).
void Box3DPogoJoint::set_initial_impulse(double p_v) { initial_impulse = p_v; }
double Box3DPogoJoint::get_initial_impulse() const { return initial_impulse; }
void Box3DPogoJoint::set_initial_speed(double p_v) { initial_speed = p_v; }
double Box3DPogoJoint::get_initial_speed() const { return initial_speed; }

void Box3DPogoJoint::set_ground_point(const Vector3 &p_world_point) {
	if (!joint_live()) {
		return;
	}
	// b3 body A is the ground side for the pogo.
	b3BodyId ground = b3Joint_GetBodyA(joint_id);
	b3Transform frame = b3Joint_GetLocalFrameA(joint_id);
	frame.p = b3Body_GetLocalPoint(ground, to_b3_pos(p_world_point));
	b3Joint_SetLocalFrameA(joint_id, frame);
}

double Box3DPogoJoint::get_current_length() const {
	return joint_live() ? b3PogoJoint_GetCurrentLength(joint_id) : 0.0;
}
double Box3DPogoJoint::get_current_speed() const {
	return joint_live() ? b3PogoJoint_GetCurrentSpeed(joint_id) : 0.0;
}
double Box3DPogoJoint::get_current_impulse() const {
	return joint_live() ? b3PogoJoint_GetImpulse(joint_id) : 0.0;
}

void Box3DPogoJoint::fill_live_settings(Dictionary &r_d) const {
	r_d["normal"] = to_gd(b3PogoJoint_GetNormal(joint_id));
	r_d["spring_hertz"] = b3PogoJoint_GetSpringHertz(joint_id);
	r_d["spring_damping"] = b3PogoJoint_GetSpringDampingRatio(joint_id);
	r_d["rest_length"] = b3PogoJoint_GetRestLength(joint_id);
	r_d["max_tension_force"] = b3PogoJoint_GetMaxTensionForce(joint_id);
	r_d["max_compression_force"] = b3PogoJoint_GetMaxCompressionForce(joint_id);
}

void Box3DPogoJoint::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_normal", "normal"), &Box3DPogoJoint::set_normal);
	ClassDB::bind_method(D_METHOD("get_normal"), &Box3DPogoJoint::get_normal);
	ClassDB::bind_method(D_METHOD("set_spring_hertz", "hertz"), &Box3DPogoJoint::set_spring_hertz);
	ClassDB::bind_method(D_METHOD("get_spring_hertz"), &Box3DPogoJoint::get_spring_hertz);
	ClassDB::bind_method(D_METHOD("set_spring_damping", "ratio"), &Box3DPogoJoint::set_spring_damping);
	ClassDB::bind_method(D_METHOD("get_spring_damping"), &Box3DPogoJoint::get_spring_damping);
	ClassDB::bind_method(D_METHOD("set_rest_length", "length"), &Box3DPogoJoint::set_rest_length);
	ClassDB::bind_method(D_METHOD("get_rest_length"), &Box3DPogoJoint::get_rest_length);
	ClassDB::bind_method(D_METHOD("set_max_tension_force", "force"), &Box3DPogoJoint::set_max_tension_force);
	ClassDB::bind_method(D_METHOD("get_max_tension_force"), &Box3DPogoJoint::get_max_tension_force);
	ClassDB::bind_method(D_METHOD("set_max_compression_force", "force"), &Box3DPogoJoint::set_max_compression_force);
	ClassDB::bind_method(D_METHOD("get_max_compression_force"), &Box3DPogoJoint::get_max_compression_force);
	ClassDB::bind_method(D_METHOD("set_initial_impulse", "impulse"), &Box3DPogoJoint::set_initial_impulse);
	ClassDB::bind_method(D_METHOD("get_initial_impulse"), &Box3DPogoJoint::get_initial_impulse);
	ClassDB::bind_method(D_METHOD("set_initial_speed", "speed"), &Box3DPogoJoint::set_initial_speed);
	ClassDB::bind_method(D_METHOD("get_initial_speed"), &Box3DPogoJoint::get_initial_speed);
	ClassDB::bind_method(D_METHOD("set_ground_point", "world_point"), &Box3DPogoJoint::set_ground_point);
	ClassDB::bind_method(D_METHOD("get_current_length"), &Box3DPogoJoint::get_current_length);
	ClassDB::bind_method(D_METHOD("get_current_speed"), &Box3DPogoJoint::get_current_speed);
	ClassDB::bind_method(D_METHOD("get_current_impulse"), &Box3DPogoJoint::get_current_impulse);

	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "normal"), "set_normal", "get_normal");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_hertz", PROPERTY_HINT_RANGE, "0,60,0.1,or_greater"), "set_spring_hertz", "get_spring_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spring_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_spring_damping", "get_spring_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rest_length", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_rest_length", "get_rest_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_tension_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_tension_force", "get_max_tension_force");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_compression_force", PROPERTY_HINT_RANGE, "0,100000,1,or_greater"), "set_max_compression_force", "get_max_compression_force");
	ADD_GROUP("Warm Start", "initial_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "initial_impulse"), "set_initial_impulse", "get_initial_impulse");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "initial_speed"), "set_initial_speed", "get_initial_speed");
}

// Box3DFilterJoint -----------------------------------------------------------

b3JointId Box3DFilterJoint::create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
		const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
	b3FilterJointDef def = b3DefaultFilterJointDef();
	def.base.bodyIdA = p_a;
	def.base.bodyIdB = p_b;
	def.base.localFrameA = local_frame(p_xf_a, p_joint);
	def.base.localFrameB = local_frame(p_xf_b, p_joint);
	def.base.collideConnected = false; // the whole point of a filter joint
	return b3CreateFilterJoint(p_world, &def);
}

void Box3DFilterJoint::_bind_methods() {
}
