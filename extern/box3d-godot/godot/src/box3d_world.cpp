// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#include "box3d_world.h"

#include "box3d_body.h"
#include "box3d_collision_shape.h"
#include "box3d_conversions.h"
#include "box3d_joint.h"

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/cylinder_mesh.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cmath>
#include <godot_cpp/core/math.hpp>

// Upstream erincatto/box3d (79fc559, "Optimizations #168") dropped
// b3World_RebuildStaticTree from the public header and kept it as an internal
// testing hook in src/physics_world.h. The engine is compiled into this same
// library, so declare it here rather than pulling in the internal C header.
extern "C" void b3World_RebuildStaticTree(b3WorldId worldId);

using namespace godot;

// Forward declarations of the Extended core access III C callbacks (defined
// further down) that ensure_world() installs on every world it creates.
namespace {
void *debug_shape_create_cb(const b3DebugShape *p_shape, void *p_context);
void debug_shape_destroy_cb(void *p_user_shape, void *p_context);
bool world_custom_filter_cb(b3ShapeId p_a, b3ShapeId p_b, void *p_context);
bool world_presolve_cb(b3ShapeId p_a, b3ShapeId p_b, b3Pos p_point, b3Vec3 p_normal, void *p_context);
} // namespace

Box3DWorld::Box3DWorld() {}

Box3DWorld::~Box3DWorld() {
	stop_step_thread();
	if (recording != nullptr) {
		if (b3World_IsValid(world_id)) {
			b3World_StopRecording(world_id);
		}
		b3DestroyRecording(recording);
		recording = nullptr;
	}
	if (b3World_IsValid(world_id)) {
		b3DestroyWorld(world_id);
		world_id = b3_nullWorldId;
	}
}

void Box3DWorld::async_thread_main() {
	std::unique_lock<std::mutex> lock(step_mutex);
	while (true) {
		step_cv.wait(lock, [this] { return worker_busy || worker_exit; });
		if (worker_exit) {
			break;
		}
		double dt = worker_dt;
		int substeps = worker_substeps;
		b3WorldId id = world_id; // stable: destruction joins this thread first
		lock.unlock();
		b3World_Step(id, (float)dt, substeps);
		lock.lock();
		worker_busy = false;
		step_cv.notify_all();
	}
}

void Box3DWorld::launch_async_step(double p_delta) {
	if (!step_thread.joinable()) {
		step_thread = std::thread(&Box3DWorld::async_thread_main, this);
	}
	{
		std::lock_guard<std::mutex> lock(step_mutex);
		worker_dt = p_delta;
		worker_substeps = substep_count;
		worker_busy = true;
		step_inflight.store(true, std::memory_order_release);
	}
	step_cv.notify_all();
}

void Box3DWorld::join_async_step() const {
	if (!step_inflight.load(std::memory_order_acquire)) {
		return;
	}
	{
		std::unique_lock<std::mutex> lock(step_mutex);
		step_cv.wait(lock, [this] { return !worker_busy; });
	}
	step_inflight.store(false, std::memory_order_release);
	step_pending_apply = true;
}

void Box3DWorld::apply_step_results() {
	step_pending_apply = false;
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_from_physics();
			body->debug_hit_decay();
		}
	}
	dispatch_contact_events();
	dispatch_sensor_events();
	dispatch_joint_events();
	// Async mode refreshes the debug shells here: we are post-join, and apply
	// runs at most once per physics frame so it cannot catch-up-spiral like
	// the old per-tick update in the synchronous path could.
	if (debug_draw) {
		update_debug_draw();
	}
}

void Box3DWorld::stop_step_thread() {
	if (!step_thread.joinable()) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(step_mutex);
		worker_exit = true;
	}
	step_cv.notify_all();
	step_thread.join();
	worker_exit = false;
	step_inflight.store(false, std::memory_order_release);
	step_pending_apply = false;
}

void Box3DWorld::ensure_world() {
	if (b3World_IsValid(world_id)) {
		return;
	}
	b3WorldDef def = b3DefaultWorldDef();
	def.gravity = to_b3(gravity);
	def.enableContinuous = continuous_collision;
	if (max_linear_speed > 0.0) {
		def.maximumLinearSpeed = (float)max_linear_speed;
	}
	// >1 turns on Box3D's internal multithreaded scheduler (no task callbacks
	// needed). Applied at world creation.
	def.workerCount = (uint32_t)(worker_count < 1 ? 1 : worker_count);
	def.enableSleep = enable_sleep;
	// Extended core access III: def-time knobs, the node back-pointer as world
	// user data, and debug-shape hooks so b3World_Draw reports shapes (see
	// get_debug_draw_data). The hooks only run inside b3World_Draw / shape
	// destruction, so worlds that never draw pay nothing.
	def.restitutionIterations = restitution_iterations;
	def.enableRestitutionPropagation = enable_restitution_propagation;
	def.isotropicInertiaTolerance = (float)isotropic_inertia_tolerance;
	def.userData = this;
	def.createDebugShape = debug_shape_create_cb;
	def.destroyDebugShape = debug_shape_destroy_cb;
	def.userDebugShapeContext = this;
	world_id = b3CreateWorld(&def);
	apply_contact_tuning();
	b3World_EnableWarmStarting(world_id, enable_warm_starting);
	// Extended solver knobs cached before the world existed.
	b3World_EnableSpeculative(world_id, enable_speculative);
	if (restitution_threshold >= 0.0) {
		b3World_SetRestitutionThreshold(world_id, (float)restitution_threshold);
	}
	if (hit_event_threshold >= 0.0) {
		b3World_SetHitEventThreshold(world_id, (float)hit_event_threshold);
	}
	if (contact_recycle_distance >= 0.0) {
		b3World_SetContactRecycleDistance(world_id, (float)contact_recycle_distance);
	}
	if (enable_sse2_fallback) {
		b3World_EnableSSE2Fallback(world_id, true);
	}
	apply_mix_callbacks();
	// Always installed: they are no-ops until rules exist, and the continuous
	// solver calls the pre-solve hook WITHOUT a null check whenever a shape has
	// pre-solve events enabled, so a registered hook also keeps that path safe.
	b3World_SetCustomFilterCallback(world_id, world_custom_filter_cb, this);
	b3World_SetPreSolveCallback(world_id, world_presolve_cb, this);
}

void Box3DWorld::apply_contact_tuning() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	join_async_step();
	// contactSpeed left at Box3D's own default (3 m/s at this binding's fixed
	// 1-length-unit-per-meter scale); only stiffness/damping are exposed.
	b3World_SetContactTuning(world_id, (float)contact_hertz, (float)contact_damping, 3.0f);
}

b3WorldId Box3DWorld::get_world_id() {
	ensure_world();
	join_async_step();
	return world_id;
}

bool Box3DWorld::is_world_alive() const {
	join_async_step();
	return b3World_IsValid(world_id);
}

void Box3DWorld::register_body(Box3DBody *p_body) {
	if (p_body == nullptr) {
		return;
	}
	bodies.push_back(p_body);
}

void Box3DWorld::unregister_body(Box3DBody *p_body) {
	for (size_t i = 0; i < bodies.size(); ++i) {
		if (bodies[i] == p_body) {
			bodies.erase(bodies.begin() + i);
			return;
		}
	}
}

void Box3DWorld::step(double p_delta) {
	ensure_world();
	if (!b3World_IsValid(world_id) || p_delta <= 0.0) {
		return;
	}
	if (async_step) {
		if (step_inflight.load(std::memory_order_acquire)) {
			{
				std::lock_guard<std::mutex> lock(step_mutex);
				if (worker_busy) {
					// The previous step is still solving: skip this tick so
					// rendering stays smooth (the sim lags rather than stalls).
					return;
				}
			}
			step_inflight.store(false, std::memory_order_release);
			step_pending_apply = true;
		}
		if (step_pending_apply) {
			apply_step_results();
		}
		// Push user-driven (kinematic) transforms into the solver.
		for (Box3DBody *body : bodies) {
			if (body != nullptr) {
				body->sync_to_physics(p_delta);
			}
		}
		purge_stale_filter_bodies();
		last_step_delta = p_delta;
		launch_async_step(p_delta);
		return;
	}
	// Synchronous path. Settle any leftover async state first (async_step may
	// have just been toggled off with a step still in flight).
	join_async_step();
	if (step_pending_apply) {
		apply_step_results();
	}
	// Push user-driven (kinematic) transforms into the solver.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_to_physics(p_delta);
		}
	}
	purge_stale_filter_bodies();
	last_step_delta = p_delta;
	b3World_Step(world_id, (float)p_delta, substep_count);
	// Read simulated (dynamic) transforms back out to the nodes.
	for (Box3DBody *body : bodies) {
		if (body != nullptr) {
			body->sync_from_physics();
			body->debug_hit_decay();
		}
	}
	dispatch_contact_events();
	dispatch_sensor_events();
	dispatch_joint_events();
	debug_step_dirty = true; // the shells refresh from NOTIFICATION_PROCESS
}

Box3DBody *Box3DWorld::body_from_shape(b3ShapeId p_shape) {
	if (!b3Shape_IsValid(p_shape)) {
		return nullptr;
	}
	b3BodyId body_id = b3Shape_GetBody(p_shape);
	if (!b3Body_IsValid(body_id)) {
		return nullptr;
	}
	return static_cast<Box3DBody *>(b3Body_GetUserData(body_id));
}

void Box3DWorld::dispatch_contact_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3ContactEvents events = b3World_GetContactEvents(world_id);
	for (int i = 0; i < events.beginCount; ++i) {
		Box3DBody *a = body_from_shape(events.beginEvents[i].shapeIdA);
		Box3DBody *b = body_from_shape(events.beginEvents[i].shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_begin(b);
			b->emit_contact_begin(a);
		}
	}
	for (int i = 0; i < events.endCount; ++i) {
		Box3DBody *a = body_from_shape(events.endEvents[i].shapeIdA);
		Box3DBody *b = body_from_shape(events.endEvents[i].shapeIdB);
		if (a != nullptr && b != nullptr) {
			a->emit_contact_end(b);
			b->emit_contact_end(a);
		}
	}
	// Hit events stand in for upstream's internal TOI flag (lime flash).
	// Upstream sets it during the continuous-collision sweep, i.e. only for
	// bodies moving over half their min extent per step, and CCD only sweeps
	// against static geometry (bullets also sweep dynamic bodies). Mirror
	// both conditions using the hit event's approach speed.
	float dt = (float)last_step_delta;
	for (int i = 0; i < events.hitCount; ++i) {
		const b3ContactHitEvent &hit = events.hitEvents[i];
		Box3DBody *a = body_from_shape(hit.shapeIdA);
		Box3DBody *b = body_from_shape(hit.shapeIdB);
		if (a == nullptr || b == nullptr) {
			continue;
		}
		Box3DBody *pair[2] = { a, b };
		for (int j = 0; j < 2; ++j) {
			Box3DBody *self = pair[j];
			Box3DBody *other = pair[1 - j];
			if (self->get_body_type() != Box3DBody::DYNAMIC) {
				continue;
			}
			bool swept_partner = other->get_body_type() == Box3DBody::STATIC || self->get_continuous();
			if (swept_partner && hit.approachSpeed * dt > 0.5f * self->debug_min_extent()) {
				self->debug_hit_mark();
			}
		}
		// Extended core access: surface hit events to scripts. Gated on
		// contact_monitor like the touch signals, so quiet bodies stay free.
		Vector3 hit_point = to_gd_pos(hit.point);
		Vector3 hit_normal = to_gd(hit.normal);
		if (a->get_contact_monitor()) {
			a->emit_hit(b, hit_point, hit_normal, hit.approachSpeed);
		}
		if (b->get_contact_monitor()) {
			b->emit_hit(a, hit_point, -hit_normal, hit.approachSpeed);
		}
	}
}

void Box3DWorld::dispatch_sensor_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3SensorEvents events = b3World_GetSensorEvents(world_id);
	for (int i = 0; i < events.beginCount; ++i) {
		Box3DBody *sensor = body_from_shape(events.beginEvents[i].sensorShapeId);
		Box3DBody *visitor = body_from_shape(events.beginEvents[i].visitorShapeId);
		if (sensor != nullptr && visitor != nullptr) {
			sensor->emit_area_begin(visitor);
		}
	}
	for (int i = 0; i < events.endCount; ++i) {
		Box3DBody *sensor = body_from_shape(events.endEvents[i].sensorShapeId);
		Box3DBody *visitor = body_from_shape(events.endEvents[i].visitorShapeId);
		if (sensor != nullptr && visitor != nullptr) {
			sensor->emit_area_end(visitor);
		}
	}
}

void Box3DWorld::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			if (!Engine::get_singleton()->is_editor_hint()) {
				ensure_world();
				set_physics_process(true);
				set_process(true);
			}
		} break;
		case NOTIFICATION_PROCESS: {
			// Synchronous mode refreshes the debug shells here, at most once
			// per frame AND only after a step actually ran (the solver data is
			// frozen between ticks, so re-reading it at render rate was pure
			// waste; updating inside step() instead made every catch-up tick
			// pay the full rebuild, which spiraled heavy scenes to a
			// standstill). Async mode updates from apply_step_results instead:
			// a step is in flight during most process callbacks, and joining
			// here would stall the rendering async exists to protect.
			if (debug_draw && !async_step && debug_step_dirty && !Engine::get_singleton()->is_editor_hint()) {
				debug_step_dirty = false;
				update_debug_draw();
			}
		} break;
		case NOTIFICATION_EXIT_TREE: {
			stop_step_thread();
			if (b3World_IsValid(world_id)) {
				b3DestroyWorld(world_id);
			}
			world_id = b3_nullWorldId;
			bodies.clear();
		} break;
		case NOTIFICATION_PHYSICS_PROCESS: {
			if (auto_step && !Engine::get_singleton()->is_editor_hint()) {
				step(get_physics_process_delta_time());
			}
		} break;
	}
}

void Box3DWorld::set_gravity(const Vector3 &p_gravity) {
	gravity = p_gravity;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetGravity(world_id, to_b3(gravity));
	}
}

Vector3 Box3DWorld::get_gravity() const {
	return gravity;
}

void Box3DWorld::set_substep_count(int p_count) {
	substep_count = p_count < 1 ? 1 : p_count;
}

int Box3DWorld::get_substep_count() const {
	return substep_count;
}

void Box3DWorld::set_auto_step(bool p_enabled) {
	auto_step = p_enabled;
}

bool Box3DWorld::get_auto_step() const {
	return auto_step;
}

void Box3DWorld::set_continuous_collision(bool p_enabled) {
	continuous_collision = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableContinuous(world_id, p_enabled);
	}
}

bool Box3DWorld::get_continuous_collision() const {
	return continuous_collision;
}

void Box3DWorld::set_max_linear_speed(double p_speed) {
	max_linear_speed = p_speed;
	if (b3World_IsValid(world_id) && p_speed > 0.0) {
		join_async_step();
		b3World_SetMaximumLinearSpeed(world_id, (float)p_speed);
	}
}

double Box3DWorld::get_max_linear_speed() const {
	return max_linear_speed;
}

void Box3DWorld::set_worker_count(int p_count) {
	worker_count = p_count < 1 ? 1 : p_count;
	// Applied at world creation, and live via b3World_SetWorkerCount once the
	// world exists (Extended core access III).
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetWorkerCount(world_id, worker_count > B3_MAX_WORKERS ? B3_MAX_WORKERS : worker_count);
	}
}

int Box3DWorld::get_worker_count() const {
	return worker_count;
}

void Box3DWorld::set_async_step(bool p_enabled) {
	if (async_step == p_enabled) {
		return;
	}
	if (!p_enabled) {
		// Finish and absorb any in-flight step before going synchronous.
		join_async_step();
		if (step_pending_apply) {
			apply_step_results();
		}
	}
	async_step = p_enabled;
	// Run after every script's _physics_process so per-tick API calls (e.g. a
	// grab joint chasing the mouse) land before the step launches and never
	// have to wait for it.
	set_physics_process_priority(p_enabled ? 100 : 0);
}

bool Box3DWorld::get_async_step() const {
	return async_step;
}

Dictionary Box3DWorld::raycast(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask) {
	join_async_step();
	Dictionary result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	b3Pos origin = to_b3_pos(p_from);
	b3Vec3 translation = to_b3(p_to - p_from);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	b3RayResult r = b3World_CastRayClosest(world_id, origin, translation, filter);

	if (B3_IS_NON_NULL(r.shapeId)) {
		result["hit"] = true;
		result["position"] = to_gd_pos(r.point);
		result["normal"] = to_gd(r.normal);
		result["fraction"] = r.fraction;
		b3BodyId body_id = b3Shape_GetBody(r.shapeId);
		void *user_data = b3Body_GetUserData(body_id);
		if (user_data != nullptr) {
			result["collider"] = static_cast<Object *>(static_cast<Box3DBody *>(user_data));
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

namespace {

struct OverlapContext {
	Box3DWorld *world;
	std::vector<Box3DBody *> bodies;
};

bool overlap_result_cb(b3ShapeId p_shape, void *p_context) {
	OverlapContext *ctx = static_cast<OverlapContext *>(p_context);
	Box3DBody *body = ctx->world->body_from_shape(p_shape);
	if (body != nullptr) {
		for (Box3DBody *existing : ctx->bodies) {
			if (existing == body) {
				return true;
			}
		}
		ctx->bodies.push_back(body);
	}
	return true;
}

struct CastContext {
	Box3DWorld *world;
	bool hit = false;
	b3Pos point;
	b3Vec3 normal;
	float fraction = 1.0f;
	Box3DBody *body = nullptr;
};

float cast_result_cb(b3ShapeId p_shape, b3Pos p_point, b3Vec3 p_normal, float p_fraction, uint64_t, int, int, void *p_context) {
	CastContext *ctx = static_cast<CastContext *>(p_context);
	ctx->hit = true;
	ctx->point = p_point;
	ctx->normal = p_normal;
	ctx->fraction = p_fraction;
	ctx->body = ctx->world->body_from_shape(p_shape);
	return p_fraction; // clip so later reports are only closer hits
}

struct RayAllContext {
	Box3DWorld *world;
	Array hits;
};

float ray_all_result_cb(b3ShapeId p_shape, b3Pos p_point, b3Vec3 p_normal, float p_fraction, uint64_t, int, int, void *p_context) {
	RayAllContext *ctx = static_cast<RayAllContext *>(p_context);
	Dictionary d;
	d["position"] = to_gd_pos(p_point);
	d["normal"] = to_gd(p_normal);
	d["fraction"] = p_fraction;
	Box3DBody *body = ctx->world->body_from_shape(p_shape);
	if (body != nullptr) {
		d["collider"] = static_cast<Object *>(body);
	}
	ctx->hits.push_back(d);
	return 1.0f; // keep the full ray range so every crossed shape is reported
}

} // namespace

Array Box3DWorld::cast_ray_all(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask) {
	join_async_step();
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return Array();
	}
	b3Pos origin = to_b3_pos(p_from);
	b3Vec3 translation = to_b3(p_to - p_from);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	RayAllContext ctx;
	ctx.world = this;
	b3World_CastRay(world_id, origin, translation, filter, ray_all_result_cb, &ctx);
	return ctx.hits;
}

Array Box3DWorld::overlap_sphere(const Vector3 &p_center, double p_radius, uint32_t p_mask) {
	join_async_step();
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	b3Vec3 point = b3Vec3{ 0.0f, 0.0f, 0.0f };
	b3ShapeProxy proxy;
	proxy.points = &point;
	proxy.count = 1;
	proxy.radius = (float)p_radius;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapShape(world_id, to_b3_pos(p_center), &proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius, uint32_t p_mask) {
	join_async_step();
	Dictionary result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		result["hit"] = false;
		return result;
	}
	b3Vec3 point = b3Vec3{ 0.0f, 0.0f, 0.0f };
	b3ShapeProxy proxy;
	proxy.points = &point;
	proxy.count = 1;
	proxy.radius = (float)p_radius;
	b3Vec3 translation = to_b3(p_to - p_from);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	CastContext ctx;
	ctx.world = this;
	b3World_CastShape(world_id, to_b3_pos(p_from), &proxy, translation, filter, cast_result_cb, &ctx);
	if (ctx.hit) {
		result["hit"] = true;
		result["position"] = to_gd_pos(ctx.point);
		result["normal"] = to_gd(ctx.normal);
		result["fraction"] = ctx.fraction;
		if (ctx.body != nullptr) {
			result["collider"] = static_cast<Object *>(ctx.body);
		}
	} else {
		result["hit"] = false;
	}
	return result;
}

void Box3DWorld::explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff, uint32_t p_mask) {
	join_async_step();
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3ExplosionDef def = b3DefaultExplosionDef();
	def.position = to_b3_pos(p_center);
	def.radius = (float)p_radius;
	def.falloff = (float)p_falloff;
	def.impulsePerArea = (float)p_impulse_per_area;
	def.maskBits = p_mask;
	b3World_Explode(world_id, &def);
}


void Box3DWorld::update_debug_draw() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	if (debug_mm[DEBUG_BOX] == nullptr) {
		// Solid state-colored shells, like upstream box3d's sample viewer. One
		// MultiMesh per primitive keeps thousands of bodies at a handful of
		// draw calls. A fixed-direction half-lambert ignores the sample's own
		// lighting/tonemap so the state colors read the same everywhere.
		Ref<Shader> shader;
		shader.instantiate();
		shader->set_code(R"(shader_type spatial;
render_mode unshaded;

void fragment() {
	vec3 light_vs = normalize((VIEW_MATRIX * vec4(0.35, 0.8, 0.45, 0.0)).xyz);
	float shade = clamp(dot(normalize(NORMAL), light_vs), 0.0, 1.0) * 0.55 + 0.45;
	// Instance colors are upstream's sRGB hex palette; linearize so the
	// rendered output matches it.
	ALBEDO = pow(COLOR.rgb, vec3(2.2)) * shade;
}
)");
		Ref<ShaderMaterial> mat;
		mat.instantiate();
		mat->set_shader(shader);

		Ref<BoxMesh> box_mesh;
		box_mesh.instantiate();
		box_mesh->set_size(Vector3(1, 1, 1));
		Ref<SphereMesh> sphere_mesh;
		sphere_mesh.instantiate();
		sphere_mesh->set_radius(0.5);
		sphere_mesh->set_height(1.0);
		Ref<CapsuleMesh> capsule_mesh;
		capsule_mesh.instantiate();
		capsule_mesh->set_radius(0.5);
		capsule_mesh->set_height(2.0);
		Ref<CylinderMesh> cylinder_mesh;
		cylinder_mesh.instantiate();
		cylinder_mesh->set_top_radius(0.5);
		cylinder_mesh->set_bottom_radius(0.5);
		cylinder_mesh->set_height(1.0);
		Ref<CylinderMesh> cone_mesh;
		cone_mesh.instantiate();
		cone_mesh->set_top_radius(0.0);
		cone_mesh->set_bottom_radius(0.5);
		cone_mesh->set_height(1.0);
		Ref<Mesh> meshes[DEBUG_PRIM_MAX] = { box_mesh, sphere_mesh, capsule_mesh, cylinder_mesh, cone_mesh };

		for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
			MultiMeshInstance3D *mi = memnew(MultiMeshInstance3D);
			mi->set_name(String("Box3DDebugDraw") + String::num_int64(p));
			mi->set_as_top_level(true); // draw in world space
			// Bulk multimesh_set_buffer uploads bypass the engine's own
			// multimesh physics interpolation; opt out so they render as-is.
			mi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
			// The shells are rewritten every physics tick already; interpolating
			// them too would just smear the debug view a frame behind.
			mi->set_physics_interpolation_mode(Node::PHYSICS_INTERPOLATION_MODE_OFF);
			Ref<MultiMesh> mm;
			mm.instantiate();
			mm->set_transform_format(MultiMesh::TRANSFORM_3D);
			mm->set_use_colors(true);
			mm->set_mesh(meshes[p]);
			// Without a custom AABB every buffer upload makes the renderer
			// recompute the bounds over all instances — half the refresh cost
			// at 16k bodies. Debug shells don't need accurate culling.
			mm->set_custom_aabb(AABB(Vector3(-100000, -100000, -100000), Vector3(200000, 200000, 200000)));
			mi->set_multimesh(mm);
			mi->set_material_override(mat);
			mi->set_visible(debug_draw);
			add_child(mi);
			debug_mm[p] = mi;
		}
	}

	// Callers are already post-join (sync step done, or async post-apply), so
	// this is a single atomic load; it guards any stray toggle-time path. The
	// per-body loops below therefore call the raw b3 API on cached ids instead
	// of the guarded wrappers — at 16k bodies the wrappers' per-call join +
	// revalidation dominated the whole refresh.
	join_async_step();

	// While every body sleeps nothing moves or changes color, so skip the
	// instance rewrite entirely. The first quiet frame still rebuilds, which
	// is what paints the pile in its sleeping colors. Members only: even one
	// b3 lookup per body here is measurable at this scale.
	bool any_awake = false;
	int body_count = 0;
	for (Box3DBody *body : bodies) {
		if (body == nullptr) {
			continue;
		}
		++body_count;
		if (!any_awake) {
			int type = body->get_body_type();
			// Kinematic bodies count as awake: scripts move them without the
			// cached dynamic-body sleep state ever seeing it.
			if (type == Box3DBody::KINEMATIC || (type == Box3DBody::DYNAMIC && body->get_snap_awake())) {
				any_awake = true;
			}
		}
	}
	if (!any_awake && !debug_last_any_awake && body_count == debug_last_body_count) {
		return;
	}
	debug_last_any_awake = any_awake;
	debug_last_body_count = body_count;

	const float INFLATE = 1.02f; // shells cover the samples' own visuals

	// Shells are written straight into the persistent upload buffers (grown
	// geometrically, never shrunk); the old intermediate Transform3D/Color
	// vectors doubled the memory traffic for nothing.
	int shell_count[DEBUG_PRIM_MAX] = {};
	float *shell_w[DEBUG_PRIM_MAX];
	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		shell_w[p] = debug_buffer[p].ptrw();
	}
	auto push_shell = [&](int prim, const Basis &basis, const Vector3 &origin, Vector3 scale, const Color &col) {
		PackedFloat32Array &buf = debug_buffer[prim];
		const int64_t need = ((int64_t)shell_count[prim] + 1) * 16;
		if (buf.size() < need) {
			const int64_t grow = buf.size() * 2;
			buf.resize(grow < need ? need : grow);
			shell_w[prim] = buf.ptrw();
		}
		scale *= INFLATE;
		float *inst = shell_w[prim] + (int64_t)shell_count[prim] * 16;
		++shell_count[prim];
		// Right-multiply the basis by diag(scale): component-scale each row.
		inst[0] = (float)(basis.rows[0][0] * scale.x);
		inst[1] = (float)(basis.rows[0][1] * scale.y);
		inst[2] = (float)(basis.rows[0][2] * scale.z);
		inst[3] = (float)origin.x;
		inst[4] = (float)(basis.rows[1][0] * scale.x);
		inst[5] = (float)(basis.rows[1][1] * scale.y);
		inst[6] = (float)(basis.rows[1][2] * scale.z);
		inst[7] = (float)origin.y;
		inst[8] = (float)(basis.rows[2][0] * scale.x);
		inst[9] = (float)(basis.rows[2][1] * scale.y);
		inst[10] = (float)(basis.rows[2][2] * scale.z);
		inst[11] = (float)origin.z;
		inst[12] = col.r;
		inst[13] = col.g;
		inst[14] = col.b;
		inst[15] = col.a;
	};

	for (Box3DBody *body : bodies) {
		if (body == nullptr || !body->get_debug_visualize()) {
			continue;
		}
		// A registered body's id is live by construction (bodies register only
		// after successful creation and unregister on destroy), so a null check
		// replaces a 16k-times-per-refresh b3Body_IsValid lookup.
		const b3BodyId id = body->get_body_id();
		if (B3_IS_NULL(id)) {
			continue;
		}
		// State colors: upstream box3d's exact palette and priority order
		// (physics_world.c). Red bad body, slate disabled, wheat sensor, lime
		// recent impact (hit event, standing in for the internal TOI flag),
		// turquoise awake bullet, yellow speed-capped, orange fast (moves
		// over half its min extent per step, the CCD criterion), dark gray
		// static, steel blues kinematic, tan awake / light slate asleep.
		const int type = body->get_body_type();
		const bool dynamic = type == Box3DBody::DYNAMIC;
		const bool awake = dynamic ? body->get_snap_awake() : (type == Box3DBody::KINEMATIC && b3Body_IsAwake(id));
		float lin_speed = 0.0f;
		float motion_speed = 0.0f; // upstream: |v| + |w| * maxExtent (farthest point)
		// Computed only when a branch below can use them (speed cap or CCD on),
		// and from the render snapshots rather than b3 velocity lookups: the
		// per-step transform delta over the step time IS the step's effective
		// velocity, and two more validated b3 calls per body are measurable
		// at 16k bodies.
		if (dynamic && awake && (max_linear_speed > 0.0 || continuous_collision)) {
			const b3WorldTransform &sp = body->get_snap_prev();
			const b3WorldTransform &sc = body->get_snap_curr();
			const float inv_dt = last_step_delta > 0.0 ? (float)(1.0 / last_step_delta) : 0.0f;
			const float dx = (float)(sc.p.x - sp.p.x);
			const float dy = (float)(sc.p.y - sp.p.y);
			const float dz = (float)(sc.p.z - sp.p.z);
			lin_speed = std::sqrt(dx * dx + dy * dy + dz * dz) * inv_dt;
			if (continuous_collision) {
				// Rotation delta angle between the two snapshots.
				float qd = std::abs(b3DotQuat(sp.q, sc.q));
				float ang = 2.0f * std::acos(qd < 1.0f ? qd : 1.0f);
				motion_speed = lin_speed + ang * inv_dt * body->get_cached_max_extent();
			}
		}
		Color col;
		if (dynamic && body->get_cached_mass() == 0.0f) {
			col = Color::hex(0xFF0000FF); // red: bad body
		} else if (!body->get_cached_enabled()) {
			col = Color::hex(0x708090FF); // slate gray: disabled
		} else if (body->get_is_sensor()) {
			col = Color::hex(0xF5DEB3FF); // wheat: sensor
		} else if (body->debug_hit_active()) {
			col = Color::hex(0x00FF00FF); // lime: recent impact
		} else if (body->get_continuous() && dynamic && awake) {
			col = Color::hex(0x40E0D0FF); // turquoise: awake bullet
		} else if (max_linear_speed > 0.0 && lin_speed >= (float)max_linear_speed * 0.99f) {
			col = Color::hex(0xFFFF00FF); // yellow: speed capped
		} else if (dynamic && continuous_collision && motion_speed * (float)last_step_delta > 0.5f * body->get_cached_min_extent()) {
			col = Color::hex(0xFFA500FF); // orange: fast (CCD territory)
		} else if (type == Box3DBody::STATIC) {
			col = Color::hex(0xA9A9A9FF); // dark gray: static
		} else if (type == Box3DBody::KINEMATIC) {
			col = awake ? Color::hex(0x4682B4FF) : Color::hex(0xB0C4DEFF); // steel blues
		} else {
			col = awake ? Color::hex(0xD2B48CFF) : Color::hex(0x778899FF); // tan / light slate
		}
		// Compound bodies: shell each Box3DCollisionShape child. The physics
		// ignores the body's own shape_type when child shapes exist, so drawing
		// it would show a collider that isn't there. The cached flag keeps the
		// common single-shape body from paying a get_child_count engine call.
		if (body->has_cached_child_shapes()) {
			for (int i = 0; i < body->get_child_count(); ++i) {
				Box3DCollisionShape *cs = Object::cast_to<Box3DCollisionShape>(body->get_child(i));
				if (cs == nullptr) {
					continue;
				}
				Transform3D cxf = cs->get_global_transform();
				float cr2 = (float)cs->get_capsule_radius();
				switch (cs->get_shape_type()) {
					case Box3DCollisionShape::SPHERE: {
						float r = (float)cs->get_sphere_radius();
						push_shell(DEBUG_SPHERE, cxf.basis, cxf.origin, Vector3(2 * r, 2 * r, 2 * r), col);
					} break;
					case Box3DCollisionShape::CAPSULE:
						push_shell(DEBUG_CAPSULE, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height() * 0.5f, 2 * cr2), col);
						break;
					case Box3DCollisionShape::CYLINDER:
						push_shell(DEBUG_CYLINDER, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height(), 2 * cr2), col);
						break;
					case Box3DCollisionShape::CONE:
						push_shell(DEBUG_CONE, cxf.basis, cxf.origin, Vector3(2 * cr2, (float)cs->get_capsule_height(), 2 * cr2), col);
						break;
					case Box3DCollisionShape::BOX:
					default:
						push_shell(DEBUG_BOX, cxf.basis, cxf.origin, cs->get_box_size(), col);
						break;
				}
			}
			continue;
		}
		// From the solver, not the node: renderer-managed bodies (with
		// sync_node_transform off) keep a stale node pose. Dynamic bodies read
		// the snapshot sync_from_physics already recorded this tick; kinematic
		// and static bodies (few, and not snapshotted) ask b3 directly.
		const b3WorldTransform bxf = dynamic ? body->get_snap_curr() : b3Body_GetTransform(id);
		const Basis basis(to_gd(bxf.q));
		const Vector3 origin = to_gd_pos(bxf.p);
		float cr = (float)body->get_capsule_radius();
		float ch = (float)body->get_capsule_height();
		switch (body->get_shape_type()) {
			case Box3DBody::SPHERE: {
				float r = (float)body->get_sphere_radius();
				push_shell(DEBUG_SPHERE, basis, origin, Vector3(2 * r, 2 * r, 2 * r), col);
			} break;
			case Box3DBody::CAPSULE:
				push_shell(DEBUG_CAPSULE, basis, origin, Vector3(2 * cr, ch * 0.5f, 2 * cr), col);
				break;
			case Box3DBody::CYLINDER:
				push_shell(DEBUG_CYLINDER, basis, origin, Vector3(2 * cr, ch, 2 * cr), col);
				break;
			case Box3DBody::CONE:
				push_shell(DEBUG_CONE, basis, origin, Vector3(2 * cr, ch, 2 * cr), col);
				break;
			case Box3DBody::BOX:
				push_shell(DEBUG_BOX, basis, origin, body->get_box_size(), col);
				break;
			default:
				break; // Hull / mesh colliders are not shelled
		}
	}

	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		Ref<MultiMesh> mm = debug_mm[p]->get_multimesh();
		const int n = shell_count[p];
		// One bulk buffer upload instead of two RenderingServer calls per
		// instance — per-instance writes cost ~160 ms/frame at 16k bodies. The
		// multimesh is kept sized to the whole (grow-only) buffer; instances
		// past n are zeroed and invisible.
		const int alloc = (int)(debug_buffer[p].size() / 16);
		if (alloc == 0) {
			mm->set_visible_instance_count(0);
			continue; // no shells of this primitive; 0-size uploads error out
		}
		if (mm->get_instance_count() != alloc) {
			mm->set_instance_count(alloc);
		}
		mm->set_visible_instance_count(n);
		if (alloc > n) {
			memset(shell_w[p] + (int64_t)n * 16, 0, ((int64_t)alloc - n) * 16 * sizeof(float));
		}
		RenderingServer::get_singleton()->multimesh_set_buffer(mm->get_rid(), debug_buffer[p]);
	}
}

void Box3DWorld::set_debug_draw(bool p_enabled) {
	debug_draw = p_enabled;
	debug_last_body_count = -1; // force a rebuild on the next step
	debug_step_dirty = true; // even without a step (paused / standstill scene)
	for (int p = 0; p < DEBUG_PRIM_MAX; ++p) {
		if (debug_mm[p] != nullptr) {
			debug_mm[p]->set_visible(p_enabled);
		}
	}
}

bool Box3DWorld::get_debug_draw() const {
	return debug_draw;
}

void Box3DWorld::set_contact_hertz(double p_hertz) {
	contact_hertz = p_hertz;
	apply_contact_tuning();
}

double Box3DWorld::get_contact_hertz() const {
	return contact_hertz;
}

void Box3DWorld::set_contact_damping(double p_damping) {
	contact_damping = p_damping;
	apply_contact_tuning();
}

double Box3DWorld::get_contact_damping() const {
	return contact_damping;
}

void Box3DWorld::set_enable_sleep(bool p_enabled) {
	enable_sleep = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableSleeping(world_id, enable_sleep);
	}
}

bool Box3DWorld::get_enable_sleep() const {
	return enable_sleep;
}

void Box3DWorld::set_enable_warm_starting(bool p_enabled) {
	enable_warm_starting = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableWarmStarting(world_id, enable_warm_starting);
	}
}

bool Box3DWorld::get_enable_warm_starting() const {
	return enable_warm_starting;
}

// --- Extended core access -----------------------------------------------------

int Box3DWorld::get_awake_body_count() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return 0;
	}
	return b3World_GetAwakeBodyCount(world_id);
}

Dictionary Box3DWorld::get_counters() const {
	join_async_step();
	Dictionary d;
	if (!b3World_IsValid(world_id)) {
		return d;
	}
	b3Counters c = b3World_GetCounters(world_id);
	d["bodies"] = c.bodyCount;
	d["shapes"] = c.shapeCount;
	d["contacts"] = c.contactCount;
	d["joints"] = c.jointCount;
	d["islands"] = c.islandCount;
	d["stack_used"] = c.stackUsed;
	d["static_tree_height"] = c.staticTreeHeight;
	d["tree_height"] = c.treeHeight;
	return d;
}

Dictionary Box3DWorld::get_profile() const {
	join_async_step();
	Dictionary d;
	if (!b3World_IsValid(world_id)) {
		return d;
	}
	b3Profile p = b3World_GetProfile(world_id);
	d["step"] = p.step;
	d["pairs"] = p.pairs;
	d["collide"] = p.collide;
	d["solve"] = p.solve;
	return d;
}

AABB Box3DWorld::get_bounds() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return AABB();
	}
	b3AABB b = b3World_GetBounds(world_id);
	Vector3 lower = to_gd(b.lowerBound);
	Vector3 upper = to_gd(b.upperBound);
	return AABB(lower, upper - lower);
}

void Box3DWorld::rebuild_static_tree() {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		b3World_RebuildStaticTree(world_id);
	}
}

Array Box3DWorld::overlap_aabb(const AABB &p_aabb, uint32_t p_mask) {
	join_async_step();
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	b3AABB aabb;
	aabb.lowerBound = to_b3(p_aabb.position);
	aabb.upperBound = to_b3(p_aabb.position + p_aabb.size);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapAABB(world_id, aabb, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

void Box3DWorld::set_enable_speculative(bool p_enabled) {
	join_async_step();
	enable_speculative = p_enabled;
	if (b3World_IsValid(world_id)) {
		b3World_EnableSpeculative(world_id, p_enabled);
	}
}

bool Box3DWorld::get_enable_speculative() const {
	return enable_speculative;
}

void Box3DWorld::set_restitution_threshold(double p_speed) {
	join_async_step();
	restitution_threshold = p_speed;
	if (b3World_IsValid(world_id) && p_speed >= 0.0) {
		b3World_SetRestitutionThreshold(world_id, (float)p_speed);
	}
}

double Box3DWorld::get_restitution_threshold() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_GetRestitutionThreshold(world_id);
	}
	return restitution_threshold;
}

void Box3DWorld::set_hit_event_threshold(double p_speed) {
	join_async_step();
	hit_event_threshold = p_speed;
	if (b3World_IsValid(world_id) && p_speed >= 0.0) {
		b3World_SetHitEventThreshold(world_id, (float)p_speed);
	}
}

double Box3DWorld::get_hit_event_threshold() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_GetHitEventThreshold(world_id);
	}
	return hit_event_threshold;
}

void Box3DWorld::set_contact_recycle_distance(double p_distance) {
	join_async_step();
	contact_recycle_distance = p_distance;
	if (b3World_IsValid(world_id) && p_distance >= 0.0) {
		b3World_SetContactRecycleDistance(world_id, (float)p_distance);
	}
}

double Box3DWorld::get_contact_recycle_distance() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_GetContactRecycleDistance(world_id);
	}
	return contact_recycle_distance;
}

bool Box3DWorld::start_recording(int p_byte_capacity) {
	join_async_step();
	ensure_world();
	if (recording != nullptr || !b3World_IsValid(world_id)) {
		return false;
	}
	recording = b3CreateRecording(p_byte_capacity);
	if (recording == nullptr) {
		return false;
	}
	b3World_StartRecording(world_id, recording);
	return true;
}

PackedByteArray Box3DWorld::stop_recording() {
	join_async_step();
	PackedByteArray out;
	if (recording == nullptr) {
		return out;
	}
	if (b3World_IsValid(world_id)) {
		b3World_StopRecording(world_id);
	}
	int size = b3Recording_GetSize(recording);
	const uint8_t *data = b3Recording_GetData(recording);
	if (size > 0 && data != nullptr) {
		out.resize(size);
		memcpy(out.ptrw(), data, size);
	}
	b3DestroyRecording(recording);
	recording = nullptr;
	return out;
}

bool Box3DWorld::is_recording() const {
	return recording != nullptr;
}

bool Box3DWorld::validate_replay(const PackedByteArray &p_data, int p_worker_count) {
	if (p_data.is_empty()) {
		return false;
	}
	return b3ValidateReplay(p_data.ptr(), p_data.size(),
			p_worker_count < 1 ? 1 : p_worker_count);
}

// --- Extended core access III: full b3World_* coverage -------------------------

namespace {

// Debug-shape token handed to Box3D as the opaque `userShape`. Box3D creates it
// lazily inside b3World_Draw and destroys it on shape change/destroy and world
// destruction, so it never leaks. Geometry is copied (the engine's pointers
// are into arrays that can be reallocated).
struct DebugShapeToken {
	b3ShapeId shape_id;
	b3ShapeType type;
	b3Vec3 center1;
	b3Vec3 center2;
	float radius;
};

void *debug_shape_create_cb(const b3DebugShape *p_shape, void *) {
	DebugShapeToken *t = new DebugShapeToken();
	t->shape_id = p_shape->shapeId;
	t->type = p_shape->type;
	t->center1 = b3Vec3{ 0.0f, 0.0f, 0.0f };
	t->center2 = t->center1;
	t->radius = 0.0f;
	if (p_shape->type == b3_sphereShape && p_shape->sphere != nullptr) {
		t->center1 = p_shape->sphere->center;
		t->center2 = p_shape->sphere->center;
		t->radius = p_shape->sphere->radius;
	} else if (p_shape->type == b3_capsuleShape && p_shape->capsule != nullptr) {
		t->center1 = p_shape->capsule->center1;
		t->center2 = p_shape->capsule->center2;
		t->radius = p_shape->capsule->radius;
	}
	return t;
}

void debug_shape_destroy_cb(void *p_user_shape, void *) {
	delete static_cast<DebugShapeToken *>(p_user_shape);
}

bool world_custom_filter_cb(b3ShapeId p_a, b3ShapeId p_b, void *p_context) {
	return static_cast<const Box3DWorld *>(p_context)->filter_allows_pair(p_a, p_b);
}

bool world_presolve_cb(b3ShapeId p_a, b3ShapeId p_b, b3Pos, b3Vec3 p_normal, void *p_context) {
	return static_cast<const Box3DWorld *>(p_context)->presolve_allows(p_a, p_b, p_normal);
}

// Mixing rules. Box3D passes no context (worker thread), so each rule is its
// own function and the world installs the one it wants.
float mix_average(float a, uint64_t, float b, uint64_t) { return 0.5f * (a + b); }
float mix_min(float a, uint64_t, float b, uint64_t) { return a < b ? a : b; }
float mix_max(float a, uint64_t, float b, uint64_t) { return a > b ? a : b; }
float mix_multiply(float a, uint64_t, float b, uint64_t) { return a * b; }
float mix_geometric(float a, uint64_t, float b, uint64_t) { return std::sqrt(a * b > 0.0f ? a * b : 0.0f); }

b3FrictionCallback *mix_fn(int p_rule) {
	switch (p_rule) {
		case Box3DWorld::MIX_AVERAGE:
			return mix_average;
		case Box3DWorld::MIX_MIN:
			return mix_min;
		case Box3DWorld::MIX_MAX:
			return mix_max;
		case Box3DWorld::MIX_MULTIPLY:
			return mix_multiply;
		case Box3DWorld::MIX_GEOMETRIC:
			return mix_geometric;
		default:
			return nullptr; // engine default
	}
}

// Worker-thread safe: plain reads of immutable-during-step engine data.
const Box3DBody *raw_body_of_shape(b3ShapeId p_shape) {
	return static_cast<const Box3DBody *>(b3Body_GetUserData(b3Shape_GetBody(p_shape)));
}

Color hex_to_color(b3HexColor p_color) {
	uint32_t v = (uint32_t)p_color & 0x00FFFFFFu;
	return Color(((v >> 16) & 0xFF) / 255.0f, ((v >> 8) & 0xFF) / 255.0f, (v & 0xFF) / 255.0f, 1.0f);
}

Transform3D world_xf_to_gd(const b3WorldTransform &p_xf) {
	return Transform3D(Basis(to_gd(p_xf.q)), to_gd_pos(p_xf.p));
}

// Builds a b3ShapeProxy from a Dictionary descriptor. Points are relative to
// the query origin (the transform's origin) and rotated by its basis.
struct ProxyBuffer {
	b3Vec3 points[B3_MAX_SHAPE_CAST_POINTS];
	b3ShapeProxy proxy;
};

bool build_proxy(const Dictionary &p_shape, const Basis &p_basis, ProxyBuffer &r_buf) {
	String type = String(p_shape.get("type", "sphere")).to_lower();
	int count = 0;
	float radius = 0.0f;
	if (type == "sphere") {
		r_buf.points[count++] = b3Vec3{ 0.0f, 0.0f, 0.0f };
		radius = (float)(double)p_shape.get("radius", 0.5);
	} else if (type == "capsule") {
		radius = (float)(double)p_shape.get("radius", 0.5);
		float half = (float)(double)p_shape.get("height", 2.0) * 0.5f - radius;
		if (half < 0.0f) {
			half = 0.0f;
		}
		r_buf.points[count++] = to_b3(p_basis.xform(Vector3(0, -half, 0)));
		r_buf.points[count++] = to_b3(p_basis.xform(Vector3(0, half, 0)));
	} else if (type == "box") {
		Vector3 h = Vector3(p_shape.get("size", Vector3(1, 1, 1))) * 0.5;
		radius = (float)(double)p_shape.get("radius", 0.0);
		for (int i = 0; i < 8; ++i) {
			Vector3 c((i & 1) ? h.x : -h.x, (i & 2) ? h.y : -h.y, (i & 4) ? h.z : -h.z);
			r_buf.points[count++] = to_b3(p_basis.xform(c));
		}
	} else if (type == "points" || type == "hull") {
		PackedVector3Array pts = p_shape.get("points", PackedVector3Array());
		radius = (float)(double)p_shape.get("radius", 0.0);
		int64_t n = pts.size();
		ERR_FAIL_COND_V_MSG(n < 1, false, "Box3DWorld: 'points' shape needs at least one point.");
		if (n > B3_MAX_SHAPE_CAST_POINTS) {
			WARN_PRINT("Box3DWorld: 'points' shape truncated to B3_MAX_SHAPE_CAST_POINTS.");
			n = B3_MAX_SHAPE_CAST_POINTS;
		}
		for (int64_t i = 0; i < n; ++i) {
			r_buf.points[count++] = to_b3(p_basis.xform(pts[i]));
		}
	} else {
		ERR_FAIL_V_MSG(false, "Box3DWorld: unknown shape type '" + type + "' (sphere, capsule, box, points).");
	}
	r_buf.proxy.points = r_buf.points;
	r_buf.proxy.count = count;
	r_buf.proxy.radius = radius;
	return true;
}

struct MoverFilterContext {
	const std::vector<const Box3DBody *> *exclude;
};

bool mover_filter_cb(b3ShapeId p_shape, void *p_context) {
	const MoverFilterContext *ctx = static_cast<const MoverFilterContext *>(p_context);
	const Box3DBody *body = raw_body_of_shape(p_shape);
	for (const Box3DBody *ex : *ctx->exclude) {
		if (ex == body) {
			return false;
		}
	}
	return true;
}

// b3World_Draw collector.
struct DrawCollector {
	Box3DWorld *world;
	PackedVector3Array segments;
	PackedColorArray segment_colors;
	PackedVector3Array points;
	PackedFloat32Array point_sizes;
	PackedColorArray point_colors;
	Array transforms;
	Array spheres;
	Array capsules;
	Array bounds;
	Array boxes;
	Array strings;
	Array shapes;
};

void draw_shape_cb(void *p_user_shape, b3WorldTransform p_xf, b3HexColor p_color, void *p_ctx) {
	DrawCollector *c = static_cast<DrawCollector *>(p_ctx);
	const DebugShapeToken *t = static_cast<const DebugShapeToken *>(p_user_shape);
	Dictionary d;
	d["shape_id"] = (int64_t)b3StoreShapeId(t->shape_id);
	d["type"] = (int)t->type;
	d["transform"] = world_xf_to_gd(p_xf);
	d["color"] = hex_to_color(p_color);
	Box3DBody *body = c->world->body_from_shape(t->shape_id);
	if (body != nullptr) {
		d["collider"] = static_cast<Object *>(body);
	}
	if (t->type == b3_sphereShape) {
		d["center"] = to_gd(t->center1);
		d["radius"] = t->radius;
	} else if (t->type == b3_capsuleShape) {
		d["center1"] = to_gd(t->center1);
		d["center2"] = to_gd(t->center2);
		d["radius"] = t->radius;
	}
	c->shapes.push_back(d);
}

void draw_segment_cb(b3Pos p1, b3Pos p2, b3HexColor p_color, void *p_ctx) {
	DrawCollector *c = static_cast<DrawCollector *>(p_ctx);
	c->segments.push_back(to_gd_pos(p1));
	c->segments.push_back(to_gd_pos(p2));
	c->segment_colors.push_back(hex_to_color(p_color));
}

void draw_transform_cb(b3WorldTransform p_xf, void *p_ctx) {
	static_cast<DrawCollector *>(p_ctx)->transforms.push_back(world_xf_to_gd(p_xf));
}

void draw_point_cb(b3Pos p, float p_size, b3HexColor p_color, void *p_ctx) {
	DrawCollector *c = static_cast<DrawCollector *>(p_ctx);
	c->points.push_back(to_gd_pos(p));
	c->point_sizes.push_back(p_size);
	c->point_colors.push_back(hex_to_color(p_color));
}

void draw_sphere_cb(b3Pos p, float p_radius, b3HexColor p_color, float p_alpha, void *p_ctx) {
	Dictionary d;
	d["center"] = to_gd_pos(p);
	d["radius"] = p_radius;
	d["color"] = hex_to_color(p_color);
	d["alpha"] = p_alpha;
	static_cast<DrawCollector *>(p_ctx)->spheres.push_back(d);
}

void draw_capsule_cb(b3Pos p1, b3Pos p2, float p_radius, b3HexColor p_color, float p_alpha, void *p_ctx) {
	Dictionary d;
	d["center1"] = to_gd_pos(p1);
	d["center2"] = to_gd_pos(p2);
	d["radius"] = p_radius;
	d["color"] = hex_to_color(p_color);
	d["alpha"] = p_alpha;
	static_cast<DrawCollector *>(p_ctx)->capsules.push_back(d);
}

void draw_bounds_cb(b3AABB p_aabb, b3HexColor p_color, void *p_ctx) {
	Dictionary d;
	Vector3 lo = to_gd(p_aabb.lowerBound);
	Vector3 hi = to_gd(p_aabb.upperBound);
	d["aabb"] = AABB(lo, hi - lo);
	d["color"] = hex_to_color(p_color);
	static_cast<DrawCollector *>(p_ctx)->bounds.push_back(d);
}

void draw_box_cb(b3Vec3 p_extents, b3WorldTransform p_xf, b3HexColor p_color, void *p_ctx) {
	Dictionary d;
	d["extents"] = to_gd(p_extents); // half extents
	d["transform"] = world_xf_to_gd(p_xf);
	d["color"] = hex_to_color(p_color);
	static_cast<DrawCollector *>(p_ctx)->boxes.push_back(d);
}

void draw_string_cb(b3Pos p, const char *p_text, b3HexColor p_color, void *p_ctx) {
	Dictionary d;
	d["position"] = to_gd_pos(p);
	d["text"] = String::utf8(p_text != nullptr ? p_text : "");
	d["color"] = hex_to_color(p_color);
	static_cast<DrawCollector *>(p_ctx)->strings.push_back(d);
}

} // namespace

int Box3DWorld::get_world_count() {
	return b3GetWorldCount();
}

int Box3DWorld::get_max_world_count() {
	return b3GetMaxWorldCount();
}

Vector3 Box3DWorld::get_live_gravity() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return gravity;
	}
	return to_gd(b3World_GetGravity(world_id));
}

bool Box3DWorld::is_sleeping_enabled() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return enable_sleep;
	}
	return b3World_IsSleepingEnabled(world_id);
}

bool Box3DWorld::is_continuous_enabled() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return continuous_collision;
	}
	return b3World_IsContinuousEnabled(world_id);
}

bool Box3DWorld::is_warm_starting_enabled() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return enable_warm_starting;
	}
	return b3World_IsWarmStartingEnabled(world_id);
}

double Box3DWorld::get_maximum_linear_speed() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return max_linear_speed > 0.0 ? max_linear_speed : (double)b3DefaultWorldDef().maximumLinearSpeed;
	}
	return b3World_GetMaximumLinearSpeed(world_id);
}

int Box3DWorld::get_live_worker_count() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return 0;
	}
	return b3World_GetWorkerCount(world_id);
}

Dictionary Box3DWorld::get_max_capacity() const {
	join_async_step();
	Dictionary d;
	if (!b3World_IsValid(world_id)) {
		return d;
	}
	b3Capacity c = b3World_GetMaxCapacity(world_id);
	d["static_shapes"] = c.staticShapeCount;
	d["dynamic_shapes"] = c.dynamicShapeCount;
	d["static_bodies"] = c.staticBodyCount;
	d["dynamic_bodies"] = c.dynamicBodyCount;
	d["contacts"] = c.contactCount;
	return d;
}

Object *Box3DWorld::get_user_data() const {
	join_async_step();
	if (!b3World_IsValid(world_id)) {
		return nullptr;
	}
	// ensure_world stores the owning node; b3World_SetUserData is reserved for
	// that back-pointer and therefore not exposed as a setter.
	return static_cast<Box3DWorld *>(b3World_GetUserData(world_id));
}

void Box3DWorld::set_restitution_iterations(int p_iterations) {
	restitution_iterations = CLAMP(p_iterations, 0, B3_MAX_RESTITUTION_ITERATIONS);
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetRestitutionIterations(world_id, restitution_iterations);
	}
}

int Box3DWorld::get_restitution_iterations() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_GetRestitutionIterations(world_id);
	}
	return restitution_iterations;
}

void Box3DWorld::set_enable_restitution_propagation(bool p_enabled) {
	enable_restitution_propagation = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableRestitutionPropagation(world_id, p_enabled);
	}
}

bool Box3DWorld::get_enable_restitution_propagation() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_IsRestitutionPropagationEnabled(world_id);
	}
	return enable_restitution_propagation;
}

void Box3DWorld::set_isotropic_inertia_tolerance(double p_tolerance) {
	isotropic_inertia_tolerance = CLAMP(p_tolerance, 0.0, 1.0);
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_SetIsotropicInertiaTolerance(world_id, (float)isotropic_inertia_tolerance);
	}
}

double Box3DWorld::get_isotropic_inertia_tolerance() const {
	join_async_step();
	if (b3World_IsValid(world_id)) {
		return b3World_GetIsotropicInertiaTolerance(world_id);
	}
	return isotropic_inertia_tolerance;
}

void Box3DWorld::set_enable_sse2_fallback(bool p_enabled) {
	enable_sse2_fallback = p_enabled;
	if (b3World_IsValid(world_id)) {
		join_async_step();
		b3World_EnableSSE2Fallback(world_id, p_enabled);
	}
}

bool Box3DWorld::get_enable_sse2_fallback() const {
	return enable_sse2_fallback;
}

void Box3DWorld::apply_mix_callbacks() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	join_async_step();
	b3World_SetFrictionCallback(world_id, mix_fn(friction_mix));
	b3World_SetRestitutionCallback(world_id, mix_fn(restitution_mix));
}

void Box3DWorld::set_friction_mix(int p_rule) {
	friction_mix = CLAMP(p_rule, (int)MIX_DEFAULT, (int)MIX_GEOMETRIC);
	apply_mix_callbacks();
}

int Box3DWorld::get_friction_mix() const {
	return friction_mix;
}

void Box3DWorld::set_restitution_mix(int p_rule) {
	restitution_mix = CLAMP(p_rule, (int)MIX_DEFAULT, (int)MIX_GEOMETRIC);
	apply_mix_callbacks();
}

int Box3DWorld::get_restitution_mix() const {
	return restitution_mix;
}

void Box3DWorld::dump_memory_stats() {
	join_async_step();
	ensure_world();
	if (b3World_IsValid(world_id)) {
		b3World_DumpMemoryStats(world_id);
	}
}

// Shared result shaping for closest-hit casts.
static Dictionary cast_ctx_to_dict(bool p_hit, const Vector3 &p_pos, const Vector3 &p_normal, float p_fraction, Box3DBody *p_body) {
	Dictionary result;
	result["hit"] = p_hit;
	if (p_hit) {
		result["position"] = p_pos;
		result["normal"] = p_normal;
		result["fraction"] = p_fraction;
		if (p_body != nullptr) {
			result["collider"] = static_cast<Object *>(p_body);
		}
	}
	return result;
}

Array Box3DWorld::overlap_shape(const Dictionary &p_shape, const Transform3D &p_transform, uint32_t p_mask) {
	join_async_step();
	Array result;
	ensure_world();
	ProxyBuffer buf;
	if (!b3World_IsValid(world_id) || !build_proxy(p_shape, p_transform.basis, buf)) {
		return result;
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapShape(world_id, to_b3_pos(p_transform.origin), &buf.proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::cast_shape(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_motion, uint32_t p_mask) {
	join_async_step();
	ensure_world();
	ProxyBuffer buf;
	if (!b3World_IsValid(world_id) || !build_proxy(p_shape, p_transform.basis, buf)) {
		return cast_ctx_to_dict(false, Vector3(), Vector3(), 1.0f, nullptr);
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	CastContext ctx;
	ctx.world = this;
	b3World_CastShape(world_id, to_b3_pos(p_transform.origin), &buf.proxy, to_b3(p_motion), filter, cast_result_cb, &ctx);
	return cast_ctx_to_dict(ctx.hit, to_gd_pos(ctx.point), to_gd(ctx.normal), ctx.fraction, ctx.body);
}

// The *_static queries skip join_async_step() on purpose: upstream documents
// them as safe to run concurrently with b3World_Step (static tree only), which
// is exactly what async_step users need. World creation (ensure_world) cannot
// race a step: a step is only ever in flight on an existing world.
Dictionary Box3DWorld::cast_ray_static(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask) {
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return cast_ctx_to_dict(false, Vector3(), Vector3(), 1.0f, nullptr);
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	CastContext ctx;
	ctx.world = this;
	b3World_CastRay_Static(world_id, to_b3_pos(p_from), to_b3(p_to - p_from), filter, cast_result_cb, &ctx);
	return cast_ctx_to_dict(ctx.hit, to_gd_pos(ctx.point), to_gd(ctx.normal), ctx.fraction, ctx.body);
}

Array Box3DWorld::overlap_aabb_static(const AABB &p_aabb, uint32_t p_mask) {
	Array result;
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return result;
	}
	b3AABB aabb;
	aabb.lowerBound = to_b3(p_aabb.position);
	aabb.upperBound = to_b3(p_aabb.position + p_aabb.size);
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapAABB_Static(world_id, aabb, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Array Box3DWorld::overlap_shape_static(const Dictionary &p_shape, const Transform3D &p_transform, uint32_t p_mask) {
	Array result;
	ensure_world();
	ProxyBuffer buf;
	if (!b3World_IsValid(world_id) || !build_proxy(p_shape, p_transform.basis, buf)) {
		return result;
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	OverlapContext ctx;
	ctx.world = this;
	b3World_OverlapShape_Static(world_id, to_b3_pos(p_transform.origin), &buf.proxy, filter, overlap_result_cb, &ctx);
	for (Box3DBody *body : ctx.bodies) {
		result.push_back(body);
	}
	return result;
}

Dictionary Box3DWorld::cast_shape_static(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_motion, uint32_t p_mask) {
	ensure_world();
	ProxyBuffer buf;
	if (!b3World_IsValid(world_id) || !build_proxy(p_shape, p_transform.basis, buf)) {
		return cast_ctx_to_dict(false, Vector3(), Vector3(), 1.0f, nullptr);
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	CastContext ctx;
	ctx.world = this;
	b3World_CastShape_Static(world_id, to_b3_pos(p_transform.origin), &buf.proxy, to_b3(p_motion), filter, cast_result_cb, &ctx);
	return cast_ctx_to_dict(ctx.hit, to_gd_pos(ctx.point), to_gd(ctx.normal), ctx.fraction, ctx.body);
}

double Box3DWorld::cast_mover(const Vector3 &p_from, const Vector3 &p_motion, double p_radius, double p_height, uint32_t p_mask, const Array &p_exclude) {
	join_async_step();
	ensure_world();
	if (!b3World_IsValid(world_id)) {
		return 1.0;
	}
	float r = (float)p_radius;
	float half = (float)(p_height * 0.5) - r;
	if (half < 0.0f) {
		half = 0.0f;
	}
	b3Capsule mover;
	mover.center1 = b3Vec3{ 0.0f, -half, 0.0f };
	mover.center2 = b3Vec3{ 0.0f, half, 0.0f };
	mover.radius = r;
	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = p_mask;
	std::vector<const Box3DBody *> exclude;
	for (int64_t i = 0; i < p_exclude.size(); ++i) {
		const Box3DBody *b = Object::cast_to<Box3DBody>(p_exclude[i].operator Object *());
		if (b != nullptr) {
			exclude.push_back(b);
		}
	}
	MoverFilterContext ctx{ &exclude };
	return b3World_CastMover(world_id, to_b3_pos(p_from), &mover, to_b3(p_motion), filter,
			exclude.empty() ? nullptr : mover_filter_cb, &ctx);
}

Array Box3DWorld::get_body_move_events() {
	join_async_step();
	Array out;
	if (!b3World_IsValid(world_id)) {
		return out;
	}
	b3BodyEvents events = b3World_GetBodyEvents(world_id);
	for (int i = 0; i < events.moveCount; ++i) {
		const b3BodyMoveEvent &e = events.moveEvents[i];
		Dictionary d;
		if (e.userData != nullptr) {
			d["body"] = static_cast<Object *>(static_cast<Box3DBody *>(e.userData));
		}
		d["body_id"] = (int64_t)b3StoreBodyId(e.bodyId);
		d["transform"] = world_xf_to_gd(e.transform);
		d["fell_asleep"] = e.fellAsleep;
		out.push_back(d);
	}
	return out;
}

void Box3DWorld::dispatch_joint_events() {
	if (!b3World_IsValid(world_id)) {
		return;
	}
	b3JointEvents events = b3World_GetJointEvents(world_id);
	if (events.count <= 0) {
		return;
	}
	// Copy first: a handler may destroy joints, which invalidates engine data.
	std::vector<b3JointEvent> copy(events.jointEvents, events.jointEvents + events.count);
	for (const b3JointEvent &e : copy) {
		// Every Box3DJoint stores itself as the joint's b3 user data;
		// from_joint_id resolves (and validates) it. Null if the lookup fails.
		Object *joint = static_cast<Object *>(Box3DJoint::from_joint_id(e.jointId));
		emit_signal("joint_event", joint, (int64_t)b3StoreJointId(e.jointId));
	}
}

Dictionary Box3DWorld::get_debug_draw_data(const Dictionary &p_options, int64_t p_mask) {
	join_async_step();
	ensure_world();
	Dictionary out;
	if (!b3World_IsValid(world_id)) {
		return out;
	}
	DrawCollector c;
	c.world = this;
	b3DebugDraw draw = b3DefaultDebugDraw();
	draw.DrawShapeFcn = draw_shape_cb;
	draw.DrawSegmentFcn = draw_segment_cb;
	draw.DrawTransformFcn = draw_transform_cb;
	draw.DrawPointFcn = draw_point_cb;
	draw.DrawSphereFcn = draw_sphere_cb;
	draw.DrawCapsuleFcn = draw_capsule_cb;
	draw.DrawBoundsFcn = draw_bounds_cb;
	draw.DrawBoxFcn = draw_box_cb;
	draw.DrawStringFcn = draw_string_cb;
	draw.context = &c;

	// Default drawing bounds: the whole simulation (falls back to Box3D's
	// +/-100 m box for an empty world).
	if (p_options.has("drawing_bounds")) {
		AABB a = p_options["drawing_bounds"];
		draw.drawingBounds.lowerBound = to_b3(a.position);
		draw.drawingBounds.upperBound = to_b3(a.position + a.size);
	} else {
		b3AABB wb = b3World_GetBounds(world_id);
		if (wb.lowerBound.x <= wb.upperBound.x && wb.lowerBound.y <= wb.upperBound.y && wb.lowerBound.z <= wb.upperBound.z) {
			draw.drawingBounds = wb;
		}
	}
	draw.forceScale = (float)(double)p_options.get("force_scale", draw.forceScale);
	draw.jointScale = (float)(double)p_options.get("joint_scale", draw.jointScale);
	draw.drawShapes = p_options.get("draw_shapes", true);
	draw.drawJoints = p_options.get("draw_joints", false);
	draw.drawJointExtras = p_options.get("draw_joint_extras", false);
	draw.drawBounds = p_options.get("draw_bounds", false);
	draw.drawMass = p_options.get("draw_mass", false);
	draw.drawSleep = p_options.get("draw_sleep", false);
	draw.drawBodyNames = p_options.get("draw_body_names", false);
	draw.drawContacts = p_options.get("draw_contacts", false);
	draw.drawAnchorA = p_options.get("draw_anchor_a", false);
	draw.drawGraphColors = p_options.get("draw_graph_colors", false);
	draw.drawContactFeatures = p_options.get("draw_contact_features", false);
	draw.drawContactNormals = p_options.get("draw_contact_normals", false);
	draw.drawContactForces = p_options.get("draw_contact_forces", false);
	draw.drawIslands = p_options.get("draw_islands", false);

	b3World_Draw(world_id, &draw, (uint64_t)p_mask);

	out["shapes"] = c.shapes;
	out["segments"] = c.segments;
	out["segment_colors"] = c.segment_colors;
	out["points"] = c.points;
	out["point_sizes"] = c.point_sizes;
	out["point_colors"] = c.point_colors;
	out["transforms"] = c.transforms;
	out["spheres"] = c.spheres;
	out["capsules"] = c.capsules;
	out["bounds"] = c.bounds;
	out["boxes"] = c.boxes;
	out["strings"] = c.strings;
	return out;
}

// --- Data-driven custom filter / pre-solve rules -----------------------------
// Box3D runs b3CustomFilterFcn / b3PreSolveFcn on solver worker threads, so
// GDScript can never be called from them. Instead scripts configure rule
// tables here (main thread, after join_async_step()) and the C++ callbacks only
// read them during the step:
//  * body pair rules / layer pair rules disable collision between two bodies
//    or between two collision-layer sets. They are consulted by BOTH the
//    custom filter callback (shapes created with custom filtering enabled) and
//    the pre-solve callback (shapes with pre-solve events enabled, e.g. via
//    Box3DBody.enable_shape_presolve_events(true)).
//  * one-way platforms keep a contact only when the contact normal, measured
//    pointing away from the platform, is within acos(min_dot) of the platform's
//    world-space normal; pre-solve events are enabled on the platform's shapes.

void Box3DWorld::track_filter_body(const Box3DBody *p_body) {
	filter_tracked[p_body] = p_body->get_instance_id();
}

void Box3DWorld::purge_stale_filter_bodies() {
	if (filter_tracked.empty()) {
		return;
	}
	for (auto it = filter_tracked.begin(); it != filter_tracked.end();) {
		const Object *live = ObjectDB::get_instance(it->second);
		if (live == static_cast<const Object *>(it->first)) {
			++it;
			continue;
		}
		const Box3DBody *dead = it->first;
		one_way_rules.erase(dead);
		for (auto p = filter_body_pairs.begin(); p != filter_body_pairs.end();) {
			if (p->first == dead || p->second == dead) {
				p = filter_body_pairs.erase(p);
			} else {
				++p;
			}
		}
		it = filter_tracked.erase(it);
	}
}

static std::pair<const Box3DBody *, const Box3DBody *> ordered_pair(const Box3DBody *a, const Box3DBody *b) {
	return a < b ? std::make_pair(a, b) : std::make_pair(b, a);
}

void Box3DWorld::set_body_pair_collision_enabled(Box3DBody *p_a, Box3DBody *p_b, bool p_enabled) {
	ERR_FAIL_NULL(p_a);
	ERR_FAIL_NULL(p_b);
	join_async_step();
	if (p_enabled) {
		filter_body_pairs.erase(ordered_pair(p_a, p_b));
	} else {
		filter_body_pairs.insert(ordered_pair(p_a, p_b));
		track_filter_body(p_a);
		track_filter_body(p_b);
	}
}

bool Box3DWorld::is_body_pair_collision_enabled(Box3DBody *p_a, Box3DBody *p_b) const {
	return filter_body_pairs.find(ordered_pair(p_a, p_b)) == filter_body_pairs.end();
}

void Box3DWorld::set_layer_pair_collision_enabled(int64_t p_layers_a, int64_t p_layers_b, bool p_enabled) {
	join_async_step();
	uint64_t a = (uint64_t)p_layers_a;
	uint64_t b = (uint64_t)p_layers_b;
	for (size_t i = 0; i < filter_layer_pairs.size(); ++i) {
		const auto &r = filter_layer_pairs[i];
		if ((r.first == a && r.second == b) || (r.first == b && r.second == a)) {
			filter_layer_pairs.erase(filter_layer_pairs.begin() + i);
			break;
		}
	}
	if (!p_enabled) {
		filter_layer_pairs.push_back(std::make_pair(a, b));
	}
}

void Box3DWorld::clear_collision_filters() {
	join_async_step();
	filter_body_pairs.clear();
	filter_layer_pairs.clear();
	one_way_rules.clear();
	filter_tracked.clear();
}

void Box3DWorld::set_one_way_platform(Box3DBody *p_body, const Vector3 &p_normal, double p_min_dot) {
	ERR_FAIL_NULL(p_body);
	join_async_step();
	Vector3 n = p_normal.length_squared() > 0.0 ? p_normal.normalized() : Vector3(0, 1, 0);
	one_way_rules[p_body] = OneWayRule{ to_b3(n), (float)p_min_dot };
	track_filter_body(p_body);
	b3BodyId id = p_body->get_body_id();
	if (b3Body_IsValid(id)) {
		int count = b3Body_GetShapeCount(id);
		std::vector<b3ShapeId> shapes((size_t)(count > 0 ? count : 0));
		if (count > 0) {
			b3Body_GetShapes(id, shapes.data(), count);
		}
		for (b3ShapeId s : shapes) {
			b3Shape_EnablePreSolveEvents(s, true);
		}
	}
}

void Box3DWorld::clear_one_way_platform(Box3DBody *p_body) {
	join_async_step();
	one_way_rules.erase(p_body);
}

bool Box3DWorld::filter_allows_pair(b3ShapeId p_a, b3ShapeId p_b) const {
	if (!filter_layer_pairs.empty()) {
		uint64_t ca = b3Shape_GetFilter(p_a).categoryBits;
		uint64_t cb = b3Shape_GetFilter(p_b).categoryBits;
		for (const auto &r : filter_layer_pairs) {
			if (((ca & r.first) && (cb & r.second)) || ((ca & r.second) && (cb & r.first))) {
				return false;
			}
		}
	}
	if (!filter_body_pairs.empty()) {
		const Box3DBody *a = raw_body_of_shape(p_a);
		const Box3DBody *b = raw_body_of_shape(p_b);
		if (filter_body_pairs.find(ordered_pair(a, b)) != filter_body_pairs.end()) {
			return false;
		}
	}
	return true;
}

bool Box3DWorld::presolve_allows(b3ShapeId p_a, b3ShapeId p_b, b3Vec3 p_normal) const {
	if (!filter_allows_pair(p_a, p_b)) {
		return false;
	}
	if (one_way_rules.empty()) {
		return true;
	}
	// Box3D's normal points from shape A to shape B.
	auto it = one_way_rules.find(raw_body_of_shape(p_a));
	if (it != one_way_rules.end() && b3Dot(p_normal, it->second.normal) < it->second.min_dot) {
		return false;
	}
	it = one_way_rules.find(raw_body_of_shape(p_b));
	if (it != one_way_rules.end() && -b3Dot(p_normal, it->second.normal) < it->second.min_dot) {
		return false;
	}
	return true;
}

void Box3DWorld::_bind_methods() {
	ClassDB::bind_method(D_METHOD("step", "delta"), &Box3DWorld::step);
	ClassDB::bind_method(D_METHOD("raycast", "from", "to", "collision_mask"), &Box3DWorld::raycast, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("overlap_sphere", "center", "radius", "collision_mask"), &Box3DWorld::overlap_sphere, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("shape_cast_sphere", "from", "to", "radius", "collision_mask"), &Box3DWorld::shape_cast_sphere, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("cast_ray_all", "from", "to", "collision_mask"), &Box3DWorld::cast_ray_all, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("explode", "center", "radius", "impulse_per_area", "falloff", "collision_mask"), &Box3DWorld::explode, DEFVAL(0.0), DEFVAL(0xFFFFFFFF));

	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &Box3DWorld::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &Box3DWorld::get_gravity);
	ClassDB::bind_method(D_METHOD("set_substep_count", "count"), &Box3DWorld::set_substep_count);
	ClassDB::bind_method(D_METHOD("get_substep_count"), &Box3DWorld::get_substep_count);
	ClassDB::bind_method(D_METHOD("set_auto_step", "enabled"), &Box3DWorld::set_auto_step);
	ClassDB::bind_method(D_METHOD("get_auto_step"), &Box3DWorld::get_auto_step);
	ClassDB::bind_method(D_METHOD("set_continuous_collision", "enabled"), &Box3DWorld::set_continuous_collision);
	ClassDB::bind_method(D_METHOD("get_continuous_collision"), &Box3DWorld::get_continuous_collision);
	ClassDB::bind_method(D_METHOD("set_max_linear_speed", "speed"), &Box3DWorld::set_max_linear_speed);
	ClassDB::bind_method(D_METHOD("get_max_linear_speed"), &Box3DWorld::get_max_linear_speed);
	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &Box3DWorld::set_worker_count);
	ClassDB::bind_method(D_METHOD("set_async_step", "enabled"), &Box3DWorld::set_async_step);
	ClassDB::bind_method(D_METHOD("get_async_step"), &Box3DWorld::get_async_step);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &Box3DWorld::get_worker_count);
	ClassDB::bind_method(D_METHOD("set_debug_draw", "enabled"), &Box3DWorld::set_debug_draw);
	ClassDB::bind_method(D_METHOD("get_debug_draw"), &Box3DWorld::get_debug_draw);
	ClassDB::bind_method(D_METHOD("set_contact_hertz", "hertz"), &Box3DWorld::set_contact_hertz);
	ClassDB::bind_method(D_METHOD("get_contact_hertz"), &Box3DWorld::get_contact_hertz);
	ClassDB::bind_method(D_METHOD("set_contact_damping", "damping"), &Box3DWorld::set_contact_damping);
	ClassDB::bind_method(D_METHOD("get_contact_damping"), &Box3DWorld::get_contact_damping);
	ClassDB::bind_method(D_METHOD("set_enable_sleep", "enabled"), &Box3DWorld::set_enable_sleep);
	ClassDB::bind_method(D_METHOD("get_enable_sleep"), &Box3DWorld::get_enable_sleep);
	ClassDB::bind_method(D_METHOD("set_enable_warm_starting", "enabled"), &Box3DWorld::set_enable_warm_starting);
	ClassDB::bind_method(D_METHOD("get_enable_warm_starting"), &Box3DWorld::get_enable_warm_starting);

	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "substep_count", PROPERTY_HINT_RANGE, "1,16,1"), "set_substep_count", "get_substep_count");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_step"), "set_auto_step", "get_auto_step");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "continuous_collision"), "set_continuous_collision", "get_continuous_collision");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_linear_speed", PROPERTY_HINT_RANGE, "0,1000,0.1,or_greater"), "set_max_linear_speed", "get_max_linear_speed");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worker_count", PROPERTY_HINT_RANGE, "1,16,1"), "set_worker_count", "get_worker_count");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "async_step"), "set_async_step", "get_async_step");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_draw"), "set_debug_draw", "get_debug_draw");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_hertz", PROPERTY_HINT_RANGE, "0,120,0.1,or_greater"), "set_contact_hertz", "get_contact_hertz");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_damping", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_contact_damping", "get_contact_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_sleep"), "set_enable_sleep", "get_enable_sleep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_warm_starting"), "set_enable_warm_starting", "get_enable_warm_starting");

	// --- Extended core access -------------------------------------------------
	ClassDB::bind_method(D_METHOD("overlap_aabb", "aabb", "collision_mask"), &Box3DWorld::overlap_aabb, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("get_awake_body_count"), &Box3DWorld::get_awake_body_count);
	ClassDB::bind_method(D_METHOD("get_counters"), &Box3DWorld::get_counters);
	ClassDB::bind_method(D_METHOD("get_profile"), &Box3DWorld::get_profile);
	ClassDB::bind_method(D_METHOD("get_bounds"), &Box3DWorld::get_bounds);
	ClassDB::bind_method(D_METHOD("rebuild_static_tree"), &Box3DWorld::rebuild_static_tree);
	ClassDB::bind_method(D_METHOD("set_enable_speculative", "enabled"), &Box3DWorld::set_enable_speculative);
	ClassDB::bind_method(D_METHOD("get_enable_speculative"), &Box3DWorld::get_enable_speculative);
	ClassDB::bind_method(D_METHOD("set_restitution_threshold", "speed"), &Box3DWorld::set_restitution_threshold);
	ClassDB::bind_method(D_METHOD("get_restitution_threshold"), &Box3DWorld::get_restitution_threshold);
	ClassDB::bind_method(D_METHOD("set_hit_event_threshold", "speed"), &Box3DWorld::set_hit_event_threshold);
	ClassDB::bind_method(D_METHOD("get_hit_event_threshold"), &Box3DWorld::get_hit_event_threshold);
	ClassDB::bind_method(D_METHOD("set_contact_recycle_distance", "distance"), &Box3DWorld::set_contact_recycle_distance);
	ClassDB::bind_method(D_METHOD("get_contact_recycle_distance"), &Box3DWorld::get_contact_recycle_distance);
	ClassDB::bind_method(D_METHOD("start_recording", "byte_capacity"), &Box3DWorld::start_recording, DEFVAL(16 * 1024 * 1024));
	ClassDB::bind_method(D_METHOD("stop_recording"), &Box3DWorld::stop_recording);
	ClassDB::bind_method(D_METHOD("is_recording"), &Box3DWorld::is_recording);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("validate_replay", "data", "worker_count"), &Box3DWorld::validate_replay, DEFVAL(1));
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_speculative"), "set_enable_speculative", "get_enable_speculative");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "restitution_threshold", PROPERTY_HINT_RANGE, "0,10,0.01,or_greater"), "set_restitution_threshold", "get_restitution_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hit_event_threshold", PROPERTY_HINT_RANGE, "0,50,0.01,or_greater"), "set_hit_event_threshold", "get_hit_event_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_recycle_distance", PROPERTY_HINT_RANGE, "0,1,0.001,or_greater"), "set_contact_recycle_distance", "get_contact_recycle_distance");

	// --- Extended core access III: full b3World_* coverage ---------------------
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_world_count"), &Box3DWorld::get_world_count);
	ClassDB::bind_static_method("Box3DWorld", D_METHOD("get_max_world_count"), &Box3DWorld::get_max_world_count);
	ClassDB::bind_method(D_METHOD("get_live_gravity"), &Box3DWorld::get_live_gravity);
	ClassDB::bind_method(D_METHOD("is_sleeping_enabled"), &Box3DWorld::is_sleeping_enabled);
	ClassDB::bind_method(D_METHOD("is_continuous_enabled"), &Box3DWorld::is_continuous_enabled);
	ClassDB::bind_method(D_METHOD("is_warm_starting_enabled"), &Box3DWorld::is_warm_starting_enabled);
	ClassDB::bind_method(D_METHOD("get_maximum_linear_speed"), &Box3DWorld::get_maximum_linear_speed);
	ClassDB::bind_method(D_METHOD("get_live_worker_count"), &Box3DWorld::get_live_worker_count);
	ClassDB::bind_method(D_METHOD("get_max_capacity"), &Box3DWorld::get_max_capacity);
	ClassDB::bind_method(D_METHOD("get_user_data"), &Box3DWorld::get_user_data);
	ClassDB::bind_method(D_METHOD("set_restitution_iterations", "iterations"), &Box3DWorld::set_restitution_iterations);
	ClassDB::bind_method(D_METHOD("get_restitution_iterations"), &Box3DWorld::get_restitution_iterations);
	ClassDB::bind_method(D_METHOD("set_enable_restitution_propagation", "enabled"), &Box3DWorld::set_enable_restitution_propagation);
	ClassDB::bind_method(D_METHOD("get_enable_restitution_propagation"), &Box3DWorld::get_enable_restitution_propagation);
	ClassDB::bind_method(D_METHOD("set_isotropic_inertia_tolerance", "tolerance"), &Box3DWorld::set_isotropic_inertia_tolerance);
	ClassDB::bind_method(D_METHOD("get_isotropic_inertia_tolerance"), &Box3DWorld::get_isotropic_inertia_tolerance);
	ClassDB::bind_method(D_METHOD("set_enable_sse2_fallback", "enabled"), &Box3DWorld::set_enable_sse2_fallback);
	ClassDB::bind_method(D_METHOD("get_enable_sse2_fallback"), &Box3DWorld::get_enable_sse2_fallback);
	ClassDB::bind_method(D_METHOD("set_friction_mix", "rule"), &Box3DWorld::set_friction_mix);
	ClassDB::bind_method(D_METHOD("get_friction_mix"), &Box3DWorld::get_friction_mix);
	ClassDB::bind_method(D_METHOD("set_restitution_mix", "rule"), &Box3DWorld::set_restitution_mix);
	ClassDB::bind_method(D_METHOD("get_restitution_mix"), &Box3DWorld::get_restitution_mix);
	ClassDB::bind_method(D_METHOD("dump_memory_stats"), &Box3DWorld::dump_memory_stats);
	ClassDB::bind_method(D_METHOD("overlap_shape", "shape", "transform", "collision_mask"), &Box3DWorld::overlap_shape, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("cast_shape", "shape", "transform", "motion", "collision_mask"), &Box3DWorld::cast_shape, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("cast_ray_static", "from", "to", "collision_mask"), &Box3DWorld::cast_ray_static, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("overlap_aabb_static", "aabb", "collision_mask"), &Box3DWorld::overlap_aabb_static, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("overlap_shape_static", "shape", "transform", "collision_mask"), &Box3DWorld::overlap_shape_static, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("cast_shape_static", "shape", "transform", "motion", "collision_mask"), &Box3DWorld::cast_shape_static, DEFVAL(0xFFFFFFFF));
	ClassDB::bind_method(D_METHOD("cast_mover", "from", "motion", "radius", "height", "collision_mask", "exclude"), &Box3DWorld::cast_mover, DEFVAL(0xFFFFFFFF), DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("get_body_move_events"), &Box3DWorld::get_body_move_events);
	ClassDB::bind_method(D_METHOD("get_debug_draw_data", "options", "mask"), &Box3DWorld::get_debug_draw_data, DEFVAL(Dictionary()), DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("set_body_pair_collision_enabled", "body_a", "body_b", "enabled"), &Box3DWorld::set_body_pair_collision_enabled);
	ClassDB::bind_method(D_METHOD("is_body_pair_collision_enabled", "body_a", "body_b"), &Box3DWorld::is_body_pair_collision_enabled);
	ClassDB::bind_method(D_METHOD("set_layer_pair_collision_enabled", "layers_a", "layers_b", "enabled"), &Box3DWorld::set_layer_pair_collision_enabled);
	ClassDB::bind_method(D_METHOD("clear_collision_filters"), &Box3DWorld::clear_collision_filters);
	ClassDB::bind_method(D_METHOD("set_one_way_platform", "body", "normal", "min_dot"), &Box3DWorld::set_one_way_platform, DEFVAL(Vector3(0, 1, 0)), DEFVAL(0.5));
	ClassDB::bind_method(D_METHOD("clear_one_way_platform", "body"), &Box3DWorld::clear_one_way_platform);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "restitution_iterations", PROPERTY_HINT_RANGE, "0,63,1"), "set_restitution_iterations", "get_restitution_iterations");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_restitution_propagation"), "set_enable_restitution_propagation", "get_enable_restitution_propagation");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "isotropic_inertia_tolerance", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_isotropic_inertia_tolerance", "get_isotropic_inertia_tolerance");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enable_sse2_fallback"), "set_enable_sse2_fallback", "get_enable_sse2_fallback");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "friction_mix", PROPERTY_HINT_ENUM, "Default,Average,Min,Max,Multiply,Geometric"), "set_friction_mix", "get_friction_mix");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "restitution_mix", PROPERTY_HINT_ENUM, "Default,Average,Min,Max,Multiply,Geometric"), "set_restitution_mix", "get_restitution_mix");

	ADD_SIGNAL(MethodInfo("joint_event", PropertyInfo(Variant::OBJECT, "joint", PROPERTY_HINT_NODE_TYPE, "Box3DJoint"), PropertyInfo(Variant::INT, "joint_id")));

	BIND_ENUM_CONSTANT(MIX_DEFAULT);
	BIND_ENUM_CONSTANT(MIX_AVERAGE);
	BIND_ENUM_CONSTANT(MIX_MIN);
	BIND_ENUM_CONSTANT(MIX_MAX);
	BIND_ENUM_CONSTANT(MIX_MULTIPLY);
	BIND_ENUM_CONSTANT(MIX_GEOMETRIC);
}
