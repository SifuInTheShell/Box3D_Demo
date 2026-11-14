// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_body.h"

#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_world.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

#include <vector>

using namespace godot;

Box3DBody::Box3DBody() {}

Box3DBody::~Box3DBody() {
	free_owned_geometry();
}

// Releases every geometry blob Box3D shapes reference by pointer. Only safe
// once those shapes are gone (destroy_body / destructor).
void Box3DBody::free_owned_geometry() {
	if (mesh_data != nullptr) {
		b3DestroyMesh(mesh_data);
		mesh_data = nullptr;
	}
	if (height_field_data != nullptr) {
		b3DestroyHeightField(height_field_data);
		height_field_data = nullptr;
	}
	if (compound_data != nullptr) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
	}
	for (b3MeshData *m : extra_mesh_data) {
		b3DestroyMesh(m);
	}
	extra_mesh_data.clear();
}

Box3DWorld *Box3DBody::find_world() {
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

bool Box3DBody::is_body_valid() const {
	return body_live();
}

// Validity check that also syncs with an in-flight async world step: touching
// the b3 API while the solver thread runs would race, so wait it out first
// (a single atomic load when nothing is in flight).
bool Box3DBody::body_live() const {
	if (world != nullptr) {
		world->join_async_step();
	}
	return b3Body_IsValid(body_id);
}

void Box3DBody::create_in_world() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	world = find_world();
	if (world == nullptr) {
		UtilityFunctions::push_warning("Box3DBody has no Box3DWorld ancestor; it will not be simulated.");
		return;
	}
	b3WorldId world_id = world->get_world_id();
	if (!b3World_IsValid(world_id)) {
		return;
	}

	Transform3D xform = get_global_transform();
	Quaternion rotation = xform.basis.get_rotation_quaternion();

	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = (b3BodyType)body_type;
	body_def.position = to_b3_pos(xform.origin);
	body_def.rotation = to_b3(rotation);
	body_def.linearDamping = (float)linear_damping;
	body_def.angularDamping = (float)angular_damping;
	body_def.gravityScale = (float)gravity_scale;
	body_def.isBullet = continuous;
	body_def.enableContactRecycling = contact_recycling;
	body_def.allowFastRotation = allow_fast_rotation;
	body_def.motionLocks.linearX = lock_linear_x;
	body_def.motionLocks.linearY = lock_linear_y;
	body_def.motionLocks.linearZ = lock_linear_z;
	body_def.motionLocks.angularX = lock_angular_x;
	body_def.motionLocks.angularY = lock_angular_y;
	body_def.motionLocks.angularZ = lock_angular_z;
	body_def.enableSleep = sleep_enabled;
	body_def.safetyFactor = (float)safety_factor;
	// Box3D copies the name into its own name cache.
	CharString body_name_utf8 = body_name.utf8();
	body_def.name = body_name.is_empty() ? nullptr : body_name_utf8.get_data();
	body_def.userData = this;
	body_id = b3CreateBody(world_id, &body_def);
	snap_prev = b3Body_GetTransform(body_id);
	snap_curr = snap_prev;
	snap_awake = b3Body_IsAwake(body_id);
	debug_enabled = b3Body_IsEnabled(body_id);

	// Compound bodies: if there are Box3DCollisionShape children, build a shape
	// for each and skip the body's own shape_type.
	{
		Transform3D body_inv = get_global_transform().affine_inverse();
		bool has_child_shapes = false;
		// bake_compound: one baked b3CompoundData shape for all children
		// (static, non-sensor bodies only); falls back to runtime shapes.
		bool baked = bake_compound && create_baked_compound(body_inv);
		for (int i = 0; i < get_child_count(); ++i) {
			Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
			if (cs != nullptr) {
				has_child_shapes = true;
				if (!baked) {
					create_child_shape(cs, body_inv);
				}
			}
		}
		if (has_child_shapes) {
			debug_mass = b3Body_GetMass(body_id);
			debug_has_child_shapes = true;
			debug_min_ext = debug_min_extent();
			debug_max_ext = debug_max_extent();
			world->register_body(this);
			return;
		}
	}

	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.density = (float)density;
	shape_def.baseMaterial.friction = (float)friction;
	shape_def.baseMaterial.restitution = (float)restitution;
	shape_def.enableContactEvents = contact_monitor;
	shape_def.filter.categoryBits = collision_layer;
	shape_def.filter.maskBits = collision_mask;
	shape_def.isSensor = is_sensor;
	// Enable sensor events on every shape so sensors detect any body (like an
	// Area3D). Box3D only does work here in proportion to the number of sensors.
	shape_def.enableSensorEvents = true;
	// Hit events power the debug draw's impact flash; box3d only reports them
	// above the world's hit-event speed threshold (default 1 m/s).
	shape_def.enableHitEvents = true;

	switch (shape_type) {
		case SPHERE: {
			b3Sphere sphere;
			sphere.center = b3Vec3{ 0.0f, 0.0f, 0.0f };
			sphere.radius = (float)sphere_radius;
			b3CreateSphereShape(body_id, &shape_def, &sphere);
		} break;
		case CAPSULE: {
			float radius = (float)capsule_radius;
			float half = (float)(capsule_height * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			b3Capsule capsule;
			capsule.center1 = b3Vec3{ 0.0f, -half, 0.0f };
			capsule.center2 = b3Vec3{ 0.0f, half, 0.0f };
			capsule.radius = radius;
			b3CreateCapsuleShape(body_id, &shape_def, &capsule);
		} break;
		case CYLINDER: {
			// yOffset centers the cylinder on the body origin (Box3D builds it
			// base-up from the offset), matching Godot's centered CylinderMesh.
			float half = (float)capsule_height * 0.5f;
			b3HullData *hull = b3CreateCylinder((float)capsule_height, (float)capsule_radius, -half, cylinder_sides);
			if (hull != nullptr) {
				b3CreateHullShape(body_id, &shape_def, hull);
				b3DestroyHull(hull);
			}
		} break;
		case CONE: {
			// radius1 = base, radius2 = 0 (the point). b3CreateCone has no offset,
			// so bake a -height/2 shift to center it on the body origin.
			b3HullData *hull = b3CreateCone((float)capsule_height, (float)capsule_radius, 0.0f, cylinder_sides);
			if (hull != nullptr) {
				b3Transform xf;
				xf.p = b3Vec3{ 0.0f, -(float)capsule_height * 0.5f, 0.0f };
				xf.q = b3Quat_identity;
				b3CreateTransformedHullShape(body_id, &shape_def, hull, xf, b3Vec3_one);
				b3DestroyHull(hull);
			}
		} break;
		case HULL: {
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int count = faces.size();
				if (count >= 4) {
					std::vector<b3Vec3> points((size_t)count);
					for (int i = 0; i < count; ++i) {
						points[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					int max_verts = count < 255 ? count : 255;
					b3HullData *hull = b3CreateHull(points.data(), count, max_verts);
					if (hull != nullptr) {
						b3CreateHullShape(body_id, &shape_def, hull);
						b3DestroyHull(hull);
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Hull but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case MESH: {
			if (mesh_data != nullptr) {
				b3DestroyMesh(mesh_data);
				mesh_data = nullptr;
			}
			if (body_type != STATIC) {
				UtilityFunctions::push_warning("Box3DBody: Mesh colliders only generate contacts on static bodies.");
			}
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				PackedVector3Array faces = src_mesh->get_faces();
				int vcount = faces.size();
				if (vcount >= 3 && (vcount % 3) == 0) {
					std::vector<b3Vec3> verts((size_t)vcount);
					std::vector<int32_t> idx((size_t)vcount);
					for (int i = 0; i < vcount; ++i) {
						verts[(size_t)i] = to_b3(src_local.xform(faces[i]));
					}
					// Reverse triangle winding: Godot winds faces so the normal
					// points outward, but Box3D's one-sided mesh collision uses the
					// opposite winding, so flip to collide with the outer surface.
					for (int t = 0; t < vcount / 3; ++t) {
						idx[(size_t)(t * 3 + 0)] = t * 3 + 0;
						idx[(size_t)(t * 3 + 1)] = t * 3 + 2;
						idx[(size_t)(t * 3 + 2)] = t * 3 + 1;
					}
					b3MeshDef def = {};
					def.vertices = verts.data();
					def.indices = idx.data();
					def.vertexCount = vcount;
					def.triangleCount = vcount / 3;
					def.weldVertices = true;
					def.weldTolerance = 0.001f;
					def.identifyEdges = true;
					// Box3D keeps a pointer to mesh_data, so it must live until the
					// body is destroyed (see destroy_body()).
					mesh_data = b3CreateMesh(&def, nullptr, 0);
					if (mesh_data != nullptr) {
						b3CreateMeshShape(body_id, &shape_def, mesh_data, b3Vec3_one);
					}
				}
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Mesh but no collision_mesh or child MeshInstance3D was found.");
			}
		} break;
		case FIT_MESH: {
			// Box collider auto-sized to the child MeshInstance3D's mesh bounds, so
			// resizing the visual mesh resizes the collider — no separate box_size.
			Ref<Mesh> src_mesh;
			Transform3D src_local;
			if (resolve_collision_mesh(src_mesh, src_local)) {
				AABB aabb = src_mesh->get_aabb();
				// Transform the 8 corners into body space and take their bounds.
				AABB local_aabb;
				for (int c = 0; c < 8; ++c) {
					Vector3 corner = src_local.xform(aabb.get_endpoint(c));
					if (c == 0) {
						local_aabb = AABB(corner, Vector3());
					} else {
						local_aabb = local_aabb.expand(corner);
					}
				}
				Vector3 h = local_aabb.size * 0.5;
				Vector3 center = local_aabb.position + h;
				b3Transform xf;
				xf.p = to_b3(center);
				xf.q = b3Quat_identity;
				b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, xf);
				b3CreateHullShape(body_id, &shape_def, &box.base);
			} else {
				UtilityFunctions::push_warning("Box3DBody shape_type is Fit Mesh but no child MeshInstance3D was found.");
			}
		} break;
		case HEIGHTFIELD: {
			create_height_field_shape(shape_def);
		} break;
		case BOX:
		default: {
			b3BoxHull box = b3MakeBoxHull((float)(box_size.x * 0.5), (float)(box_size.y * 0.5), (float)(box_size.z * 0.5));
			b3CreateHullShape(body_id, &shape_def, &box.base);
		} break;
	}

	debug_mass = b3Body_GetMass(body_id);
	debug_has_child_shapes = false;
	debug_min_ext = debug_min_extent();
	debug_max_ext = debug_max_extent();
	update_auto_visual();
	world->register_body(this);
}

bool Box3DBody::resolve_collision_mesh(Ref<Mesh> &r_mesh, Transform3D &r_local) {
	if (collision_mesh.is_valid()) {
		r_mesh = collision_mesh;
		r_local = Transform3D();
		return true;
	}
	// Fall back to the first child MeshInstance3D's mesh, at its transform
	// relative to this body — so devs can drop in their own model as a collider
	// without assigning collision_mesh separately.
	Transform3D body_inv = get_global_transform().affine_inverse();
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		// Skip our own auto_visual mesh: it's derived FROM the collision shape,
		// so it must never be used as a collision source (would self-reference).
		if (mi != nullptr && mi != auto_mesh_instance && mi->get_mesh().is_valid()) {
			r_mesh = mi->get_mesh();
			r_local = body_inv * mi->get_global_transform();
			return true;
		}
	}
	return false;
}

void Box3DBody::update_auto_visual() {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (!auto_visual) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}
	// Defer to a user-provided MeshInstance3D child: auto_visual only fills in
	// when there's nothing else drawing the body.
	for (int i = 0; i < get_child_count(); ++i) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(get_child(i));
		if (mi != nullptr && mi != auto_mesh_instance) {
			if (auto_mesh_instance != nullptr) {
				auto_mesh_instance->queue_free();
				auto_mesh_instance = nullptr;
			}
			return;
		}
	}

	// Build a mesh matching the current primitive collider. Hull/Mesh/Fit Mesh
	// have no size of their own to mirror (they derive the collider FROM a
	// mesh, the opposite direction), so nothing is generated for those.
	Ref<Mesh> mesh;
	switch (shape_type) {
		case SPHERE: {
			Ref<SphereMesh> m;
			m.instantiate();
			m->set_radius((float)sphere_radius);
			m->set_height((float)sphere_radius * 2.0f);
			mesh = m;
		} break;
		case CAPSULE: {
			Ref<CapsuleMesh> m;
			m.instantiate();
			m->set_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CYLINDER: {
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius((float)capsule_radius);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case CONE: {
			// Apex up, base down — matches b3CreateCone's centering (see the
			// CONE case above) and Godot's CylinderMesh (top face at +height/2).
			Ref<CylinderMesh> m;
			m.instantiate();
			m->set_top_radius(0.0f);
			m->set_bottom_radius((float)capsule_radius);
			m->set_height((float)capsule_height);
			mesh = m;
		} break;
		case BOX: {
			Ref<BoxMesh> m;
			m.instantiate();
			m->set_size(box_size); // BoxMesh size is full extents, like box_size
			mesh = m;
		} break;
		default:
			break;
	}

	if (!mesh.is_valid()) {
		if (auto_mesh_instance != nullptr) {
			auto_mesh_instance->queue_free();
			auto_mesh_instance = nullptr;
		}
		return;
	}

	if (auto_mesh_instance == nullptr) {
		auto_mesh_instance = memnew(MeshInstance3D);
		auto_mesh_instance->set_name("Box3DAutoVisual");
		add_child(auto_mesh_instance);
	}
	auto_mesh_instance->set_mesh(mesh);
}

void Box3DBody::create_child_shape(Box3DCollisionShape *p_shape, const Transform3D &p_body_inv) {
	b3ShapeDef sd = b3DefaultShapeDef();
	sd.density = (float)p_shape->get_density();
	sd.baseMaterial.friction = (float)p_shape->get_friction();
	sd.baseMaterial.restitution = (float)p_shape->get_restitution();
	sd.enableContactEvents = contact_monitor;
	sd.filter.categoryBits = collision_layer;
	sd.filter.maskBits = collision_mask;
	sd.isSensor = is_sensor;
	sd.enableSensorEvents = true;
	sd.enableHitEvents = true;
	CharString shape_name_utf8 = p_shape->get_shape_name().utf8();
	sd.name = p_shape->get_shape_name().is_empty() ? nullptr : shape_name_utf8.get_data();

	// The shape's transform relative to the body.
	Transform3D local = p_body_inv * p_shape->get_global_transform();
	switch (p_shape->get_shape_type()) {
		case Box3DCollisionShape::CYLINDER: {
			// Centered on the child node origin (yOffset -h/2, like the body's
			// own CYLINDER), then placed by the child's local transform.
			float ch_h = (float)p_shape->get_capsule_height();
			b3HullData *hull = b3CreateCylinder(ch_h, (float)p_shape->get_capsule_radius(), -ch_h * 0.5f, p_shape->get_sides());
			if (hull != nullptr) {
				b3Transform xf;
				xf.p = to_b3(local.origin);
				xf.q = to_b3(local.basis.get_rotation_quaternion());
				b3CreateTransformedHullShape(body_id, &sd, hull, xf, b3Vec3_one);
				b3DestroyHull(hull);
			}
		} break;
		case Box3DCollisionShape::CONE: {
			// b3CreateCone has no offset; bake the -h/2 centering shift into
			// the placement transform (mirrors the body's own CONE case).
			float ch_h = (float)p_shape->get_capsule_height();
			b3HullData *hull = b3CreateCone(ch_h, (float)p_shape->get_capsule_radius(), 0.0f, p_shape->get_sides());
			if (hull != nullptr) {
				b3Transform xf;
				xf.p = to_b3(local.xform(Vector3(0, -ch_h * 0.5f, 0)));
				xf.q = to_b3(local.basis.get_rotation_quaternion());
				b3CreateTransformedHullShape(body_id, &sd, hull, xf, b3Vec3_one);
				b3DestroyHull(hull);
			}
		} break;
		case Box3DCollisionShape::SPHERE: {
			b3Sphere sphere;
			sphere.center = to_b3(local.origin);
			sphere.radius = (float)p_shape->get_sphere_radius();
			b3CreateSphereShape(body_id, &sd, &sphere);
		} break;
		case Box3DCollisionShape::CAPSULE: {
			float radius = (float)p_shape->get_capsule_radius();
			float half = (float)(p_shape->get_capsule_height() * 0.5) - radius;
			if (half < 0.0f) {
				half = 0.0f;
			}
			b3Capsule capsule;
			capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)));
			capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)));
			capsule.radius = radius;
			b3CreateCapsuleShape(body_id, &sd, &capsule);
		} break;
		case Box3DCollisionShape::BOX:
		default: {
			Vector3 h = p_shape->get_box_size() * 0.5;
			b3BoxHull box = b3MakeTransformedBoxHull((float)h.x, (float)h.y, (float)h.z, to_b3_transform(local));
			b3CreateHullShape(body_id, &sd, &box.base);
		} break;
	}
}

void Box3DBody::request_rebuild() {
	rebuild_if_alive();
}

void Box3DBody::destroy_body() {
	if (world != nullptr) {
		world->unregister_body(this);
	}
	if (body_live()) {
		b3DestroyBody(body_id);
	}
	body_id = b3_nullBodyId;
	// The shapes (and their mesh / height-field / compound references) are
	// gone now, so the geometry is free to release.
	free_owned_geometry();
}

void Box3DBody::rebuild_if_alive() {
	if (is_body_valid()) {
		destroy_body();
		create_in_world();
	}
}

void Box3DBody::apply_motion_locks() {
	if (!body_live()) {
		return;
	}
	b3MotionLocks locks;
	locks.linearX = lock_linear_x;
	locks.linearY = lock_linear_y;
	locks.linearZ = lock_linear_z;
	locks.angularX = lock_angular_x;
	locks.angularY = lock_angular_y;
	locks.angularZ = lock_angular_z;
	b3Body_SetMotionLocks(body_id, locks);
}

void Box3DBody::sync_to_physics(double p_delta) {
	if (!body_live() || body_type != KINEMATIC) {
		return;
	}
	Transform3D xform = get_global_transform();
	b3WorldTransform target;
	target.p = to_b3_pos(xform.origin);
	target.q = to_b3(xform.basis.get_rotation_quaternion());
	// Solves for the velocity that reaches the target over one step, so the
	// kinematic body pushes dynamic bodies correctly instead of teleporting.
	b3Body_SetTargetTransform(body_id, target, (float)p_delta, true);
}

void Box3DBody::sync_from_physics() {
	if (body_type != DYNAMIC || !body_live()) {
		return;
	}
	// Sleeping bodies don't move, so skip the node update once their final
	// transform has been written — big scenes idle for free this way.
	if (b3Body_IsAwake(body_id)) {
		asleep_synced = false;
		snap_awake = true;
	} else {
		snap_awake = false;
		if (asleep_synced) {
			return;
		}
		asleep_synced = true;
	}
	b3WorldTransform t = b3Body_GetTransform(body_id);
	snap_prev = snap_curr;
	snap_curr = t;
	if (sync_node_transform) {
		set_global_transform(Transform3D(Basis(to_gd(t.q)), to_gd_pos(t.p)));
	}
}

bool Box3DBody::is_awake_now() const {
	return body_live() && b3Body_IsAwake(body_id);
}

bool Box3DBody::is_enabled_now() const {
	return body_live() && b3Body_IsEnabled(body_id);
}

void Box3DBody::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				create_in_world();
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			destroy_body();
			world = nullptr;
		} break;
	}
}

void Box3DBody::emit_contact_begin(Box3DBody *p_other) {
	emit_signal("body_entered", p_other);
}

void Box3DBody::emit_hit(Box3DBody *p_other, const Vector3 &p_point,
		const Vector3 &p_normal, float p_approach_speed) {
	emit_signal("body_hit", p_other, p_point, p_normal, p_approach_speed);
}

void Box3DBody::emit_contact_end(Box3DBody *p_other) {
	emit_signal("body_exited", p_other);
}

void Box3DBody::emit_area_begin(Box3DBody *p_visitor) {
	emit_signal("area_entered", p_visitor);
}

void Box3DBody::emit_area_end(Box3DBody *p_visitor) {
	emit_signal("area_exited", p_visitor);
}

// --- Scripting API ---

void Box3DBody::apply_central_force(const Vector3 &p_force) {
	if (body_live()) {
		b3Body_ApplyForceToCenter(body_id, to_b3(p_force), true);
	}
}

void Box3DBody::apply_central_impulse(const Vector3 &p_impulse) {
	if (body_live()) {
		b3Body_ApplyLinearImpulseToCenter(body_id, to_b3(p_impulse), true);
	}
}

void Box3DBody::apply_torque(const Vector3 &p_torque) {
	if (body_live()) {
		b3Body_ApplyTorque(body_id, to_b3(p_torque), true);
	}
}

void Box3DBody::set_linear_velocity(const Vector3 &p_velocity) {
	if (body_live()) {
		b3Body_SetLinearVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_linear_velocity() const {
	if (body_live()) {
		return to_gd(b3Body_GetLinearVelocity(body_id));
	}
	return Vector3();
}

void Box3DBody::set_angular_velocity(const Vector3 &p_velocity) {
	if (body_live()) {
		b3Body_SetAngularVelocity(body_id, to_b3(p_velocity));
	}
}

Vector3 Box3DBody::get_angular_velocity() const {
	if (body_live()) {
		return to_gd(b3Body_GetAngularVelocity(body_id));
	}
	return Vector3();
}

double Box3DBody::get_mass() const {
	if (body_live()) {
		return b3Body_GetMass(body_id);
	}
	return 0.0;
}

void Box3DBody::teleport(const Transform3D &p_xform) {
	// Reposition the body instantly (respawn / reset), clearing momentum so it
	// starts at rest. Unlike a kinematic move this doesn't sweep through the
	// world, so don't teleport into overlapping geometry.
	set_global_transform(p_xform);
	// With physics interpolation on, an instant jump must not be smeared
	// across the render frame.
	reset_physics_interpolation();
	if (body_live()) {
		// The render snapshots must jump too, not smear the teleport.
		snap_curr.p = to_b3_pos(p_xform.origin);
		snap_curr.q = to_b3(p_xform.basis.get_rotation_quaternion());
		snap_prev = snap_curr;
		b3Body_SetTransform(body_id, to_b3_pos(p_xform.origin),
				to_b3(p_xform.basis.get_rotation_quaternion()));
		b3Body_SetLinearVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAngularVelocity(body_id, to_b3(Vector3()));
		b3Body_SetAwake(body_id, true);
	}
}

// --- Properties ---

void Box3DBody::set_body_type(int p_type) {
	body_type = (BodyType)p_type;
	// Static-only geometry (height field, baked compound, triangle mesh) is
	// rebuilt so creation re-validates/warns; everything else switches live.
	if (shape_type == HEIGHTFIELD || shape_type == MESH || compound_data != nullptr) {
		rebuild_if_alive();
		return;
	}
	if (body_live()) {
		b3Body_SetType(body_id, (b3BodyType)body_type);
		debug_mass = b3Body_GetMass(body_id);
		snap_awake = b3Body_IsAwake(body_id);
		asleep_synced = false;
	}
}

int Box3DBody::get_body_type() const {
	return (int)body_type;
}

void Box3DBody::set_shape_type(int p_type) {
	shape_type = (ShapeType)p_type;
	rebuild_if_alive();
}

int Box3DBody::get_shape_type() const {
	return (int)shape_type;
}

void Box3DBody::set_box_size(const Vector3 &p_size) {
	box_size = p_size;
	rebuild_if_alive();
}

Vector3 Box3DBody::get_box_size() const {
	return box_size;
}

void Box3DBody::set_sphere_radius(double p_radius) {
	sphere_radius = p_radius;
	rebuild_if_alive();
}

double Box3DBody::get_sphere_radius() const {
	return sphere_radius;
}

void Box3DBody::set_capsule_radius(double p_radius) {
	capsule_radius = p_radius;
	rebuild_if_alive();
}

double Box3DBody::get_capsule_radius() const {
	return capsule_radius;
}

void Box3DBody::set_capsule_height(double p_height) {
	capsule_height = p_height;
	rebuild_if_alive();
}

double Box3DBody::get_capsule_height() const {
	return capsule_height;
}

void Box3DBody::set_cylinder_sides(int p_sides) {
	cylinder_sides = p_sides < 3 ? 3 : p_sides;
	rebuild_if_alive();
}

int Box3DBody::get_cylinder_sides() const {
	return cylinder_sides;
}

void Box3DBody::set_collision_mesh(const Ref<Mesh> &p_mesh) {
	collision_mesh = p_mesh;
	rebuild_if_alive();
}

Ref<Mesh> Box3DBody::get_collision_mesh() const {
	return collision_mesh;
}

void Box3DBody::set_density(double p_density) {
	density = p_density;
	rebuild_if_alive();
}

double Box3DBody::get_density() const {
	return density;
}

void Box3DBody::set_friction(double p_friction) {
	friction = p_friction;
	rebuild_if_alive();
}

double Box3DBody::get_friction() const {
	return friction;
}

void Box3DBody::set_restitution(double p_restitution) {
	restitution = p_restitution;
	rebuild_if_alive();
}

double Box3DBody::get_restitution() const {
	return restitution;
}

void Box3DBody::set_linear_damping(double p_damping) {
	linear_damping = p_damping;
	if (body_live()) {
		b3Body_SetLinearDamping(body_id, (float)linear_damping);
	}
}

double Box3DBody::get_linear_damping() const {
	if (body_live()) {
		return b3Body_GetLinearDamping(body_id);
	}
	return linear_damping;
}

void Box3DBody::set_angular_damping(double p_damping) {
	angular_damping = p_damping;
	if (body_live()) {
		b3Body_SetAngularDamping(body_id, (float)angular_damping);
	}
}

double Box3DBody::get_angular_damping() const {
	if (body_live()) {
		return b3Body_GetAngularDamping(body_id);
	}
	return angular_damping;
}

void Box3DBody::set_gravity_scale(double p_scale) {
	gravity_scale = p_scale;
	if (body_live()) {
		b3Body_SetGravityScale(body_id, (float)gravity_scale);
	}
}

double Box3DBody::get_gravity_scale() const {
	if (body_live()) {
		return b3Body_GetGravityScale(body_id);
	}
	return gravity_scale;
}

void Box3DBody::set_contact_monitor(bool p_enabled) {
	contact_monitor = p_enabled;
	rebuild_if_alive();
}

bool Box3DBody::get_contact_monitor() const {
	return contact_monitor;
}

void Box3DBody::set_is_sensor(bool p_sensor) {
	is_sensor = p_sensor;
	rebuild_if_alive();
}

bool Box3DBody::get_is_sensor() const {
	return is_sensor;
}

void Box3DBody::set_debug_visualize(bool p_enabled) {
	debug_visualize = p_enabled;
}

bool Box3DBody::get_debug_visualize() const {
	return debug_visualize;
}

float Box3DBody::debug_max_extent() const {
	// Distance from the body origin to its farthest collider point, mirroring
	// upstream's sim->maxExtent (rotation's contribution to the fast check).
	bool has_child_shapes = false;
	float max_extent = 0.0f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 0.0f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_height() * 0.5f;
				break;
			case Box3DCollisionShape::BOX:
			default:
				e = (float)(cs->get_box_size() * 0.5).length();
				break;
		}
		max_extent = MAX(max_extent, (float)cs->get_position().length() + e);
	}
	if (has_child_shapes) {
		return max_extent;
	}
	switch (shape_type) {
		case SPHERE:
			return (float)sphere_radius;
		case CAPSULE:
		case CYLINDER:
		case CONE: {
			float half_h = (float)capsule_height * 0.5f;
			float r = (float)capsule_radius;
			return Math::sqrt(half_h * half_h + r * r);
		}
		case BOX:
		case FIT_MESH:
			return (float)(box_size * 0.5).length();
		default:
			return 0.0f; // hull/mesh: no rotation contribution
	}
}

float Box3DBody::debug_min_extent() const {
	// Smallest half-extent of the collider, mirroring upstream's sim->minExtent
	// (used by its "fast body" debug state). Child shapes take over for
	// compounds, exactly like collision creation does.
	bool has_child_shapes = false;
	float min_extent = 1e9f;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs == nullptr) {
			continue;
		}
		has_child_shapes = true;
		float e = 1e9f;
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE:
				e = (float)cs->get_sphere_radius();
				break;
			case Box3DCollisionShape::CAPSULE:
				e = (float)cs->get_capsule_radius();
				break;
			case Box3DCollisionShape::BOX:
			default: {
				Vector3 half = cs->get_box_size() * 0.5;
				e = (float)MIN(half.x, MIN(half.y, half.z));
			} break;
		}
		min_extent = MIN(min_extent, e);
	}
	if (has_child_shapes) {
		return min_extent;
	}
	switch (shape_type) {
		case SPHERE:
			return (float)sphere_radius;
		case CAPSULE:
			return (float)capsule_radius;
		case CYLINDER:
		case CONE:
			return MIN((float)capsule_radius, (float)capsule_height * 0.5f);
		case BOX:
		case FIT_MESH: {
			Vector3 half = box_size * 0.5;
			return (float)MIN(half.x, MIN(half.y, half.z));
		}
		default:
			return 1e9f; // hull/mesh: never flagged fast
	}
}

void Box3DBody::set_continuous(bool p_enabled) {
	continuous = p_enabled;
	if (body_live()) {
		b3Body_SetBullet(body_id, p_enabled);
	}
}

bool Box3DBody::get_continuous() const {
	return continuous;
}

void Box3DBody::set_contact_recycling(bool p_enabled) {
	contact_recycling = p_enabled;
	if (body_live()) {
		b3Body_EnableContactRecycling(body_id, p_enabled);
	}
}

bool Box3DBody::get_contact_recycling() const {
	return contact_recycling;
}

void Box3DBody::set_sync_node_transform(bool p_enabled) {
	sync_node_transform = p_enabled;
	// Turning it back on catches the node up on the next tick.
	asleep_synced = false;
}

bool Box3DBody::get_sync_node_transform() const {
	return sync_node_transform;
}

void Box3DBody::set_allow_fast_rotation(bool p_enabled) {
	allow_fast_rotation = p_enabled;
	if (body_live()) {
		b3Body_AllowFastRotation(body_id, p_enabled);
	}
}

bool Box3DBody::get_allow_fast_rotation() const {
	return allow_fast_rotation;
}

void Box3DBody::set_lock_linear_x(bool p_v) { lock_linear_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_x() const { return lock_linear_x; }
void Box3DBody::set_lock_linear_y(bool p_v) { lock_linear_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_y() const { return lock_linear_y; }
void Box3DBody::set_lock_linear_z(bool p_v) { lock_linear_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_linear_z() const { return lock_linear_z; }
void Box3DBody::set_lock_angular_x(bool p_v) { lock_angular_x = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_x() const { return lock_angular_x; }
void Box3DBody::set_lock_angular_y(bool p_v) { lock_angular_y = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_y() const { return lock_angular_y; }
void Box3DBody::set_lock_angular_z(bool p_v) { lock_angular_z = p_v; apply_motion_locks(); }
bool Box3DBody::get_lock_angular_z() const { return lock_angular_z; }

void Box3DBody::set_collision_layer(int p_layer) {
	collision_layer = (uint32_t)p_layer;
	rebuild_if_alive();
}

int Box3DBody::get_collision_layer() const {
	return (int)collision_layer;
}

void Box3DBody::set_collision_mask(int p_mask) {
	collision_mask = (uint32_t)p_mask;
	rebuild_if_alive();
}

int Box3DBody::get_collision_mask() const {
	return (int)collision_mask;
}

void Box3DBody::set_auto_visual(bool p_enabled) {
	auto_visual = p_enabled;
	update_auto_visual();
}

bool Box3DBody::get_auto_visual() const {
	return auto_visual;
}

// --- Extended core access -----------------------------------------------------

void Box3DBody::apply_force(const Vector3 &p_force, const Vector3 &p_world_point) {
	if (body_live()) {
		b3Body_ApplyForce(body_id, to_b3(p_force), to_b3_pos(p_world_point), true);
	}
}

void Box3DBody::apply_impulse(const Vector3 &p_impulse, const Vector3 &p_world_point) {
	if (body_live()) {
		b3Body_ApplyLinearImpulse(body_id, to_b3(p_impulse), to_b3_pos(p_world_point), true);
	}
}

void Box3DBody::apply_angular_impulse(const Vector3 &p_impulse) {
	if (body_live()) {
		b3Body_ApplyAngularImpulse(body_id, to_b3(p_impulse), true);
	}
}

Vector3 Box3DBody::get_point_velocity(const Vector3 &p_world_point) const {
	if (!is_body_valid()) {
		return Vector3();
	}
	return to_gd(b3Body_GetWorldPointVelocity(body_id, to_b3_pos(p_world_point)));
}

Vector3 Box3DBody::get_center_of_mass() const {
	if (!is_body_valid()) {
		return get_global_position();
	}
	return to_gd_pos(b3Body_GetWorldCenter(body_id));
}

double Box3DBody::get_inverse_mass() const {
	if (!is_body_valid()) {
		return 0.0;
	}
	return b3Body_GetInverseMass(body_id);
}

Dictionary Box3DBody::get_mass_data() const {
	Dictionary d;
	if (!is_body_valid()) {
		return d;
	}
	b3MassData md = b3Body_GetMassData(body_id);
	d["mass"] = md.mass;
	d["local_center"] = to_gd(md.center);
	return d;
}

// Overrides mass and local centre of mass; the inertia tensor is rescaled by
// the mass ratio so the body keeps its rotational character.
void Box3DBody::set_mass_data(double p_mass, const Vector3 &p_local_center) {
	if (!body_live() || p_mass <= 0.0) {
		return;
	}
	b3MassData md = b3Body_GetMassData(body_id);
	float scale = md.mass > 0.0f ? (float)p_mass / md.mass : 1.0f;
	b3Vec3 *cols[3] = { &md.inertia.cx, &md.inertia.cy, &md.inertia.cz };
	for (int r = 0; r < 3; ++r) {
		cols[r]->x *= scale;
		cols[r]->y *= scale;
		cols[r]->z *= scale;
	}
	md.mass = (float)p_mass;
	md.center = to_b3(p_local_center);
	b3Body_SetMassData(body_id, md);
}

void Box3DBody::reset_mass() {
	if (body_live()) {
		b3Body_ApplyMassFromShapes(body_id);
	}
}

void Box3DBody::set_sleep_threshold(double p_speed) {
	if (body_live()) {
		b3Body_SetSleepThreshold(body_id, (float)p_speed);
	}
}

double Box3DBody::get_sleep_threshold() const {
	if (!is_body_valid()) {
		return 0.0;
	}
	return b3Body_GetSleepThreshold(body_id);
}

void Box3DBody::set_enabled(bool p_enabled) {
	if (!body_live()) {
		return;
	}
	if (p_enabled) {
		b3Body_Enable(body_id);
	} else {
		b3Body_Disable(body_id);
	}
}

bool Box3DBody::is_enabled() const {
	return is_enabled_now();
}

void Box3DBody::wake() {
	if (body_live()) {
		b3Body_SetAwake(body_id, true);
	}
}

bool Box3DBody::is_awake() const {
	return is_awake_now();
}

Dictionary Box3DBody::get_closest_point(const Vector3 &p_target) const {
	Dictionary d;
	if (!is_body_valid()) {
		d["distance"] = 0.0;
		d["point"] = p_target;
		return d;
	}
	b3Vec3 result;
	float dist = b3Body_GetClosestPoint(body_id, &result, to_b3(p_target));
	d["distance"] = dist;
	d["point"] = to_gd(result);
	return d;
}

// Live contact list: one entry per touching contact with the deepest point's
// world position, the normal pointing away from this body, and the solver's
// normal impulse (how hard the contact pushed this step).
Array Box3DBody::get_contact_data() const {
	Array out;
	if (!is_body_valid()) {
		return out;
	}
	int capacity = b3Body_GetContactCapacity(body_id);
	if (capacity <= 0) {
		return out;
	}
	std::vector<b3ContactData> contacts(capacity);
	int count = b3Body_GetContactData(body_id, contacts.data(), capacity);
	Vector3 my_center = to_gd_pos(b3Body_GetWorldCenter(body_id));
	for (int i = 0; i < count; ++i) {
		const b3ContactData &c = contacts[i];
		Box3DBody *body_a = world != nullptr ? world->body_from_shape(c.shapeIdA) : nullptr;
		Box3DBody *body_b = world != nullptr ? world->body_from_shape(c.shapeIdB) : nullptr;
		bool self_is_a = body_a == this;
		Box3DBody *other = self_is_a ? body_b : body_a;
		for (int m = 0; m < c.manifoldCount; ++m) {
			const b3Manifold &manifold = c.manifolds[m];
			if (manifold.pointCount <= 0) {
				continue;
			}
			int best = 0;
			for (int k = 1; k < manifold.pointCount; ++k) {
				if (manifold.points[k].totalNormalImpulse
						> manifold.points[best].totalNormalImpulse) {
					best = k;
				}
			}
			const b3ManifoldPoint &mp = manifold.points[best];
			Dictionary d;
			d["body"] = other;
			d["contact_id"] = Vector3i(c.contactId.index1, (int32_t)c.contactId.world0, (int32_t)c.contactId.generation);
			d["point"] = my_center + to_gd(self_is_a ? mp.anchorA : mp.anchorB);
			// Manifold normal points A -> B; flip so it points away from us.
			d["normal"] = self_is_a ? to_gd(manifold.normal) : -to_gd(manifold.normal);
			d["impulse"] = mp.totalNormalImpulse;
			d["separation"] = mp.separation;
			out.push_back(d);
		}
	}
	return out;
}

// --- Extended core access II: transforms, introspection, live shapes ----------

Vector3 Box3DBody::to_local_point(const Vector3 &p_world_point) const {
	if (!is_body_valid()) {
		return p_world_point;
	}
	return to_gd(b3Body_GetLocalPoint(body_id, to_b3_pos(p_world_point)));
}

Vector3 Box3DBody::to_world_point(const Vector3 &p_local_point) const {
	if (!is_body_valid()) {
		return p_local_point;
	}
	return to_gd_pos(b3Body_GetWorldPoint(body_id, to_b3(p_local_point)));
}

Vector3 Box3DBody::to_local_vector(const Vector3 &p_world_vector) const {
	if (!is_body_valid()) {
		return p_world_vector;
	}
	return to_gd(b3Body_GetLocalVector(body_id, to_b3(p_world_vector)));
}

Vector3 Box3DBody::to_world_vector(const Vector3 &p_local_vector) const {
	if (!is_body_valid()) {
		return p_local_vector;
	}
	return to_gd(b3Body_GetWorldVector(body_id, to_b3(p_local_vector)));
}

Vector3 Box3DBody::get_local_point_velocity(const Vector3 &p_local_point) const {
	if (!is_body_valid()) {
		return Vector3();
	}
	return to_gd(b3Body_GetLocalPointVelocity(body_id, to_b3(p_local_point)));
}

Vector3 Box3DBody::get_local_center() const {
	if (!is_body_valid()) {
		return Vector3();
	}
	return to_gd(b3Body_GetLocalCenter(body_id));
}

AABB Box3DBody::get_aabb() const {
	if (!is_body_valid()) {
		return AABB();
	}
	b3AABB box = b3Body_ComputeAABB(body_id);
	Vector3 lower = to_gd(box.lowerBound);
	Vector3 upper = to_gd(box.upperBound);
	return AABB(lower, upper - lower);
}

int Box3DBody::get_shape_count() const {
	if (!is_body_valid()) {
		return 0;
	}
	return b3Body_GetShapeCount(body_id);
}

int Box3DBody::get_joint_count() const {
	if (!is_body_valid()) {
		return 0;
	}
	return b3Body_GetJointCount(body_id);
}

std::vector<b3ShapeId> Box3DBody::shape_ids() const {
	std::vector<b3ShapeId> ids;
	if (!is_body_valid()) {
		return ids;
	}
	int count = b3Body_GetShapeCount(body_id);
	if (count <= 0) {
		return ids;
	}
	ids.resize(count);
	int got = b3Body_GetShapes(body_id, ids.data(), count);
	ids.resize(got < 0 ? 0 : got);
	return ids;
}

void Box3DBody::set_shape_friction(double p_friction) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_SetFriction(shape, (float)p_friction);
	}
}

double Box3DBody::get_shape_friction(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return 0.0;
	}
	return b3Shape_GetFriction(ids[p_shape_index]);
}

void Box3DBody::set_shape_restitution(double p_restitution) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_SetRestitution(shape, (float)p_restitution);
	}
}

double Box3DBody::get_shape_restitution(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return 0.0;
	}
	return b3Shape_GetRestitution(ids[p_shape_index]);
}

void Box3DBody::set_shape_density(double p_density, bool p_update_mass) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_SetDensity(shape, (float)p_density, p_update_mass);
	}
}

double Box3DBody::get_shape_density(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return 0.0;
	}
	return b3Shape_GetDensity(ids[p_shape_index]);
}

void Box3DBody::set_shape_filter(int p_category, int p_mask, int p_group) {
	for (b3ShapeId shape : shape_ids()) {
		b3Filter filter = b3Shape_GetFilter(shape);
		filter.categoryBits = (uint64_t)(uint32_t)p_category;
		filter.maskBits = (uint64_t)(uint32_t)p_mask;
		filter.groupIndex = p_group;
		// invokeContacts: re-evaluate existing contacts against the new filter.
		b3Shape_SetFilter(shape, filter, true);
	}
}

Dictionary Box3DBody::get_shape_filter(int p_shape_index) const {
	Dictionary d;
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return d;
	}
	b3Filter filter = b3Shape_GetFilter(ids[p_shape_index]);
	d["category"] = (int64_t)filter.categoryBits;
	d["mask"] = (int64_t)filter.maskBits;
	d["group"] = filter.groupIndex;
	return d;
}

void Box3DBody::set_shape_surface_material(const Dictionary &p_material) {
	// Missing keys fall back to the shape's current value, so a partial
	// Dictionary edits only the fields it names. Dictionary::get is const;
	// operator[] is not, hence get(key, default) here.
	for (b3ShapeId shape : shape_ids()) {
		b3SurfaceMaterial mat = b3Shape_GetSurfaceMaterial(shape);
		mat.friction = (float)(double)p_material.get("friction", (double)mat.friction);
		mat.restitution = (float)(double)p_material.get("restitution", (double)mat.restitution);
		mat.rollingResistance = (float)(double)p_material.get("rolling_resistance", (double)mat.rollingResistance);
		mat.tangentVelocity = to_b3((Vector3)p_material.get("tangent_velocity", to_gd(mat.tangentVelocity)));
		mat.userMaterialId = (uint64_t)(int64_t)p_material.get("user_material_id", (int64_t)mat.userMaterialId);
		mat.customColor = (uint32_t)(int64_t)p_material.get("custom_color", (int64_t)mat.customColor);
		b3Shape_SetSurfaceMaterial(shape, mat);
	}
}

Dictionary Box3DBody::get_shape_surface_material(int p_shape_index) const {
	Dictionary d;
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return d;
	}
	b3SurfaceMaterial mat = b3Shape_GetSurfaceMaterial(ids[p_shape_index]);
	d["friction"] = mat.friction;
	d["restitution"] = mat.restitution;
	d["rolling_resistance"] = mat.rollingResistance;
	d["tangent_velocity"] = to_gd(mat.tangentVelocity);
	d["user_material_id"] = (int64_t)mat.userMaterialId;
	d["custom_color"] = (int64_t)mat.customColor;
	return d;
}

void Box3DBody::enable_shape_contact_events(bool p_enabled) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_EnableContactEvents(shape, p_enabled);
	}
}

bool Box3DBody::are_shape_contact_events_enabled(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return false;
	}
	return b3Shape_AreContactEventsEnabled(ids[p_shape_index]);
}

void Box3DBody::enable_shape_hit_events(bool p_enabled) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_EnableHitEvents(shape, p_enabled);
	}
}

bool Box3DBody::are_shape_hit_events_enabled(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return false;
	}
	return b3Shape_AreHitEventsEnabled(ids[p_shape_index]);
}

void Box3DBody::enable_shape_sensor_events(bool p_enabled) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_EnableSensorEvents(shape, p_enabled);
	}
}

bool Box3DBody::are_shape_sensor_events_enabled(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return false;
	}
	return b3Shape_AreSensorEventsEnabled(ids[p_shape_index]);
}

void Box3DBody::enable_shape_presolve_events(bool p_enabled) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_EnablePreSolveEvents(shape, p_enabled);
	}
}

bool Box3DBody::are_shape_presolve_events_enabled(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return false;
	}
	return b3Shape_ArePreSolveEventsEnabled(ids[p_shape_index]);
}

bool Box3DBody::is_shape_sensor(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return false;
	}
	return b3Shape_IsSensor(ids[p_shape_index]);
}

int Box3DBody::get_shape_core_type(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return -1;
	}
	return (int)b3Shape_GetType(ids[p_shape_index]);
}

AABB Box3DBody::get_shape_aabb(int p_shape_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		return AABB();
	}
	b3AABB box = b3Shape_GetAABB(ids[p_shape_index]);
	Vector3 lower = to_gd(box.lowerBound);
	Vector3 upper = to_gd(box.upperBound);
	return AABB(lower, upper - lower);
}

Dictionary Box3DBody::get_shape_closest_point(const Vector3 &p_target, int p_shape_index) const {
	Dictionary d;
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		d["distance"] = 0.0;
		d["point"] = p_target;
		return d;
	}
	b3Vec3 result = b3Shape_GetClosestPoint(ids[p_shape_index], to_b3(p_target));
	Vector3 point = to_gd(result);
	d["point"] = point;
	d["distance"] = point.distance_to(p_target);
	return d;
}

Dictionary Box3DBody::shape_raycast(const Vector3 &p_from, const Vector3 &p_to, int p_shape_index) const {
	Dictionary d;
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_shape_index < 0 || p_shape_index >= (int)ids.size()) {
		d["hit"] = false;
		return d;
	}
	b3WorldCastOutput out = b3Shape_RayCast(ids[p_shape_index], to_b3_pos(p_from), to_b3(p_to - p_from));
	if (out.hit) {
		d["hit"] = true;
		// out.point is a world position (b3Pos in double-precision builds).
		d["position"] = to_gd_pos(out.point);
		d["normal"] = to_gd(out.normal);
		d["fraction"] = out.fraction;
	} else {
		d["hit"] = false;
	}
	return d;
}

// --- Extended core access III: full body/shape/contact API --------------------

namespace {

Vector3i contact_id_to_gd(b3ContactId p_id) {
	return Vector3i(p_id.index1, (int32_t)p_id.world0, (int32_t)p_id.generation);
}

b3ContactId contact_id_to_b3(const Vector3i &p_id) {
	b3ContactId id = b3_nullContactId;
	id.index1 = p_id.x;
	id.world0 = (uint16_t)p_id.y;
	id.generation = (uint32_t)p_id.z;
	return id;
}

Basis matrix_to_basis(const b3Matrix3 &p_m) {
	// b3Matrix3 is column-major (cx, cy, cz); Basis(x, y, z) takes columns.
	return Basis(to_gd(p_m.cx), to_gd(p_m.cy), to_gd(p_m.cz));
}

Dictionary material_to_dict(const b3SurfaceMaterial &p_mat) {
	Dictionary d;
	d["friction"] = p_mat.friction;
	d["restitution"] = p_mat.restitution;
	d["rolling_resistance"] = p_mat.rollingResistance;
	d["tangent_velocity"] = to_gd(p_mat.tangentVelocity);
	d["user_material_id"] = (int64_t)p_mat.userMaterialId;
	d["custom_color"] = (int64_t)p_mat.customColor;
	return d;
}

// Missing keys keep the value already in r_mat.
void dict_to_material(const Dictionary &p_dict, b3SurfaceMaterial &r_mat) {
	r_mat.friction = (float)(double)p_dict.get("friction", (double)r_mat.friction);
	r_mat.restitution = (float)(double)p_dict.get("restitution", (double)r_mat.restitution);
	r_mat.rollingResistance = (float)(double)p_dict.get("rolling_resistance", (double)r_mat.rollingResistance);
	r_mat.tangentVelocity = to_b3((Vector3)p_dict.get("tangent_velocity", to_gd(r_mat.tangentVelocity)));
	r_mat.userMaterialId = (uint64_t)(int64_t)p_dict.get("user_material_id", (int64_t)r_mat.userMaterialId);
	r_mat.customColor = (uint32_t)(int64_t)p_dict.get("custom_color", (int64_t)r_mat.customColor);
}

b3QueryFilter make_query_filter(int p_mask) {
	b3QueryFilter filter = b3DefaultQueryFilter();
	// -1 (all bits) from GDScript maps to every category.
	filter.maskBits = p_mask == -1 ? UINT64_MAX : (uint64_t)(uint32_t)p_mask;
	return filter;
}

// Capsule from { center1, center2, radius } or { height, radius } (upright,
// total height including caps, centred on the origin).
b3Capsule dict_to_capsule(const Dictionary &p_dict) {
	b3Capsule capsule;
	float radius = (float)(double)p_dict.get("radius", 0.5);
	capsule.radius = radius;
	if (p_dict.has("center1") || p_dict.has("center2")) {
		capsule.center1 = to_b3((Vector3)p_dict.get("center1", Vector3()));
		capsule.center2 = to_b3((Vector3)p_dict.get("center2", Vector3()));
	} else {
		float half = (float)(double)p_dict.get("height", 2.0) * 0.5f - radius;
		if (half < 0.0f) {
			half = 0.0f;
		}
		capsule.center1 = b3Vec3{ 0.0f, -half, 0.0f };
		capsule.center2 = b3Vec3{ 0.0f, half, 0.0f };
	}
	return capsule;
}

// Fills r_points/r_radius with a convex proxy described by p_dict (see the
// header for the accepted forms). Points are relative to the query origin.
void dict_to_proxy_points(const Dictionary &p_dict, std::vector<b3Vec3> &r_points, float &r_radius) {
	r_points.clear();
	r_radius = (float)(double)p_dict.get("radius", 0.0);
	if (p_dict.has("points")) {
		PackedVector3Array pts = p_dict["points"];
		for (int i = 0; i < pts.size() && i < B3_MAX_SHAPE_CAST_POINTS; ++i) {
			r_points.push_back(to_b3(pts[i]));
		}
	} else if (p_dict.has("half_extents")) {
		Vector3 h = p_dict["half_extents"];
		Quaternion q = p_dict.get("rotation", Quaternion());
		for (int c = 0; c < 8; ++c) {
			Vector3 corner((c & 1) ? h.x : -h.x, (c & 2) ? h.y : -h.y, (c & 4) ? h.z : -h.z);
			r_points.push_back(to_b3(q.xform(corner)));
		}
	} else if (p_dict.has("center1") || p_dict.has("center2") || p_dict.has("height")) {
		b3Capsule capsule = dict_to_capsule(p_dict);
		r_points.push_back(capsule.center1);
		r_points.push_back(capsule.center2);
		r_radius = capsule.radius;
	}
	if (r_points.empty()) {
		r_points.push_back(b3Vec3{ 0.0f, 0.0f, 0.0f }); // sphere / point
	}
}

AABB aabb_to_gd(const b3AABB &p_box) {
	Vector3 lower = to_gd(p_box.lowerBound);
	Vector3 upper = to_gd(p_box.upperBound);
	return AABB(lower, upper - lower);
}

Dictionary hull_to_dict(const b3HullData *p_hull) {
	Dictionary d;
	if (p_hull == nullptr) {
		return d;
	}
	PackedVector3Array points;
	const b3Vec3 *src = b3GetHullPoints(p_hull);
	for (int i = 0; src != nullptr && i < p_hull->vertexCount; ++i) {
		points.push_back(to_gd(src[i]));
	}
	// Faces as vertex-index loops, walked through the half-edge structure.
	Array faces;
	const b3HullFace *hull_faces = b3GetHullFaces(p_hull);
	const b3HullHalfEdge *edges = b3GetHullEdges(p_hull);
	for (int f = 0; hull_faces != nullptr && edges != nullptr && f < p_hull->faceCount; ++f) {
		PackedInt32Array loop;
		int first = hull_faces[f].edge;
		int e = first;
		int guard = 0;
		do {
			loop.push_back(edges[e].origin);
			e = edges[e].next;
		} while (e != first && ++guard <= p_hull->edgeCount);
		faces.push_back(loop);
	}
	d["points"] = points;
	d["faces"] = faces;
	d["center"] = to_gd(p_hull->center);
	d["volume"] = p_hull->volume;
	d["surface_area"] = p_hull->surfaceArea;
	d["inner_radius"] = p_hull->innerRadius;
	d["aabb"] = aabb_to_gd(p_hull->aabb);
	d["vertex_count"] = p_hull->vertexCount;
	d["edge_count"] = p_hull->edgeCount;
	d["face_count"] = p_hull->faceCount;
	return d;
}

} // namespace

b3ShapeId Box3DBody::shape_at(int p_index) const {
	std::vector<b3ShapeId> ids = shape_ids();
	if (p_index < 0 || p_index >= (int)ids.size()) {
		return b3_nullShapeId;
	}
	return ids[p_index];
}

int Box3DBody::shape_index_of(b3ShapeId p_shape) const {
	std::vector<b3ShapeId> ids = shape_ids();
	for (int i = 0; i < (int)ids.size(); ++i) {
		if (B3_ID_EQUALS(ids[i], p_shape)) {
			return i;
		}
	}
	return -1;
}

// Full contact description: { contact_id, body_a, body_b, shape_index_a,
// shape_index_b (index on that body, -1 if unknown), manifolds: [ { normal
// (A -> B), points: [ { point (world), separation, normal_impulse,
// total_normal_impulse, normal_velocity, triangle_index, persisted } ] } ] }.
Dictionary Box3DBody::contact_to_dict(const b3ContactData &p_contact) const {
	Dictionary d;
	d["contact_id"] = contact_id_to_gd(p_contact.contactId);
	Box3DBody *body_a = world != nullptr ? world->body_from_shape(p_contact.shapeIdA) : nullptr;
	Box3DBody *body_b = world != nullptr ? world->body_from_shape(p_contact.shapeIdB) : nullptr;
	d["body_a"] = body_a;
	d["body_b"] = body_b;
	d["shape_index_a"] = body_a != nullptr ? body_a->shape_index_of(p_contact.shapeIdA) : -1;
	d["shape_index_b"] = body_b != nullptr ? body_b->shape_index_of(p_contact.shapeIdB) : -1;
	Vector3 center_a;
	Vector3 center_b;
	if (b3Shape_IsValid(p_contact.shapeIdA)) {
		center_a = to_gd_pos(b3Body_GetWorldCenter(b3Shape_GetBody(p_contact.shapeIdA)));
	}
	if (b3Shape_IsValid(p_contact.shapeIdB)) {
		center_b = to_gd_pos(b3Body_GetWorldCenter(b3Shape_GetBody(p_contact.shapeIdB)));
	}
	Array manifolds;
	for (int m = 0; p_contact.manifolds != nullptr && m < p_contact.manifoldCount; ++m) {
		const b3Manifold &manifold = p_contact.manifolds[m];
		Dictionary md;
		md["normal"] = to_gd(manifold.normal);
		md["twist_impulse"] = manifold.twistImpulse;
		md["friction_impulse"] = to_gd(manifold.frictionImpulse);
		md["rolling_impulse"] = to_gd(manifold.rollingImpulse);
		Array points;
		for (int k = 0; k < manifold.pointCount; ++k) {
			const b3ManifoldPoint &mp = manifold.points[k];
			Dictionary pd;
			pd["point"] = center_a + to_gd(mp.anchorA);
			pd["point_b"] = center_b + to_gd(mp.anchorB);
			pd["separation"] = mp.separation;
			pd["normal_impulse"] = mp.normalImpulse;
			pd["total_normal_impulse"] = mp.totalNormalImpulse;
			pd["normal_velocity"] = mp.normalVelocity;
			pd["triangle_index"] = mp.triangleIndex;
			pd["persisted"] = mp.persisted;
			points.push_back(pd);
		}
		md["points"] = points;
		manifolds.push_back(md);
	}
	d["manifolds"] = manifolds;
	return d;
}

// Persistent properties --------------------------------------------------------

void Box3DBody::set_sleep_enabled(bool p_enabled) {
	sleep_enabled = p_enabled;
	if (body_live()) {
		b3Body_EnableSleep(body_id, p_enabled);
	}
}

bool Box3DBody::is_sleep_enabled() const {
	if (body_live()) {
		return b3Body_IsSleepEnabled(body_id);
	}
	return sleep_enabled;
}

void Box3DBody::set_safety_factor(double p_factor) {
	safety_factor = p_factor;
	if (body_live()) {
		b3Body_SetSafetyFactor(body_id, (float)p_factor);
	}
}

double Box3DBody::get_safety_factor() const {
	if (body_live()) {
		return b3Body_GetSafetyFactor(body_id);
	}
	return safety_factor;
}

void Box3DBody::set_body_name(const String &p_name) {
	body_name = p_name;
	if (body_live()) {
		CharString utf8 = p_name.utf8();
		b3Body_SetName(body_id, p_name.is_empty() ? nullptr : utf8.get_data());
	}
}

String Box3DBody::get_body_name() const {
	if (body_live()) {
		const char *name = b3Body_GetName(body_id);
		return name != nullptr ? String::utf8(name) : String();
	}
	return body_name;
}

void Box3DBody::set_bake_compound(bool p_enabled) {
	bake_compound = p_enabled;
	rebuild_if_alive();
}

bool Box3DBody::get_bake_compound() const {
	return bake_compound;
}

void Box3DBody::set_heightfield_heights(const PackedFloat32Array &p_heights) {
	heightfield_heights = p_heights;
	if (shape_type == HEIGHTFIELD) {
		rebuild_if_alive();
	}
}

PackedFloat32Array Box3DBody::get_heightfield_heights() const {
	return heightfield_heights;
}

void Box3DBody::set_heightfield_count_x(int p_count) {
	heightfield_count_x = p_count < 0 ? 0 : p_count;
	if (shape_type == HEIGHTFIELD) {
		rebuild_if_alive();
	}
}

int Box3DBody::get_heightfield_count_x() const {
	return heightfield_count_x;
}

void Box3DBody::set_heightfield_count_z(int p_count) {
	heightfield_count_z = p_count < 0 ? 0 : p_count;
	if (shape_type == HEIGHTFIELD) {
		rebuild_if_alive();
	}
}

int Box3DBody::get_heightfield_count_z() const {
	return heightfield_count_z;
}

void Box3DBody::set_heightfield_scale(const Vector3 &p_scale) {
	heightfield_scale = p_scale;
	if (shape_type == HEIGHTFIELD) {
		rebuild_if_alive();
	}
}

Vector3 Box3DBody::get_heightfield_scale() const {
	return heightfield_scale;
}

void Box3DBody::set_heightfield_materials(const PackedByteArray &p_materials) {
	heightfield_materials = p_materials;
	if (shape_type == HEIGHTFIELD) {
		rebuild_if_alive();
	}
}

PackedByteArray Box3DBody::get_heightfield_materials() const {
	return heightfield_materials;
}

void Box3DBody::create_height_field_shape(const b3ShapeDef &p_def) {
	if (height_field_data != nullptr) {
		b3DestroyHeightField(height_field_data);
		height_field_data = nullptr;
	}
	const int cx = heightfield_count_x;
	const int cz = heightfield_count_z;
	if (cx < 2 || cz < 2 || heightfield_heights.size() != cx * cz) {
		UtilityFunctions::push_warning("Box3DBody: Height Field needs heightfield_count_x/z >= 2 and exactly count_x * count_z heightfield_heights.");
		return;
	}
	if (heightfield_scale.x <= 0.0 || heightfield_scale.y <= 0.0 || heightfield_scale.z <= 0.0) {
		UtilityFunctions::push_warning("Box3DBody: heightfield_scale components must be positive.");
		return;
	}
	if (body_type != STATIC) {
		UtilityFunctions::push_warning("Box3DBody: Height Field colliders are only supported on static bodies.");
	}
	std::vector<float> heights((size_t)(cx * cz));
	float min_h = heightfield_heights[0];
	float max_h = heightfield_heights[0];
	for (int i = 0; i < cx * cz; ++i) {
		float h = heightfield_heights[i];
		heights[(size_t)i] = h;
		min_h = MIN(min_h, h);
		max_h = MAX(max_h, h);
	}
	const int cell_count = (cx - 1) * (cz - 1);
	std::vector<uint8_t> materials;
	if (heightfield_materials.size() == cell_count) {
		materials.resize((size_t)cell_count);
		for (int i = 0; i < cell_count; ++i) {
			materials[(size_t)i] = heightfield_materials[i];
		}
	} else if (heightfield_materials.size() != 0) {
		UtilityFunctions::push_warning("Box3DBody: heightfield_materials must hold (count_x - 1) * (count_z - 1) entries; ignored.");
	}
	b3HeightFieldDef def = {};
	def.heights = heights.data();
	def.materialIndices = materials.empty() ? nullptr : materials.data();
	def.scale = to_b3(heightfield_scale);
	def.countX = cx;
	def.countZ = cz;
	def.globalMinimumHeight = min_h;
	def.globalMaximumHeight = max_h;
	def.clockwiseWinding = false;
	// Box3D references (does not copy) the height field: kept until
	// destroy_body().
	height_field_data = b3CreateHeightField(&def);
	if (height_field_data != nullptr) {
		b3CreateHeightFieldShape(body_id, &p_def, height_field_data);
	}
}

bool Box3DBody::create_baked_compound(const Transform3D &p_body_inv) {
	if (body_type != STATIC || is_sensor) {
		UtilityFunctions::push_warning("Box3DBody: bake_compound requires a static, non-sensor body; using runtime shapes.");
		return false;
	}
	std::vector<Box3DCollisionShape *> children;
	for (int i = 0; i < get_child_count(); ++i) {
		Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(get_child(i));
		if (cs != nullptr) {
			children.push_back(cs);
		}
	}
	if (children.empty()) {
		return false;
	}
	std::vector<b3CompoundSphereDef> spheres;
	std::vector<b3CompoundCapsuleDef> capsules;
	std::vector<b3CompoundHullDef> hulls;
	// Box hulls live in this vector (reserved up front so the pointers the
	// hull defs take stay valid); cylinder/cone hulls are heap blobs freed
	// once b3CreateCompound has cloned them.
	std::vector<b3BoxHull> boxes;
	boxes.reserve(children.size());
	std::vector<b3HullData *> owned_hulls;
	for (Box3DCollisionShape *cs : children) {
		b3SurfaceMaterial mat = b3DefaultSurfaceMaterial();
		mat.friction = (float)cs->get_friction();
		mat.restitution = (float)cs->get_restitution();
		Transform3D local = p_body_inv * cs->get_global_transform();
		switch (cs->get_shape_type()) {
			case Box3DCollisionShape::SPHERE: {
				b3CompoundSphereDef sd;
				sd.sphere.center = to_b3(local.origin);
				sd.sphere.radius = (float)cs->get_sphere_radius();
				sd.material = mat;
				spheres.push_back(sd);
			} break;
			case Box3DCollisionShape::CAPSULE: {
				float radius = (float)cs->get_capsule_radius();
				float half = (float)(cs->get_capsule_height() * 0.5) - radius;
				if (half < 0.0f) {
					half = 0.0f;
				}
				b3CompoundCapsuleDef cd;
				cd.capsule.center1 = to_b3(local.xform(Vector3(0, -half, 0)));
				cd.capsule.center2 = to_b3(local.xform(Vector3(0, half, 0)));
				cd.capsule.radius = radius;
				cd.material = mat;
				capsules.push_back(cd);
			} break;
			case Box3DCollisionShape::CYLINDER:
			case Box3DCollisionShape::CONE: {
				float h = (float)cs->get_capsule_height();
				float r = (float)cs->get_capsule_radius();
				bool cone = cs->get_shape_type() == Box3DCollisionShape::CONE;
				b3HullData *hull = cone ? b3CreateCone(h, r, 0.0f, cs->get_sides())
										: b3CreateCylinder(h, r, -h * 0.5f, cs->get_sides());
				if (hull == nullptr) {
					break;
				}
				owned_hulls.push_back(hull);
				b3CompoundHullDef hd;
				hd.hull = hull;
				hd.transform.p = to_b3(cone ? local.xform(Vector3(0, -h * 0.5f, 0)) : local.origin);
				hd.transform.q = to_b3(local.basis.get_rotation_quaternion());
				hd.material = mat;
				hulls.push_back(hd);
			} break;
			case Box3DCollisionShape::BOX:
			default: {
				Vector3 half = cs->get_box_size() * 0.5;
				boxes.push_back(b3MakeBoxHull((float)half.x, (float)half.y, (float)half.z));
				b3CompoundHullDef hd;
				hd.hull = &boxes.back().base;
				hd.transform = to_b3_transform(local);
				hd.material = mat;
				hulls.push_back(hd);
			} break;
		}
	}
	b3CompoundDef def = {};
	def.spheres = spheres.empty() ? nullptr : spheres.data();
	def.sphereCount = (int)spheres.size();
	def.capsules = capsules.empty() ? nullptr : capsules.data();
	def.capsuleCount = (int)capsules.size();
	def.hulls = hulls.empty() ? nullptr : hulls.data();
	def.hullCount = (int)hulls.size();
	if (compound_data != nullptr) {
		b3DestroyCompound(compound_data);
	}
	compound_data = b3CreateCompound(&def);
	for (b3HullData *hull : owned_hulls) {
		b3DestroyHull(hull);
	}
	if (compound_data == nullptr) {
		return false;
	}
	b3ShapeDef sd = b3DefaultShapeDef();
	sd.enableContactEvents = contact_monitor;
	sd.filter.categoryBits = collision_layer;
	sd.filter.maskBits = collision_mask;
	sd.enableSensorEvents = true;
	sd.enableHitEvents = true;
	b3ShapeId shape = b3CreateBakedCompoundShape(body_id, &sd, compound_data);
	if (B3_IS_NULL(shape)) {
		b3DestroyCompound(compound_data);
		compound_data = nullptr;
		return false;
	}
	return true;
}

// Live body state ---------------------------------------------------------------

int Box3DBody::get_core_body_type() const {
	if (!body_live()) {
		return -1;
	}
	return (int)b3Body_GetType(body_id);
}

bool Box3DBody::is_fast_rotation_allowed() const {
	if (!body_live()) {
		return allow_fast_rotation;
	}
	return b3Body_IsFastRotationAllowed(body_id);
}

bool Box3DBody::is_bullet() const {
	if (!body_live()) {
		return continuous;
	}
	return b3Body_IsBullet(body_id);
}

bool Box3DBody::is_contact_recycling_enabled() const {
	if (!body_live()) {
		return contact_recycling;
	}
	return b3Body_IsContactRecyclingEnabled(body_id);
}

void Box3DBody::enable_hit_events(bool p_enabled) {
	if (body_live()) {
		b3Body_EnableHitEvents(body_id, p_enabled);
	}
}

Vector3 Box3DBody::get_body_position() const {
	if (!body_live()) {
		return get_global_position();
	}
	return to_gd_pos(b3Body_GetPosition(body_id));
}

Quaternion Box3DBody::get_body_rotation() const {
	if (!body_live()) {
		return get_global_basis().get_rotation_quaternion();
	}
	return to_gd(b3Body_GetRotation(body_id));
}

Basis Box3DBody::get_local_rotational_inertia() const {
	if (!body_live()) {
		return Basis(Vector3(), Vector3(), Vector3());
	}
	return matrix_to_basis(b3Body_GetLocalRotationalInertia(body_id));
}

Basis Box3DBody::get_world_inverse_rotational_inertia() const {
	if (!body_live()) {
		return Basis(Vector3(), Vector3(), Vector3());
	}
	return matrix_to_basis(b3Body_GetWorldInverseRotationalInertia(body_id));
}

double Box3DBody::get_min_extent() const {
	if (!body_live()) {
		return 0.0;
	}
	return b3Body_GetMinExtent(body_id);
}

Vector3 Box3DBody::get_max_extent() const {
	if (!body_live()) {
		return Vector3();
	}
	return to_gd(b3Body_GetMaxExtent(body_id));
}

Vector3 Box3DBody::get_max_extent_origin() const {
	if (!body_live()) {
		return Vector3();
	}
	return to_gd(b3Body_GetMaxExtentOrigin(body_id));
}

Dictionary Box3DBody::get_motion_locks() const {
	Dictionary d;
	b3MotionLocks locks;
	if (body_live()) {
		locks = b3Body_GetMotionLocks(body_id);
	} else {
		locks.linearX = lock_linear_x;
		locks.linearY = lock_linear_y;
		locks.linearZ = lock_linear_z;
		locks.angularX = lock_angular_x;
		locks.angularY = lock_angular_y;
		locks.angularZ = lock_angular_z;
	}
	d["linear_x"] = locks.linearX;
	d["linear_y"] = locks.linearY;
	d["linear_z"] = locks.linearZ;
	d["angular_x"] = locks.angularX;
	d["angular_y"] = locks.angularY;
	d["angular_z"] = locks.angularZ;
	return d;
}

Object *Box3DBody::get_box3d_world() const {
	if (world == nullptr || !body_live()) {
		return nullptr;
	}
	b3WorldId id = b3Body_GetWorld(body_id);
	// Sanity check that the core agrees about which world owns this body.
	if (b3StoreWorldId(id) != b3StoreWorldId(world->get_world_id())) {
		return nullptr;
	}
	return world;
}

Array Box3DBody::get_joints() const {
	Array out;
	if (!body_live()) {
		return out;
	}
	int count = b3Body_GetJointCount(body_id);
	if (count <= 0) {
		return out;
	}
	std::vector<b3JointId> joints((size_t)count);
	int got = b3Body_GetJoints(body_id, joints.data(), count);
	for (int i = 0; i < got; ++i) {
		b3JointId j = joints[(size_t)i];
		if (!b3Joint_IsValid(j)) {
			continue;
		}
		Dictionary d;
		d["joint_id"] = (int64_t)b3StoreJointId(j);
		d["type"] = (int)b3Joint_GetType(j);
		b3BodyId a = b3Joint_GetBodyA(j);
		b3BodyId b = b3Joint_GetBodyB(j);
		d["body_a"] = b3Body_IsValid(a) ? static_cast<Box3DBody *>(b3Body_GetUserData(a)) : nullptr;
		d["body_b"] = b3Body_IsValid(b) ? static_cast<Box3DBody *>(b3Body_GetUserData(b)) : nullptr;
		out.push_back(d);
	}
	return out;
}

// Single-body queries ----------------------------------------------------------

Dictionary Box3DBody::cast_ray(const Vector3 &p_from, const Vector3 &p_to, int p_mask) const {
	Dictionary d;
	d["hit"] = false;
	if (!body_live()) {
		return d;
	}
	b3BodyCastResult r = b3Body_CastRay(body_id, to_b3_pos(p_from), to_b3(p_to - p_from),
			make_query_filter(p_mask), 1.0f, b3Body_GetTransform(body_id));
	if (!r.hit) {
		return d;
	}
	d["hit"] = true;
	d["position"] = to_gd_pos(r.point);
	d["normal"] = to_gd(r.normal);
	d["fraction"] = r.fraction;
	d["triangle_index"] = r.triangleIndex;
	d["user_material_id"] = (int64_t)r.userMaterialId;
	d["shape_index"] = shape_index_of(r.shapeId);
	return d;
}

Dictionary Box3DBody::cast_shape(const Vector3 &p_origin, const Dictionary &p_shape, const Vector3 &p_translation,
		bool p_can_encroach, int p_mask) const {
	Dictionary d;
	d["hit"] = false;
	if (!body_live()) {
		return d;
	}
	std::vector<b3Vec3> points;
	b3ShapeProxy proxy;
	dict_to_proxy_points(p_shape, points, proxy.radius);
	proxy.points = points.data();
	proxy.count = (int)points.size();
	b3BodyCastResult r = b3Body_CastShape(body_id, to_b3_pos(p_origin), &proxy, to_b3(p_translation),
			make_query_filter(p_mask), 1.0f, p_can_encroach, b3Body_GetTransform(body_id));
	if (!r.hit) {
		return d;
	}
	d["hit"] = true;
	d["position"] = to_gd_pos(r.point);
	d["normal"] = to_gd(r.normal);
	d["fraction"] = r.fraction;
	d["triangle_index"] = r.triangleIndex;
	d["user_material_id"] = (int64_t)r.userMaterialId;
	d["shape_index"] = shape_index_of(r.shapeId);
	return d;
}

bool Box3DBody::overlap_shape(const Vector3 &p_origin, const Dictionary &p_shape, int p_mask) const {
	if (!body_live()) {
		return false;
	}
	std::vector<b3Vec3> points;
	b3ShapeProxy proxy;
	dict_to_proxy_points(p_shape, points, proxy.radius);
	proxy.points = points.data();
	proxy.count = (int)points.size();
	return b3Body_OverlapShape(body_id, to_b3_pos(p_origin), &proxy, make_query_filter(p_mask),
			b3Body_GetTransform(body_id));
}

Array Box3DBody::collide_mover(const Vector3 &p_origin, const Dictionary &p_capsule, int p_mask) const {
	Array out;
	if (!body_live()) {
		return out;
	}
	int capacity = b3Body_GetShapeCount(body_id);
	if (capacity <= 0) {
		return out;
	}
	b3Capsule mover = dict_to_capsule(p_capsule);
	std::vector<b3BodyPlaneResult> planes((size_t)capacity);
	int count = b3Body_CollideMover(body_id, planes.data(), capacity, to_b3_pos(p_origin), &mover,
			make_query_filter(p_mask), b3Body_GetTransform(body_id));
	for (int i = 0; i < count; ++i) {
		const b3PlaneResult &pr = planes[(size_t)i].result;
		// The core plane is relative to the query origin; shift it to world.
		Vector3 n = to_gd(pr.plane.normal);
		Dictionary d;
		d["plane"] = Plane(n, (real_t)pr.plane.offset + n.dot(p_origin));
		d["point"] = p_origin + to_gd(pr.point);
		d["shape_index"] = shape_index_of(planes[(size_t)i].shapeId);
		d["triangle_index"] = pr.triangleIndex;
		d["child_index"] = pr.childIndex;
		d["material_index"] = pr.materialIndex;
		out.push_back(d);
	}
	return out;
}

Dictionary Box3DBody::time_of_impact_mover(const Vector3 &p_origin, const Dictionary &p_capsule,
		const Vector3 &p_translation, int p_mask) const {
	Dictionary d;
	d["hit"] = false;
	d["fraction"] = 1.0;
	if (!body_live()) {
		return d;
	}
	b3Capsule mover = dict_to_capsule(p_capsule);
	b3WorldTransform xf = b3Body_GetTransform(body_id);
	b3BodyTOIResult r = b3Body_TimeOfImpactMover(body_id, to_b3_pos(p_origin), &mover, to_b3(p_translation),
			make_query_filter(p_mask), xf, xf);
	d["fraction"] = r.fraction;
	if (B3_IS_NULL(r.shapeId) || r.fraction >= 1.0f) {
		return d;
	}
	d["hit"] = true;
	d["position"] = to_gd_pos(r.point);
	d["normal"] = to_gd(r.normal);
	d["shape_index"] = shape_index_of(r.shapeId);
	return d;
}

// Live per-shape access, continued ---------------------------------------------

void Box3DBody::apply_wind(const Vector3 &p_wind, double p_drag, double p_lift, double p_max_speed, bool p_wake) {
	for (b3ShapeId shape : shape_ids()) {
		b3Shape_ApplyWind(shape, to_b3(p_wind), (float)p_drag, (float)p_lift, (float)p_max_speed, p_wake);
	}
}

Dictionary Box3DBody::compute_shape_mass_data(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return d;
	}
	b3MassData md = b3Shape_ComputeMassData(shape);
	d["mass"] = md.mass;
	d["local_center"] = to_gd(md.center);
	d["rotational_inertia"] = matrix_to_basis(md.inertia);
	return d;
}

Dictionary Box3DBody::get_shape_sphere(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_sphereShape) {
		return d;
	}
	b3Sphere sphere = b3Shape_GetSphere(shape);
	d["center"] = to_gd(sphere.center);
	d["radius"] = sphere.radius;
	return d;
}

void Box3DBody::set_shape_sphere(const Dictionary &p_sphere, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	b3Sphere sphere;
	sphere.center = to_b3((Vector3)p_sphere.get("center", Vector3()));
	sphere.radius = (float)(double)p_sphere.get("radius", 0.5);
	b3Shape_SetSphere(shape, &sphere);
}

Dictionary Box3DBody::get_shape_capsule(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_capsuleShape) {
		return d;
	}
	b3Capsule capsule = b3Shape_GetCapsule(shape);
	d["center1"] = to_gd(capsule.center1);
	d["center2"] = to_gd(capsule.center2);
	d["radius"] = capsule.radius;
	return d;
}

void Box3DBody::set_shape_capsule(const Dictionary &p_capsule, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	b3Capsule capsule = dict_to_capsule(p_capsule);
	b3Shape_SetCapsule(shape, &capsule);
}

Dictionary Box3DBody::get_shape_hull(int p_shape_index) const {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_hullShape) {
		return Dictionary();
	}
	return hull_to_dict(b3Shape_GetHull(shape));
}

void Box3DBody::set_shape_hull(const PackedVector3Array &p_points, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || p_points.size() < 4) {
		return;
	}
	std::vector<b3Vec3> points((size_t)p_points.size());
	for (int i = 0; i < p_points.size(); ++i) {
		points[(size_t)i] = to_b3(p_points[i]);
	}
	int max_verts = p_points.size() < B3_MAX_HULL_VERTICES ? (int)p_points.size() : B3_MAX_HULL_VERTICES;
	b3HullData *hull = b3CreateHull(points.data(), (int)points.size(), max_verts);
	if (hull == nullptr) {
		UtilityFunctions::push_warning("Box3DBody.set_shape_hull: could not build a convex hull from the points.");
		return;
	}
	// The world's hull database copies the hull, so it can be released now.
	b3Shape_SetHull(shape, hull);
	b3DestroyHull(hull);
}

Dictionary Box3DBody::get_shape_mesh(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_meshShape) {
		return d;
	}
	b3Mesh mesh = b3Shape_GetMesh(shape);
	d["scale"] = to_gd(mesh.scale);
	if (mesh.data == nullptr) {
		return d;
	}
	PackedVector3Array vertices;
	const b3Vec3 *verts = b3GetMeshVertices(mesh.data);
	for (int i = 0; verts != nullptr && i < mesh.data->vertexCount; ++i) {
		vertices.push_back(to_gd(verts[i]));
	}
	PackedInt32Array indices;
	const b3MeshTriangle *tris = b3GetMeshTriangles(mesh.data);
	for (int i = 0; tris != nullptr && i < mesh.data->triangleCount; ++i) {
		indices.push_back(tris[i].index1);
		indices.push_back(tris[i].index2);
		indices.push_back(tris[i].index3);
	}
	PackedByteArray materials;
	const uint8_t *mats = b3GetMeshMaterialIndices(mesh.data);
	for (int i = 0; mats != nullptr && i < mesh.data->triangleCount; ++i) {
		materials.push_back(mats[i]);
	}
	d["vertices"] = vertices;
	d["indices"] = indices;
	d["triangle_materials"] = materials;
	d["vertex_count"] = mesh.data->vertexCount;
	d["triangle_count"] = mesh.data->triangleCount;
	d["material_count"] = mesh.data->materialCount;
	d["aabb"] = aabb_to_gd(mesh.data->bounds);
	return d;
}

void Box3DBody::set_shape_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices,
		const Vector3 &p_scale, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	if (p_vertices.size() < 3 || p_indices.size() < 3 || (p_indices.size() % 3) != 0) {
		UtilityFunctions::push_warning("Box3DBody.set_shape_mesh: needs >= 3 vertices and a multiple-of-3 index array.");
		return;
	}
	std::vector<b3Vec3> verts((size_t)p_vertices.size());
	for (int i = 0; i < p_vertices.size(); ++i) {
		verts[(size_t)i] = to_b3(p_vertices[i]);
	}
	std::vector<int32_t> idx((size_t)p_indices.size());
	for (int i = 0; i < p_indices.size(); ++i) {
		int32_t v = p_indices[i];
		if (v < 0 || v >= p_vertices.size()) {
			UtilityFunctions::push_warning("Box3DBody.set_shape_mesh: index out of range.");
			return;
		}
		idx[(size_t)i] = v;
	}
	b3MeshDef def = {};
	def.vertices = verts.data();
	def.indices = idx.data();
	def.vertexCount = (int)verts.size();
	def.triangleCount = (int)idx.size() / 3;
	def.weldVertices = true;
	def.weldTolerance = 0.001f;
	def.identifyEdges = true;
	b3MeshData *data = b3CreateMesh(&def, nullptr, 0);
	if (data == nullptr) {
		return;
	}
	// Box3D references the mesh data: owned here until destroy_body().
	extra_mesh_data.push_back(data);
	b3Shape_SetMesh(shape, data, to_b3(p_scale));
}

Dictionary Box3DBody::get_shape_height_field(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_heightShape) {
		return d;
	}
	const b3HeightFieldData *hf = b3Shape_GetHeightField(shape);
	if (hf == nullptr) {
		return d;
	}
	const int count = hf->columnCount * hf->rowCount;
	const int cells = (hf->columnCount - 1) * (hf->rowCount - 1);
	// Heights are stored quantized; decompress back to unscaled sample values.
	PackedFloat32Array heights;
	const uint16_t *compressed = b3GetHeightFieldCompressedHeights(hf);
	for (int i = 0; compressed != nullptr && i < count; ++i) {
		heights.push_back(hf->minHeight + hf->heightScale * (float)compressed[i]);
	}
	PackedByteArray materials;
	const uint8_t *mats = b3GetHeightFieldMaterialIndices(hf);
	for (int i = 0; mats != nullptr && i < cells; ++i) {
		materials.push_back(mats[i]);
	}
	d["count_x"] = hf->columnCount;
	d["count_z"] = hf->rowCount;
	d["scale"] = to_gd(hf->scale);
	d["min_height"] = hf->minHeight;
	d["max_height"] = hf->maxHeight;
	d["heights"] = heights;
	d["materials"] = materials;
	d["aabb"] = aabb_to_gd(hf->aabb);
	d["clockwise"] = hf->clockwise != 0;
	return d;
}

Dictionary Box3DBody::get_shape_compound(int p_shape_index) const {
	Dictionary d;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || b3Shape_GetType(shape) != b3_compoundShape) {
		return d;
	}
	const b3CompoundData *compound = b3Shape_GetCompound(shape);
	if (compound == nullptr) {
		return d;
	}
	d["capsule_count"] = compound->capsuleCount;
	d["hull_count"] = compound->hullCount;
	d["mesh_count"] = compound->meshCount;
	d["sphere_count"] = compound->sphereCount;
	d["aabb"] = aabb_to_gd(compound->bounds);
	Array materials;
	const b3SurfaceMaterial *mats = b3GetCompoundMaterials(compound);
	for (int i = 0; mats != nullptr && i < compound->materialCount; ++i) {
		materials.push_back(material_to_dict(mats[i]));
	}
	d["materials"] = materials;
	// Children in core order (capsules, hulls, meshes, spheres), each with
	// type (b3ShapeType), transform, material_index and its geometry.
	Array children;
	int total = compound->capsuleCount + compound->hullCount + compound->meshCount + compound->sphereCount;
	for (int i = 0; i < total; ++i) {
		b3ChildShape child = b3GetCompoundChild(compound, i);
		Dictionary c;
		c["type"] = (int)child.type;
		c["transform"] = to_gd_transform(child.transform);
		c["material_index"] = (child.materialIndices != nullptr && child.materialCount > 0) ? (int)child.materialIndices[0] : 0;
		switch (child.type) {
			case b3_sphereShape:
				c["center"] = to_gd(child.sphere.center);
				c["radius"] = child.sphere.radius;
				break;
			case b3_capsuleShape:
				c["center1"] = to_gd(child.capsule.center1);
				c["center2"] = to_gd(child.capsule.center2);
				c["radius"] = child.capsule.radius;
				break;
			case b3_hullShape:
				c["hull"] = hull_to_dict(child.hull);
				break;
			case b3_meshShape:
				c["scale"] = to_gd(child.mesh.scale);
				c["triangle_count"] = child.mesh.data != nullptr ? child.mesh.data->triangleCount : 0;
				break;
			default:
				break;
		}
		children.push_back(c);
	}
	d["children"] = children;
	return d;
}

int Box3DBody::get_shape_mesh_material_count(int p_shape_index) const {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return 0;
	}
	return b3Shape_GetMeshMaterialCount(shape);
}

Dictionary Box3DBody::get_shape_mesh_material(int p_material_index, int p_shape_index) const {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || p_material_index < 0 || p_material_index >= b3Shape_GetMeshMaterialCount(shape)) {
		return Dictionary();
	}
	return material_to_dict(b3Shape_GetMeshSurfaceMaterial(shape, p_material_index));
}

void Box3DBody::set_shape_mesh_material(const Dictionary &p_material, int p_material_index, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || p_material_index < 0 || p_material_index >= b3Shape_GetMeshMaterialCount(shape)) {
		return;
	}
	b3SurfaceMaterial mat = b3Shape_GetMeshSurfaceMaterial(shape, p_material_index);
	dict_to_material(p_material, mat);
	b3Shape_SetMeshMaterial(shape, mat, p_material_index);
}

void Box3DBody::set_shape_name(const String &p_name, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	CharString utf8 = p_name.utf8();
	b3Shape_SetName(shape, p_name.is_empty() ? nullptr : utf8.get_data());
}

String Box3DBody::get_shape_name(int p_shape_index) const {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return String();
	}
	const char *name = b3Shape_GetName(shape);
	return name != nullptr ? String::utf8(name) : String();
}

void Box3DBody::set_shape_user_data(int64_t p_value, int p_shape_index) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	b3Shape_SetUserData(shape, (void *)(intptr_t)p_value);
}

int64_t Box3DBody::get_shape_user_data(int p_shape_index) const {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return 0;
	}
	return (int64_t)(intptr_t)b3Shape_GetUserData(shape);
}

Array Box3DBody::get_shape_contact_data(int p_shape_index) const {
	Array out;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return out;
	}
	int capacity = b3Shape_GetContactCapacity(shape);
	if (capacity <= 0) {
		return out;
	}
	std::vector<b3ContactData> contacts((size_t)capacity);
	int count = b3Shape_GetContactData(shape, contacts.data(), capacity);
	for (int i = 0; i < count; ++i) {
		out.push_back(contact_to_dict(contacts[(size_t)i]));
	}
	return out;
}

Array Box3DBody::get_shape_sensor_overlaps(int p_shape_index) const {
	Array out;
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape) || world == nullptr) {
		return out;
	}
	int capacity = b3Shape_GetSensorCapacity(shape);
	if (capacity <= 0) {
		return out;
	}
	std::vector<b3ShapeId> visitors((size_t)capacity);
	int count = b3Shape_GetSensorData(shape, visitors.data(), capacity);
	for (int i = 0; i < count; ++i) {
		// body_from_shape validates the id (overlaps may hold destroyed shapes).
		Box3DBody *body = world->body_from_shape(visitors[(size_t)i]);
		if (body != nullptr && !out.has(body)) {
			out.push_back(body);
		}
	}
	return out;
}

void Box3DBody::destroy_shape(int p_shape_index, bool p_update_mass) {
	b3ShapeId shape = shape_at(p_shape_index);
	if (B3_IS_NULL(shape)) {
		return;
	}
	b3DestroyShape(shape, p_update_mass);
	debug_mass = b3Body_GetMass(body_id);
}

bool Box3DBody::is_contact_valid(const Vector3i &p_contact_id) const {
	if (world != nullptr) {
		world->join_async_step();
	}
	if (!world || !world->is_world_alive()) {
		return false;
	}
	return b3Contact_IsValid(contact_id_to_b3(p_contact_id));
}

Dictionary Box3DBody::get_contact(const Vector3i &p_contact_id) const {
	if (!is_contact_valid(p_contact_id)) {
		return Dictionary();
	}
	return contact_to_dict(b3Contact_GetData(contact_id_to_b3(p_contact_id)));
}

void Box3DBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("apply_central_force", "force"), &Box3DBody::apply_central_force);
	ClassDB::bind_method(D_METHOD("apply_central_impulse", "impulse"), &Box3DBody::apply_central_impulse);
	ClassDB::bind_method(D_METHOD("apply_torque", "torque"), &Box3DBody::apply_torque);
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "velocity"), &Box3DBody::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_linear_velocity"), &Box3DBody::get_linear_velocity);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "velocity"), &Box3DBody::set_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_angular_velocity"), &Box3DBody::get_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_mass"), &Box3DBody::get_mass);
	ClassDB::bind_method(D_METHOD("teleport", "transform"), &Box3DBody::teleport);

	ClassDB::bind_method(D_METHOD("set_body_type", "type"), &Box3DBody::set_body_type);
	ClassDB::bind_method(D_METHOD("get_body_type"), &Box3DBody::get_body_type);
	ClassDB::bind_method(D_METHOD("set_shape_type", "type"), &Box3DBody::set_shape_type);
	ClassDB::bind_method(D_METHOD("get_shape_type"), &Box3DBody::get_shape_type);
	ClassDB::bind_method(D_METHOD("set_box_size", "size"), &Box3DBody::set_box_size);
	ClassDB::bind_method(D_METHOD("get_box_size"), &Box3DBody::get_box_size);
	ClassDB::bind_method(D_METHOD("set_sphere_radius", "radius"), &Box3DBody::set_sphere_radius);
	ClassDB::bind_method(D_METHOD("get_sphere_radius"), &Box3DBody::get_sphere_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_radius", "radius"), &Box3DBody::set_capsule_radius);
	ClassDB::bind_method(D_METHOD("get_capsule_radius"), &Box3DBody::get_capsule_radius);
	ClassDB::bind_method(D_METHOD("set_capsule_height", "height"), &Box3DBody::set_capsule_height);
	ClassDB::bind_method(D_METHOD("get_capsule_height"), &Box3DBody::get_capsule_height);
	ClassDB::bind_method(D_METHOD("set_cylinder_sides", "sides"), &Box3DBody::set_cylinder_sides);
	ClassDB::bind_method(D_METHOD("get_cylinder_sides"), &Box3DBody::get_cylinder_sides);
	ClassDB::bind_method(D_METHOD("set_collision_mesh", "mesh"), &Box3DBody::set_collision_mesh);
	ClassDB::bind_method(D_METHOD("get_collision_mesh"), &Box3DBody::get_collision_mesh);
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Box3DBody::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Box3DBody::get_density);
	ClassDB::bind_method(D_METHOD("set_friction", "friction"), &Box3DBody::set_friction);
	ClassDB::bind_method(D_METHOD("get_friction"), &Box3DBody::get_friction);
	ClassDB::bind_method(D_METHOD("set_restitution", "restitution"), &Box3DBody::set_restitution);
	ClassDB::bind_method(D_METHOD("get_restitution"), &Box3DBody::get_restitution);
	ClassDB::bind_method(D_METHOD("set_linear_damping", "damping"), &Box3DBody::set_linear_damping);
	ClassDB::bind_method(D_METHOD("get_linear_damping"), &Box3DBody::get_linear_damping);
	ClassDB::bind_method(D_METHOD("set_angular_damping", "damping"), &Box3DBody::set_angular_damping);
	ClassDB::bind_method(D_METHOD("get_angular_damping"), &Box3DBody::get_angular_damping);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "scale"), &Box3DBody::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"), &Box3DBody::get_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_contact_monitor", "enabled"), &Box3DBody::set_contact_monitor);
	ClassDB::bind_method(D_METHOD("get_contact_monitor"), &Box3DBody::get_contact_monitor);
	ClassDB::bind_method(D_METHOD("set_is_sensor", "sensor"), &Box3DBody::set_is_sensor);
	ClassDB::bind_method(D_METHOD("get_is_sensor"), &Box3DBody::get_is_sensor);
	ClassDB::bind_method(D_METHOD("set_debug_visualize", "enabled"), &Box3DBody::set_debug_visualize);
	ClassDB::bind_method(D_METHOD("get_debug_visualize"), &Box3DBody::get_debug_visualize);
	ClassDB::bind_method(D_METHOD("set_continuous", "enabled"), &Box3DBody::set_continuous);
	ClassDB::bind_method(D_METHOD("set_contact_recycling", "enabled"), &Box3DBody::set_contact_recycling);
	ClassDB::bind_method(D_METHOD("get_contact_recycling"), &Box3DBody::get_contact_recycling);
	ClassDB::bind_method(D_METHOD("set_sync_node_transform", "enabled"), &Box3DBody::set_sync_node_transform);
	ClassDB::bind_method(D_METHOD("get_sync_node_transform"), &Box3DBody::get_sync_node_transform);
	ClassDB::bind_method(D_METHOD("get_continuous"), &Box3DBody::get_continuous);
	ClassDB::bind_method(D_METHOD("set_allow_fast_rotation", "enabled"), &Box3DBody::set_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("get_allow_fast_rotation"), &Box3DBody::get_allow_fast_rotation);
	ClassDB::bind_method(D_METHOD("set_lock_linear_x", "enabled"), &Box3DBody::set_lock_linear_x);
	ClassDB::bind_method(D_METHOD("get_lock_linear_x"), &Box3DBody::get_lock_linear_x);
	ClassDB::bind_method(D_METHOD("set_lock_linear_y", "enabled"), &Box3DBody::set_lock_linear_y);
	ClassDB::bind_method(D_METHOD("get_lock_linear_y"), &Box3DBody::get_lock_linear_y);
	ClassDB::bind_method(D_METHOD("set_lock_linear_z", "enabled"), &Box3DBody::set_lock_linear_z);
	ClassDB::bind_method(D_METHOD("get_lock_linear_z"), &Box3DBody::get_lock_linear_z);
	ClassDB::bind_method(D_METHOD("set_lock_angular_x", "enabled"), &Box3DBody::set_lock_angular_x);
	ClassDB::bind_method(D_METHOD("get_lock_angular_x"), &Box3DBody::get_lock_angular_x);
	ClassDB::bind_method(D_METHOD("set_lock_angular_y", "enabled"), &Box3DBody::set_lock_angular_y);
	ClassDB::bind_method(D_METHOD("get_lock_angular_y"), &Box3DBody::get_lock_angular_y);
	ClassDB::bind_method(D_METHOD("set_lock_angular_z", "enabled"), &Box3DBody::set_lock_angular_z);
	ClassDB::bind_method(D_METHOD("get_lock_angular_z"), &Box3DBody::get_lock_angular_z);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Box3DBody::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Box3DBody::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Box3DBody::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Box3DBody::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_auto_visual", "enabled"), &Box3DBody::set_auto_visual);
	ClassDB::bind_method(D_METHOD("get_auto_visual"), &Box3DBody::get_auto_visual);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "body_type", PROPERTY_HINT_ENUM, "Static,Kinematic,Dynamic"), "set_body_type", "get_body_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_type", PROPERTY_HINT_ENUM, "Box,Sphere,Capsule,Cylinder,Cone,Hull,Mesh,Fit Mesh,Height Field"), "set_shape_type", "get_shape_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "box_size"), "set_box_size", "get_box_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sphere_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_sphere_radius", "get_sphere_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_radius", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_capsule_radius", "get_capsule_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "capsule_height", PROPERTY_HINT_RANGE, "0.02,100,0.01,or_greater"), "set_capsule_height", "get_capsule_height");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cylinder_sides", PROPERTY_HINT_RANGE, "3,64,1"), "set_cylinder_sides", "get_cylinder_sides");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_collision_mesh", "get_collision_mesh");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_visual"), "set_auto_visual", "get_auto_visual");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, "0.01,100,0.01,or_greater"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "friction", PROPERTY_HINT_RANGE, "0,1,0.01,or_greater"), "set_friction", "get_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_restitution", "get_restitution");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "linear_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_linear_damping", "get_linear_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "angular_damping", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_angular_damping", "get_angular_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale", PROPERTY_HINT_RANGE, "-10,10,0.01"), "set_gravity_scale", "get_gravity_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_monitor"), "set_contact_monitor", "get_contact_monitor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_sensor"), "set_is_sensor", "get_is_sensor");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_visualize"), "set_debug_visualize", "get_debug_visualize");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous"), "set_continuous", "get_continuous");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_recycling"), "set_contact_recycling", "get_contact_recycling");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sync_node_transform"), "set_sync_node_transform", "get_sync_node_transform");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_fast_rotation"), "set_allow_fast_rotation", "get_allow_fast_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");

	ADD_GROUP("Axis Lock", "lock_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_x"), "set_lock_linear_x", "get_lock_linear_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_y"), "set_lock_linear_y", "get_lock_linear_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_linear_z"), "set_lock_linear_z", "get_lock_linear_z");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_x"), "set_lock_angular_x", "get_lock_angular_x");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_y"), "set_lock_angular_y", "get_lock_angular_y");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lock_angular_z"), "set_lock_angular_z", "get_lock_angular_z");

	// --- Extended core access -------------------------------------------------
	ClassDB::bind_method(D_METHOD("apply_force", "force", "world_point"), &Box3DBody::apply_force);
	ClassDB::bind_method(D_METHOD("apply_impulse", "impulse", "world_point"), &Box3DBody::apply_impulse);
	ClassDB::bind_method(D_METHOD("apply_angular_impulse", "impulse"), &Box3DBody::apply_angular_impulse);
	ClassDB::bind_method(D_METHOD("get_point_velocity", "world_point"), &Box3DBody::get_point_velocity);
	ClassDB::bind_method(D_METHOD("get_center_of_mass"), &Box3DBody::get_center_of_mass);
	ClassDB::bind_method(D_METHOD("get_inverse_mass"), &Box3DBody::get_inverse_mass);
	ClassDB::bind_method(D_METHOD("get_mass_data"), &Box3DBody::get_mass_data);
	ClassDB::bind_method(D_METHOD("set_mass_data", "mass", "local_center"), &Box3DBody::set_mass_data);
	ClassDB::bind_method(D_METHOD("reset_mass"), &Box3DBody::reset_mass);
	ClassDB::bind_method(D_METHOD("set_sleep_threshold", "speed"), &Box3DBody::set_sleep_threshold);
	ClassDB::bind_method(D_METHOD("get_sleep_threshold"), &Box3DBody::get_sleep_threshold);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Box3DBody::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Box3DBody::is_enabled);
	ClassDB::bind_method(D_METHOD("wake"), &Box3DBody::wake);
	ClassDB::bind_method(D_METHOD("is_awake"), &Box3DBody::is_awake);
	ClassDB::bind_method(D_METHOD("get_closest_point", "target"), &Box3DBody::get_closest_point);
	ClassDB::bind_method(D_METHOD("get_contact_data"), &Box3DBody::get_contact_data);

	// --- Extended core access II: transforms, introspection, live shapes ------
	ClassDB::bind_method(D_METHOD("to_local_point", "world_point"), &Box3DBody::to_local_point);
	ClassDB::bind_method(D_METHOD("to_world_point", "local_point"), &Box3DBody::to_world_point);
	ClassDB::bind_method(D_METHOD("to_local_vector", "world_vector"), &Box3DBody::to_local_vector);
	ClassDB::bind_method(D_METHOD("to_world_vector", "local_vector"), &Box3DBody::to_world_vector);
	ClassDB::bind_method(D_METHOD("get_local_point_velocity", "local_point"), &Box3DBody::get_local_point_velocity);
	ClassDB::bind_method(D_METHOD("get_local_center"), &Box3DBody::get_local_center);
	ClassDB::bind_method(D_METHOD("get_aabb"), &Box3DBody::get_aabb);
	ClassDB::bind_method(D_METHOD("get_shape_count"), &Box3DBody::get_shape_count);
	ClassDB::bind_method(D_METHOD("get_joint_count"), &Box3DBody::get_joint_count);
	ClassDB::bind_method(D_METHOD("set_shape_friction", "friction"), &Box3DBody::set_shape_friction);
	ClassDB::bind_method(D_METHOD("get_shape_friction", "shape_index"), &Box3DBody::get_shape_friction, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_restitution", "restitution"), &Box3DBody::set_shape_restitution);
	ClassDB::bind_method(D_METHOD("get_shape_restitution", "shape_index"), &Box3DBody::get_shape_restitution, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_density", "density", "update_mass"), &Box3DBody::set_shape_density, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("get_shape_density", "shape_index"), &Box3DBody::get_shape_density, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_filter", "category", "mask", "group"), &Box3DBody::set_shape_filter, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_filter", "shape_index"), &Box3DBody::get_shape_filter, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_surface_material", "material"), &Box3DBody::set_shape_surface_material);
	ClassDB::bind_method(D_METHOD("get_shape_surface_material", "shape_index"), &Box3DBody::get_shape_surface_material, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("enable_shape_contact_events", "enabled"), &Box3DBody::enable_shape_contact_events);
	ClassDB::bind_method(D_METHOD("are_shape_contact_events_enabled", "shape_index"), &Box3DBody::are_shape_contact_events_enabled, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("enable_shape_hit_events", "enabled"), &Box3DBody::enable_shape_hit_events);
	ClassDB::bind_method(D_METHOD("are_shape_hit_events_enabled", "shape_index"), &Box3DBody::are_shape_hit_events_enabled, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("enable_shape_sensor_events", "enabled"), &Box3DBody::enable_shape_sensor_events);
	ClassDB::bind_method(D_METHOD("are_shape_sensor_events_enabled", "shape_index"), &Box3DBody::are_shape_sensor_events_enabled, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("enable_shape_presolve_events", "enabled"), &Box3DBody::enable_shape_presolve_events);
	ClassDB::bind_method(D_METHOD("are_shape_presolve_events_enabled", "shape_index"), &Box3DBody::are_shape_presolve_events_enabled, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_shape_sensor", "shape_index"), &Box3DBody::is_shape_sensor, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_core_type", "shape_index"), &Box3DBody::get_shape_core_type, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_aabb", "shape_index"), &Box3DBody::get_shape_aabb, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_closest_point", "target", "shape_index"), &Box3DBody::get_shape_closest_point, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("shape_raycast", "from", "to", "shape_index"), &Box3DBody::shape_raycast, DEFVAL(0));

	// --- Extended core access III: full body/shape/contact API -----------------
	ClassDB::bind_method(D_METHOD("set_sleep_enabled", "enabled"), &Box3DBody::set_sleep_enabled);
	ClassDB::bind_method(D_METHOD("is_sleep_enabled"), &Box3DBody::is_sleep_enabled);
	ClassDB::bind_method(D_METHOD("set_safety_factor", "factor"), &Box3DBody::set_safety_factor);
	ClassDB::bind_method(D_METHOD("get_safety_factor"), &Box3DBody::get_safety_factor);
	ClassDB::bind_method(D_METHOD("set_body_name", "name"), &Box3DBody::set_body_name);
	ClassDB::bind_method(D_METHOD("get_body_name"), &Box3DBody::get_body_name);
	ClassDB::bind_method(D_METHOD("set_bake_compound", "enabled"), &Box3DBody::set_bake_compound);
	ClassDB::bind_method(D_METHOD("get_bake_compound"), &Box3DBody::get_bake_compound);
	ClassDB::bind_method(D_METHOD("set_heightfield_heights", "heights"), &Box3DBody::set_heightfield_heights);
	ClassDB::bind_method(D_METHOD("get_heightfield_heights"), &Box3DBody::get_heightfield_heights);
	ClassDB::bind_method(D_METHOD("set_heightfield_count_x", "count"), &Box3DBody::set_heightfield_count_x);
	ClassDB::bind_method(D_METHOD("get_heightfield_count_x"), &Box3DBody::get_heightfield_count_x);
	ClassDB::bind_method(D_METHOD("set_heightfield_count_z", "count"), &Box3DBody::set_heightfield_count_z);
	ClassDB::bind_method(D_METHOD("get_heightfield_count_z"), &Box3DBody::get_heightfield_count_z);
	ClassDB::bind_method(D_METHOD("set_heightfield_scale", "scale"), &Box3DBody::set_heightfield_scale);
	ClassDB::bind_method(D_METHOD("get_heightfield_scale"), &Box3DBody::get_heightfield_scale);
	ClassDB::bind_method(D_METHOD("set_heightfield_materials", "materials"), &Box3DBody::set_heightfield_materials);
	ClassDB::bind_method(D_METHOD("get_heightfield_materials"), &Box3DBody::get_heightfield_materials);

	ClassDB::bind_method(D_METHOD("get_core_body_type"), &Box3DBody::get_core_body_type);
	ClassDB::bind_method(D_METHOD("is_fast_rotation_allowed"), &Box3DBody::is_fast_rotation_allowed);
	ClassDB::bind_method(D_METHOD("is_bullet"), &Box3DBody::is_bullet);
	ClassDB::bind_method(D_METHOD("is_contact_recycling_enabled"), &Box3DBody::is_contact_recycling_enabled);
	ClassDB::bind_method(D_METHOD("enable_hit_events", "enabled"), &Box3DBody::enable_hit_events);
	ClassDB::bind_method(D_METHOD("get_body_position"), &Box3DBody::get_body_position);
	ClassDB::bind_method(D_METHOD("get_body_rotation"), &Box3DBody::get_body_rotation);
	ClassDB::bind_method(D_METHOD("get_local_rotational_inertia"), &Box3DBody::get_local_rotational_inertia);
	ClassDB::bind_method(D_METHOD("get_world_inverse_rotational_inertia"), &Box3DBody::get_world_inverse_rotational_inertia);
	ClassDB::bind_method(D_METHOD("get_min_extent"), &Box3DBody::get_min_extent);
	ClassDB::bind_method(D_METHOD("get_max_extent"), &Box3DBody::get_max_extent);
	ClassDB::bind_method(D_METHOD("get_max_extent_origin"), &Box3DBody::get_max_extent_origin);
	ClassDB::bind_method(D_METHOD("get_motion_locks"), &Box3DBody::get_motion_locks);
	ClassDB::bind_method(D_METHOD("get_box3d_world"), &Box3DBody::get_box3d_world);
	ClassDB::bind_method(D_METHOD("get_joints"), &Box3DBody::get_joints);

	ClassDB::bind_method(D_METHOD("cast_ray", "from", "to", "mask"), &Box3DBody::cast_ray, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("cast_shape", "origin", "shape", "translation", "can_encroach", "mask"), &Box3DBody::cast_shape, DEFVAL(false), DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("overlap_shape", "origin", "shape", "mask"), &Box3DBody::overlap_shape, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("collide_mover", "origin", "capsule", "mask"), &Box3DBody::collide_mover, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("time_of_impact_mover", "origin", "capsule", "translation", "mask"), &Box3DBody::time_of_impact_mover, DEFVAL(-1));

	ClassDB::bind_method(D_METHOD("apply_wind", "wind", "drag", "lift", "max_speed", "wake"), &Box3DBody::apply_wind, DEFVAL(10.0), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("compute_shape_mass_data", "shape_index"), &Box3DBody::compute_shape_mass_data, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_sphere", "shape_index"), &Box3DBody::get_shape_sphere, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_sphere", "sphere", "shape_index"), &Box3DBody::set_shape_sphere, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_capsule", "shape_index"), &Box3DBody::get_shape_capsule, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_capsule", "capsule", "shape_index"), &Box3DBody::set_shape_capsule, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_hull", "shape_index"), &Box3DBody::get_shape_hull, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_hull", "points", "shape_index"), &Box3DBody::set_shape_hull, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_mesh", "shape_index"), &Box3DBody::get_shape_mesh, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_mesh", "vertices", "indices", "scale", "shape_index"), &Box3DBody::set_shape_mesh, DEFVAL(Vector3(1, 1, 1)), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_height_field", "shape_index"), &Box3DBody::get_shape_height_field, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_compound", "shape_index"), &Box3DBody::get_shape_compound, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_mesh_material_count", "shape_index"), &Box3DBody::get_shape_mesh_material_count, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_mesh_material", "material_index", "shape_index"), &Box3DBody::get_shape_mesh_material, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_mesh_material", "material", "material_index", "shape_index"), &Box3DBody::set_shape_mesh_material, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_name", "name", "shape_index"), &Box3DBody::set_shape_name, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_name", "shape_index"), &Box3DBody::get_shape_name, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_shape_user_data", "value", "shape_index"), &Box3DBody::set_shape_user_data, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_user_data", "shape_index"), &Box3DBody::get_shape_user_data, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_contact_data", "shape_index"), &Box3DBody::get_shape_contact_data, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_shape_sensor_overlaps", "shape_index"), &Box3DBody::get_shape_sensor_overlaps, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("destroy_shape", "shape_index", "update_mass"), &Box3DBody::destroy_shape, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("is_contact_valid", "contact_id"), &Box3DBody::is_contact_valid);
	ClassDB::bind_method(D_METHOD("get_contact", "contact_id"), &Box3DBody::get_contact);

	ADD_GROUP("", ""); // end the Axis Lock group
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sleep_enabled"), "set_sleep_enabled", "is_sleep_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "safety_factor", PROPERTY_HINT_RANGE, "0.01,1,0.01"), "set_safety_factor", "get_safety_factor");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "body_name"), "set_body_name", "get_body_name");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "bake_compound"), "set_bake_compound", "get_bake_compound");
	ADD_GROUP("Height Field", "heightfield_");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "heightfield_heights"), "set_heightfield_heights", "get_heightfield_heights");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "heightfield_count_x", PROPERTY_HINT_RANGE, "0,4096,1,or_greater"), "set_heightfield_count_x", "get_heightfield_count_x");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "heightfield_count_z", PROPERTY_HINT_RANGE, "0,4096,1,or_greater"), "set_heightfield_count_z", "get_heightfield_count_z");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "heightfield_scale"), "set_heightfield_scale", "get_heightfield_scale");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "heightfield_materials"), "set_heightfield_materials", "get_heightfield_materials");

	ADD_SIGNAL(MethodInfo("body_entered", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("body_exited", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("body_hit", PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody"),
			PropertyInfo(Variant::VECTOR3, "point"), PropertyInfo(Variant::VECTOR3, "normal"),
			PropertyInfo(Variant::FLOAT, "approach_speed")));
	ADD_SIGNAL(MethodInfo("area_entered", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));
	ADD_SIGNAL(MethodInfo("area_exited", PropertyInfo(Variant::OBJECT, "visitor", PROPERTY_HINT_RESOURCE_TYPE, "Box3DBody")));

	BIND_ENUM_CONSTANT(STATIC);
	BIND_ENUM_CONSTANT(KINEMATIC);
	BIND_ENUM_CONSTANT(DYNAMIC);
	BIND_ENUM_CONSTANT(BOX);
	BIND_ENUM_CONSTANT(SPHERE);
	BIND_ENUM_CONSTANT(CAPSULE);
	BIND_ENUM_CONSTANT(CYLINDER);
	BIND_ENUM_CONSTANT(CONE);
	BIND_ENUM_CONSTANT(HULL);
	BIND_ENUM_CONSTANT(MESH);
	BIND_ENUM_CONSTANT(FIT_MESH);
	BIND_ENUM_CONSTANT(HEIGHTFIELD);
}
