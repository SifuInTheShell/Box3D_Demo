// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>

#include <box3d/box3d.h>

#include <cmath>

namespace godot {

class Box3DWorld;
class Box3DBody;

// Base class for Box3D joints. A joint connects `body_a` to `body_b`; if
// `body_b` is left empty the joint anchors to the world at this node's
// position. The node's own transform defines the joint frame (anchor + axes).
class Box3DJoint : public Node3D {
	GDCLASS(Box3DJoint, Node3D)

protected:
	b3JointId joint_id = b3_nullJointId;
	b3BodyId anchor_id = b3_nullBodyId; // static body created when body_b is empty
	Box3DWorld *world = nullptr;

	NodePath body_a_path;
	NodePath body_b_path;
	bool collide_connected = false;

	Box3DWorld *find_world();
	// b3Joint_IsValid plus a join of any in-flight async world step.
	bool joint_live() const;
	Box3DBody *resolve_body(const NodePath &p_path);
	// The joint frame expressed in a body's local space.
	b3Transform local_frame(const Transform3D &p_body, const Transform3D &p_joint) const;
	void rebuild_if_alive();
	// Wake both connected bodies. box3d's motor-target setters only store the
	// value, so a sleeping body would ignore a new drive command; every setter
	// that changes a drive target calls this.
	void wake_bodies();

	// --- Extended core access III: hooks for live readback / body ordering ---
	// Subclasses append their engine-side settings (read back through the b3
	// getters, i.e. after the engine's own clamping) to get_live_settings().
	virtual void fill_live_settings(Dictionary &r_settings) const {}
	// True for joints whose b3 body order is (ground, driven body) while this
	// node's body_a is the driven body (mover / pogo). Frame/body accessors on
	// the base class honor it so "a" always means this node's body_a.
	virtual bool swaps_bodies() const { return false; }

	// Subclasses fill in their specific joint def and create it.
	virtual b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) {
		return b3_nullJointId;
	}

	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DJoint();
	~Box3DJoint();

	void create_joint();
	void destroy_joint();
	bool is_joint_valid() const;

	void set_body_a(const NodePath &p_path);
	NodePath get_body_a() const;
	void set_body_b(const NodePath &p_path);
	NodePath get_body_b() const;
	void set_collide_connected(bool p_enabled);
	bool get_collide_connected() const;

	// --- Extended core access: solver readouts on any joint type --------------
	// Force/torque the constraint applied last step (cable tension, load on a
	// hinge), and the positional drift the solver has not resolved.
	Vector3 get_constraint_force() const;
	Vector3 get_constraint_torque() const;
	double get_linear_separation() const;
	double get_angular_separation() const;
	// Break thresholds: the engine reports joints past these in its joint
	// events; readable here per-frame as force/torque vs threshold.
	void set_force_threshold(double p_force);
	double get_force_threshold() const;
	void set_torque_threshold(double p_torque);
	double get_torque_threshold() const;
	// The core b3JointType of this joint, returned as its enum int (-1 when
	// not created): 0 parallel, 1 distance, 2 filter, 3 motor, 4 prismatic,
	// 5 revolute, 6 spherical, 7 weld, 8 wheel, 9 mover, 10 pogo. Also bound
	// as Box3DJoint.JOINT_TYPE_* constants (Extended core access III).
	int get_joint_type() const;
	// The joint's anchor frames on each body, in that body's local space.
	// Reading/writing these retargets the constraint without recreating it.
	Transform3D get_local_frame_a() const;
	void set_local_frame_a(const Transform3D &p_frame);
	Transform3D get_local_frame_b() const;
	void set_local_frame_b(const Transform3D &p_frame);
	// Soft-constraint tuning shared by all joint types: response frequency
	// (hertz, 0 = rigid) and damping ratio. get returns { hertz, damping }.
	Dictionary get_constraint_tuning() const;
	void set_constraint_tuning(double p_hertz, double p_damping);

	// --- Extended core access III: identity, sleep state, live readback -------
	// Naming convention for live readouts added in this section: get_current_*
	// reads a simulation quantity (angle, speed, applied force/torque) and
	// returns 0 / neutral when the joint isn't created; the plain property
	// getters keep returning the cached configured value. get_live_settings()
	// returns every engine-side configuration value through the b3 getters
	// (empty Dictionary when the joint isn't created).
	bool is_awake() const;
	void wake_connected_bodies();
	// The Box3DBody nodes the live joint connects (b3Joint_GetBodyA/B mapped
	// through body user data); null for the static world anchor.
	Box3DBody *get_body_a_node() const;
	Box3DBody *get_body_b_node() const;
	// The Box3DWorld node owning the live joint (b3Joint_GetWorld).
	Box3DWorld *get_world_node() const;
	Dictionary get_live_settings() const;
	// b3 joint user data is set to the owning Box3DJoint node at creation (the
	// node itself is the user data; no separate GDScript user-data slot is
	// exposed — use Object meta for that). Maps a joint id (e.g. from world
	// joint events) back to its node; null if unknown.
	static Box3DJoint *from_joint_id(b3JointId p_id);
};

// Revolute joint: rotates about this node's local Z axis (the blue gizmo arrow).
class Box3DHingeJoint : public Box3DJoint {
	GDCLASS(Box3DHingeJoint, Box3DJoint)

	bool limit_enabled = false;
	double lower_limit = 0.0; // radians
	double upper_limit = 0.0; // radians
	bool motor_enabled = false;
	double motor_speed = 0.0; // radians / second
	double max_motor_torque = 0.0;
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;
	double target_angle = 0.0; // radians, spring target (Extended core access III)

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;

public:
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_lower_limit(double p_v);
	double get_lower_limit() const;
	void set_upper_limit(double p_v);
	double get_upper_limit() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_torque(double p_v);
	double get_max_motor_torque() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;

	// --- Extended core access III: spring target + live readouts ---------------
	// Angle the spring drives toward, in [-PI, PI] (0 = the authored pose).
	void set_target_angle(double p_v);
	double get_target_angle() const;
	double get_current_angle() const;
	double get_current_motor_torque() const;
};

// Prismatic joint: body_b slides along this node's local X axis (the red gizmo arrow).
class Box3DSliderJoint : public Box3DJoint {
	GDCLASS(Box3DSliderJoint, Box3DJoint)

	bool limit_enabled = false;
	double lower_limit = 0.0; // meters
	double upper_limit = 0.0; // meters
	bool motor_enabled = false;
	double motor_speed = 0.0; // meters / second
	double max_motor_force = 0.0;
	// Extended core access III: linear spring along the axis.
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;
	double target_translation = 0.0; // meters

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;

public:
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_lower_limit(double p_v);
	double get_lower_limit() const;
	void set_upper_limit(double p_v);
	double get_upper_limit() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_force(double p_v);
	double get_max_motor_force() const;

	// --- Extended core access III: spring, target, live readouts ---------------
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_target_translation(double p_v);
	double get_target_translation() const;
	double get_current_translation() const;
	double get_current_speed() const;
	double get_current_motor_force() const;
};

// Distance joint: keeps body_a and body_b a set distance apart. Rope / rod / spring.
class Box3DDistanceJoint : public Box3DJoint {
	GDCLASS(Box3DDistanceJoint, Box3DJoint)

	double length = -1.0; // < 0 means "use the current distance between bodies"
	bool spring_enabled = false;
	double spring_hertz = 4.0;
	double spring_damping = 0.5;
	bool limit_enabled = false;
	double min_length = 0.0;
	double max_length = 10.0;
	// Extended core access III: spring force range + motor.
	double lower_spring_force = -INFINITY; // tension the spring can sustain (<= 0)
	double upper_spring_force = INFINITY; // compression the spring can sustain
	bool motor_enabled = false;
	double motor_speed = 0.0; // meters / second
	double max_motor_force = 0.0;

	void apply_spring_force_range();

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;

public:
	void set_length(double p_v);
	double get_length() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_limit_enabled(bool p_v);
	bool get_limit_enabled() const;
	void set_min_length(double p_v);
	double get_min_length() const;
	void set_max_length(double p_v);
	double get_max_length() const;

	// --- Extended core access III: spring force range, motor, live readouts ----
	// The motor (like the limit) only acts while spring_enabled is on; a
	// non-spring distance joint is rigid.
	void set_lower_spring_force(double p_v);
	double get_lower_spring_force() const;
	void set_upper_spring_force(double p_v);
	double get_upper_spring_force() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_speed(double p_v);
	double get_motor_speed() const;
	void set_max_motor_force(double p_v);
	double get_max_motor_force() const;
	double get_current_length() const;
	double get_current_motor_force() const;
};

// Ball / spherical joint: a point on body_b is pinned to a point on body_a,
// free to rotate. Good for ragdoll shoulders, chains, pendulums. Optional cone
// and twist limits constrain the rotation range (about the node's local Z).
class Box3DBallJoint : public Box3DJoint {
	GDCLASS(Box3DBallJoint, Box3DJoint)

	bool cone_limit_enabled = false;
	double cone_angle = 0.5; // radians, half-angle of the cone
	bool twist_limit_enabled = false;
	double twist_lower = 0.0; // radians
	double twist_upper = 0.0; // radians
	bool spring_enabled = false;
	double spring_hertz = 1.0;
	double spring_damping = 0.7;
	double friction_torque = 0.0; // > 0 enables a zero-target motor = dry joint friction
	// Extended core access III: spring target + velocity motor.
	Quaternion target_rotation; // frame B relative to frame A
	bool motor_enabled = false;
	Vector3 motor_velocity; // radians / second, world space (wB - wA)
	double max_motor_torque = 0.0;

	// Pushes the effective motor state (explicit motor, else friction) live.
	void apply_motor();

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;

public:
	void set_cone_limit_enabled(bool p_v);
	bool get_cone_limit_enabled() const;
	void set_cone_angle(double p_v);
	double get_cone_angle() const;
	void set_twist_limit_enabled(bool p_v);
	bool get_twist_limit_enabled() const;
	void set_twist_lower(double p_v);
	double get_twist_lower() const;
	void set_twist_upper(double p_v);
	double get_twist_upper() const;
	void set_spring_enabled(bool p_v);
	bool get_spring_enabled() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_friction_torque(double p_v);
	double get_friction_torque() const;

	// --- Extended core access III: target rotation, motor, live readouts -------
	// motor_enabled takes precedence over friction_torque (which is itself a
	// zero-velocity motor); with it off, friction_torque behaves as before.
	void set_target_rotation(const Quaternion &p_v);
	Quaternion get_target_rotation() const;
	void set_motor_enabled(bool p_v);
	bool get_motor_enabled() const;
	void set_motor_velocity(const Vector3 &p_v);
	Vector3 get_motor_velocity() const;
	void set_max_motor_torque(double p_v);
	double get_max_motor_torque() const;
	double get_current_twist_angle() const;
	double get_current_cone_angle() const;
	Vector3 get_current_motor_torque() const;
};

// Fixed / weld joint: rigidly locks two bodies together.
class Box3DFixedJoint : public Box3DJoint {
	GDCLASS(Box3DFixedJoint, Box3DJoint)

	double linear_hertz = 0.0;  // 0 = perfectly rigid
	double angular_hertz = 0.0; // 0 = perfectly rigid
	double linear_damping = 0.0; // Extended core access III (b3 default 0)
	double angular_damping = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;

public:
	void set_linear_hertz(double p_v);
	double get_linear_hertz() const;
	void set_angular_hertz(double p_v);
	double get_angular_hertz() const;

	// --- Extended core access III: spring damping ratios -----------------------
	void set_linear_damping(double p_v);
	double get_linear_damping() const;
	void set_angular_damping(double p_v);
	double get_angular_damping() const;
};

// Wheel joint: body_a is the chassis, body_b the wheel. The wheel travels on a
// suspension spring along the node's local Y (the green gizmo arrow), spins
// about the node's local Z (the axle), and can optionally steer about the
// suspension axis. This is box3d's vehicle joint — see the Car sample, which
// mirrors upstream's "Driving" sample.
class Box3DWheelJoint : public Box3DJoint {
	GDCLASS(Box3DWheelJoint, Box3DJoint)

	bool suspension_enabled = true;
	double suspension_hertz = 1.0;
	double suspension_damping = 0.7;
	bool suspension_limit_enabled = false;
	double lower_suspension_limit = 0.0; // meters
	double upper_suspension_limit = 0.0; // meters
	bool spin_motor_enabled = false;
	double spin_motor_speed = 0.0; // radians / second
	double max_spin_torque = 0.0;
	bool steering_enabled = false;
	double steering_hertz = 1.0;
	double steering_damping = 0.7;
	double target_steering_angle = 0.0; // radians
	double max_steering_torque = 0.0;
	bool steering_limit_enabled = false;
	double lower_steering_limit = 0.0; // radians
	double upper_steering_limit = 0.0; // radians

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;

public:
	void set_suspension_enabled(bool p_v);
	bool get_suspension_enabled() const;
	void set_suspension_hertz(double p_v);
	double get_suspension_hertz() const;
	void set_suspension_damping(double p_v);
	double get_suspension_damping() const;
	void set_suspension_limit_enabled(bool p_v);
	bool get_suspension_limit_enabled() const;
	void set_lower_suspension_limit(double p_v);
	double get_lower_suspension_limit() const;
	void set_upper_suspension_limit(double p_v);
	double get_upper_suspension_limit() const;
	void set_spin_motor_enabled(bool p_v);
	bool get_spin_motor_enabled() const;
	void set_spin_motor_speed(double p_v);
	double get_spin_motor_speed() const;
	void set_max_spin_torque(double p_v);
	double get_max_spin_torque() const;
	void set_steering_enabled(bool p_v);
	bool get_steering_enabled() const;
	void set_steering_hertz(double p_v);
	double get_steering_hertz() const;
	void set_steering_damping(double p_v);
	double get_steering_damping() const;
	void set_target_steering_angle(double p_v);
	double get_target_steering_angle() const;
	void set_max_steering_torque(double p_v);
	double get_max_steering_torque() const;
	void set_steering_limit_enabled(bool p_v);
	bool get_steering_limit_enabled() const;
	void set_lower_steering_limit(double p_v);
	double get_lower_steering_limit() const;
	void set_upper_steering_limit(double p_v);
	double get_upper_steering_limit() const;
	// Live readouts from the simulation (0 when the joint isn't created yet).
	double get_spin_speed() const;
	double get_steering_angle() const;

	// --- Extended core access III: applied torques -----------------------------
	double get_current_spin_torque() const;
	double get_current_steering_torque() const;

protected:
	void fill_live_settings(Dictionary &r_settings) const override;
};

// Parallel joint: a spring that keeps the two bodies' copies of the node's
// local Z axis parallel. Point the node's Z up and leave body_b empty to keep
// body_a upright (it can still yaw); soften with hertz/damping/max_torque.
class Box3DParallelJoint : public Box3DJoint {
	GDCLASS(Box3DParallelJoint, Box3DJoint)

	double spring_hertz = 1.0;
	double spring_damping = 1.0;
	double max_torque = 0.0; // 0 = unlimited

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override; // Extended core access III

public:
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_max_torque(double p_v);
	double get_max_torque() const;
};

// Motor joint: drives the relative linear/angular velocity between two bodies
// (like a servo), and/or pulls the joint frames together with position
// springs. The spring half makes a great compliant "mouse grab": box3d's own
// samples hold bodies with linear_hertz 7.5, damping 1, a force cap, and
// max_torque as angular friction.
class Box3DMotorJoint : public Box3DJoint {
	GDCLASS(Box3DMotorJoint, Box3DJoint)

	Vector3 linear_velocity;
	double max_force = 1000.0;
	Vector3 angular_velocity;
	double max_torque = 1000.0;
	double linear_hertz = 0.0; // 0 = no position spring
	double linear_damping = 1.0;
	double max_spring_force = 0.0;
	double angular_hertz = 0.0;
	double angular_damping = 1.0;
	double max_spring_torque = 0.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override; // Extended core access III

public:
	void set_linear_velocity(const Vector3 &p_v);
	Vector3 get_linear_velocity() const;
	void set_max_force(double p_v);
	double get_max_force() const;
	void set_angular_velocity(const Vector3 &p_v);
	Vector3 get_angular_velocity() const;
	void set_max_torque(double p_v);
	double get_max_torque() const;
	void set_linear_hertz(double p_v);
	double get_linear_hertz() const;
	void set_linear_damping(double p_v);
	double get_linear_damping() const;
	void set_max_spring_force(double p_v);
	double get_max_spring_force() const;
	void set_angular_hertz(double p_v);
	double get_angular_hertz() const;
	void set_angular_damping(double p_v);
	double get_angular_damping() const;
	void set_max_spring_torque(double p_v);
	double get_max_spring_torque() const;
};

// --- Extended core access III: upstream character-mover joints ---------------

// Mover joint (experimental upstream): drives the horizontal velocity of a
// dynamic character. body_a is the driven character, body_b the ground or
// platform it moves relative to (empty = the static world). Force is applied
// only in the XZ plane of this node's frame on body_a (keep the node's Y up),
// capped by max_force; vertical motion is left to gravity / a Box3DPogoJoint.
// linear_velocity is the desired world-space velocity of body_a relative to
// body_b. collide_connected defaults to true here: the character must still
// stand on its ground body. (Internally b3 orders the bodies ground-first;
// get_local_frame_a/b and get_body_a/b_node still refer to this node's body_a/b.)
class Box3DMoverJoint : public Box3DJoint {
	GDCLASS(Box3DMoverJoint, Box3DJoint)

	Vector3 linear_velocity;
	double max_force = 1000.0;

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;
	bool swaps_bodies() const override { return true; }

public:
	Box3DMoverJoint();

	void set_linear_velocity(const Vector3 &p_v);
	Vector3 get_linear_velocity() const;
	void set_max_force(double p_v);
	double get_max_force() const;
};

// Pogo joint (experimental upstream): a one-dimensional spring that holds a
// dynamic character above the ground, as in upstream's DynamicMover. body_a is
// the character, body_b the ground body (empty = the static world). The pogo
// axis is this node's local Y on body_a; the spring pushes along `normal`
// (world-space ground normal) to keep the foot point rest_length below the
// node origin. At creation both anchors sit at the node origin (length 0);
// feed a ground ray hit each physics frame with set_ground_point() and
// set_normal(), like the sample does. max_compression_force bounds how hard it
// pushes up, max_tension_force how hard it may pull down (0 = never, e.g.
// while jumping). collide_connected defaults to true. (b3 orders the bodies
// ground-first internally; base frame/body accessors still use this node's
// body_a/b.)
class Box3DPogoJoint : public Box3DJoint {
	GDCLASS(Box3DPogoJoint, Box3DJoint)

	Vector3 normal = Vector3(0, 1, 0);
	double spring_hertz = 3.0;
	double spring_damping = 0.8;
	double rest_length = 0.9;
	double max_tension_force = 0.0;
	double max_compression_force = 100000.0;
	double initial_impulse = 0.0; // warm start for a recreated pogo
	double initial_speed = 0.0;

	static b3Vec3 safe_normal(const Vector3 &p_n);

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
	void fill_live_settings(Dictionary &r_settings) const override;
	bool swaps_bodies() const override { return true; }

public:
	Box3DPogoJoint();

	void set_normal(const Vector3 &p_v);
	Vector3 get_normal() const;
	void set_spring_hertz(double p_v);
	double get_spring_hertz() const;
	void set_spring_damping(double p_v);
	double get_spring_damping() const;
	void set_rest_length(double p_v);
	double get_rest_length() const;
	void set_max_tension_force(double p_v);
	double get_max_tension_force() const;
	void set_max_compression_force(double p_v);
	double get_max_compression_force() const;
	void set_initial_impulse(double p_v);
	double get_initial_impulse() const;
	void set_initial_speed(double p_v);
	double get_initial_speed() const;
	// Moves the ground-side anchor to a world-space point (a ray hit), in the
	// ground body's local space. No-op when the joint isn't created.
	void set_ground_point(const Vector3 &p_world_point);
	// Live readouts (0 when the joint isn't created).
	double get_current_length() const;
	double get_current_speed() const;
	double get_current_impulse() const;
};

// Filter joint: no constraint at all — it only disables collision between
// body_a and body_b (and, as a side effect of being a joint, keeps them in the
// same simulation island). Set both bodies; with body_b empty it filters
// against an invisible static anchor and does nothing useful.
// collide_connected is ignored (always false).
class Box3DFilterJoint : public Box3DJoint {
	GDCLASS(Box3DFilterJoint, Box3DJoint)

protected:
	static void _bind_methods();
	b3JointId create_specific(b3WorldId p_world, b3BodyId p_a, b3BodyId p_b,
			const Transform3D &p_xf_a, const Transform3D &p_xf_b, const Transform3D &p_joint) override;
};

} // namespace godot
