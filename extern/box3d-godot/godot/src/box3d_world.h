// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT

#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <box3d/box3d.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <set>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace godot {

class Box3DBody;
class MultiMeshInstance3D;

// A Box3DWorld owns a Box3D simulation. Add Box3DBody nodes anywhere beneath it.
// The world drives the simulation every physics frame: it pushes kinematic
// bodies in, steps Box3D, then reads dynamic bodies out.
class Box3DWorld : public Node3D {
	GDCLASS(Box3DWorld, Node3D)

public:
	// Friction / restitution mixing rules (b3World_SetFrictionCallback /
	// b3World_SetRestitutionCallback). MIX_DEFAULT keeps the engine's rule:
	// sqrt(a*b) for friction, max(a, b) for restitution.
	enum MixRule {
		MIX_DEFAULT,
		MIX_AVERAGE,
		MIX_MIN,
		MIX_MAX,
		MIX_MULTIPLY,
		MIX_GEOMETRIC,
	};

private:
	b3WorldId world_id = b3_nullWorldId;
	Vector3 gravity = Vector3(0, -9.8f, 0);
	int substep_count = 4;
	bool auto_step = true;
	bool continuous_collision = true;
	double max_linear_speed = 0.0; // 0 = keep Box3D's default
	int worker_count = 1; // >1 enables Box3D's internal multithreaded solver
	bool debug_draw = false;
	// Solver tuning, forwarded to b3World_SetContactTuning. Hertz follows
	// upstream's sample app default (60; the core's b3DefaultWorldDef is 30),
	// damping matches the core, at 1 length unit per meter (this binding
	// never changes that scale).
	double contact_hertz = 60.0;
	double contact_damping = 10.0;
	bool enable_sleep = true;
	bool enable_warm_starting = true;
	// Debug draw: solid state-colored collider shells, upstream-sample style.
	// One MultiMesh per primitive keeps huge scenes at a few draw calls.
	enum DebugPrim {
		DEBUG_BOX,
		DEBUG_SPHERE,
		DEBUG_CAPSULE,
		DEBUG_CYLINDER,
		DEBUG_CONE,
		DEBUG_PRIM_MAX,
	};
	MultiMeshInstance3D *debug_mm[DEBUG_PRIM_MAX] = {};
	PackedFloat32Array debug_buffer[DEBUG_PRIM_MAX]; // reused bulk upload buffers
	bool debug_last_any_awake = false;
	int debug_last_body_count = -1; // -1 forces a rebuild on the next step
	// Synchronous mode only refreshes the shells after a step actually ran:
	// between ticks the solver data is frozen, so re-reading it every rendered
	// frame (144+ Hz vs 60 Hz physics) was pure waste. Async mode refreshes
	// from apply_step_results and never reads this flag.
	bool debug_step_dirty = true;
	double last_step_delta = 1.0 / 60.0; // for the fast-body debug criterion
	std::vector<Box3DBody *> bodies;

	// Asynchronous stepping. When async_step is on, b3World_Step runs on a
	// dedicated thread while the engine renders; results are applied at the
	// start of the NEXT physics frame. If a step overruns a whole physics
	// frame, that tick is skipped (the sim briefly lags real time) instead of
	// stalling rendering. Any API call that touches the Box3D world first
	// calls join_async_step() so scripts never race the solver.
	// Extended core access state. Thresholds < 0 mean "engine default, never
	// touched"; setters cache the value so worlds created later inherit it.
	bool enable_speculative = true;
	double restitution_threshold = -1.0;
	double hit_event_threshold = -1.0;
	double contact_recycle_distance = -1.0;
	b3Recording *recording = nullptr;

	// Extended core access III state (cached, applied at world creation).
	int restitution_iterations = 2; // b3DefaultWorldDef
	bool enable_restitution_propagation = false; // b3DefaultWorldDef
	double isotropic_inertia_tolerance = 0.2; // b3DefaultWorldDef
	bool enable_sse2_fallback = false;
	int friction_mix = MIX_DEFAULT;
	int restitution_mix = MIX_DEFAULT;

	// Data-driven solver callbacks. These tables are READ from Box3D worker
	// threads during b3World_Step and only WRITTEN on the main thread after
	// join_async_step(), so no step ever overlaps a mutation (no lock needed).
	struct OneWayRule {
		b3Vec3 normal;
		float min_dot;
	};
	std::set<std::pair<const Box3DBody *, const Box3DBody *>> filter_body_pairs;
	std::vector<std::pair<uint64_t, uint64_t>> filter_layer_pairs;
	std::unordered_map<const Box3DBody *, OneWayRule> one_way_rules;
	// Instance ids of every body referenced above; validated on the main
	// thread before each step so a freed body never leaves a stale pointer.
	std::unordered_map<const Box3DBody *, uint64_t> filter_tracked;
	void track_filter_body(const Box3DBody *p_body);
	void purge_stale_filter_bodies();
	void apply_mix_callbacks();

	bool async_step = false;
	std::thread step_thread;
	mutable std::mutex step_mutex;
	mutable std::condition_variable step_cv;
	bool worker_busy = false; // guarded by step_mutex
	bool worker_exit = false; // guarded by step_mutex
	double worker_dt = 1.0 / 60.0; // guarded by step_mutex
	int worker_substeps = 4; // guarded by step_mutex
	mutable std::atomic<bool> step_inflight{ false };
	mutable bool step_pending_apply = false; // main thread only

	void ensure_world();
	void dispatch_contact_events();
	void dispatch_sensor_events();
	void dispatch_joint_events();
	void update_debug_draw();
	void apply_contact_tuning();
	void async_thread_main();
	void launch_async_step(double p_delta);
	void apply_step_results();
	void stop_step_thread();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Box3DWorld();
	~Box3DWorld();

	// Internal: returns a valid world id, creating the world on demand.
	b3WorldId get_world_id();
	bool is_world_alive() const;
	void register_body(Box3DBody *p_body);
	void unregister_body(Box3DBody *p_body);

	// Advance the simulation by delta seconds (called automatically when
	// auto_step is enabled, or manually from script). With async_step enabled
	// this launches the step in the background and returns immediately; if the
	// previous step is still running the call is a no-op (the tick is skipped).
	void step(double p_delta);

	// Blocks until any in-flight async step finishes (no-op otherwise). Every
	// wrapper method that touches the b3 API calls this first; the fast path
	// is a single relaxed atomic load. Results are applied on the next tick.
	void join_async_step() const;

	void set_async_step(bool p_enabled);
	bool get_async_step() const;

	void set_gravity(const Vector3 &p_gravity);
	Vector3 get_gravity() const;
	void set_substep_count(int p_count);
	int get_substep_count() const;
	void set_auto_step(bool p_enabled);
	bool get_auto_step() const;
	void set_continuous_collision(bool p_enabled);
	bool get_continuous_collision() const;
	void set_max_linear_speed(double p_speed);
	double get_max_linear_speed() const;
	void set_worker_count(int p_count);
	int get_worker_count() const;
	void set_debug_draw(bool p_enabled);
	bool get_debug_draw() const;
	void set_contact_hertz(double p_hertz);
	double get_contact_hertz() const;
	void set_contact_damping(double p_damping);
	double get_contact_damping() const;
	void set_enable_sleep(bool p_enabled);
	bool get_enable_sleep() const;
	void set_enable_warm_starting(bool p_enabled);
	bool get_enable_warm_starting() const;

	// Cast a ray from -> to. Returns a Dictionary:
	//   { hit: bool, position: Vector3, normal: Vector3,
	//     fraction: float, collider: Box3DBody }
	Dictionary raycast(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask = 0xFFFFFFFFu);

	// Maps a shape to the Box3DBody that owns it (via userData). Public so the
	// query callbacks can use it.
	Box3DBody *body_from_shape(b3ShapeId p_shape);

	// Queries.
	Array overlap_sphere(const Vector3 &p_center, double p_radius, uint32_t p_mask = 0xFFFFFFFFu);
	Array overlap_aabb(const AABB &p_aabb, uint32_t p_mask = 0xFFFFFFFFu);
	Dictionary shape_cast_sphere(const Vector3 &p_from, const Vector3 &p_to, double p_radius, uint32_t p_mask = 0xFFFFFFFFu);
	// Like raycast but returns EVERY shape crossed from -> to (raycast returns
	// only the closest). Array of { position, normal, fraction, collider },
	// unsorted; sort by fraction if near-to-far order is needed.
	Array cast_ray_all(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask = 0xFFFFFFFFu);
	void explode(const Vector3 &p_center, double p_radius, double p_impulse_per_area, double p_falloff = 0.0, uint32_t p_mask = 0xFFFFFFFFu);

	// --- Extended core access -------------------------------------------------
	// Live diagnostics straight from the engine (perf HUDs, tests).
	int get_awake_body_count() const;
	Dictionary get_counters() const;
	Dictionary get_profile() const;
	AABB get_bounds() const;
	void rebuild_static_tree();

	// Solver knobs previously locked away in b3WorldDef.
	void set_enable_speculative(bool p_enabled);
	bool get_enable_speculative() const;
	void set_restitution_threshold(double p_speed);
	double get_restitution_threshold() const;
	void set_hit_event_threshold(double p_speed);
	double get_hit_event_threshold() const;
	void set_contact_recycle_distance(double p_distance);
	double get_contact_recycle_distance() const;

	// Deterministic recording (upstream src/recording.c): capture every API
	// call + initial snapshot; the buffer replays bit-exact.
	bool start_recording(int p_byte_capacity = 16 * 1024 * 1024);
	PackedByteArray stop_recording();
	bool is_recording() const;
	static bool validate_replay(const PackedByteArray &p_data, int p_worker_count = 1);

	// --- Extended core access III: full b3World_* coverage ---------------------
	static int get_world_count();
	static int get_max_world_count();

	// Live engine reads (the matching property getters return cached values and
	// never join an async step; these join and ask Box3D directly).
	Vector3 get_live_gravity() const;
	bool is_sleeping_enabled() const;
	bool is_continuous_enabled() const;
	bool is_warm_starting_enabled() const;
	double get_maximum_linear_speed() const; // effective value (engine default when 0)
	int get_live_worker_count() const;
	Dictionary get_max_capacity() const;
	Object *get_user_data() const; // b3World_GetUserData: the owning Box3DWorld

	void set_restitution_iterations(int p_iterations);
	int get_restitution_iterations() const;
	void set_enable_restitution_propagation(bool p_enabled);
	bool get_enable_restitution_propagation() const;
	void set_isotropic_inertia_tolerance(double p_tolerance);
	double get_isotropic_inertia_tolerance() const;
	void set_enable_sse2_fallback(bool p_enabled);
	bool get_enable_sse2_fallback() const;
	void set_friction_mix(int p_rule);
	int get_friction_mix() const;
	void set_restitution_mix(int p_rule);
	int get_restitution_mix() const;

	void dump_memory_stats();

	// General shape queries. `shape` is a Dictionary descriptor:
	//   { type = "sphere",  radius }
	//   { type = "capsule", radius, height }        (Y axis, total height)
	//   { type = "box",     size: Vector3 [, radius] }   (full extents)
	//   { type = "points",  points: PackedVector3Array [, radius] } (convex)
	// `transform` places the shape in world space.
	Array overlap_shape(const Dictionary &p_shape, const Transform3D &p_transform, uint32_t p_mask = 0xFFFFFFFFu);
	Dictionary cast_shape(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_motion, uint32_t p_mask = 0xFFFFFFFFu);
	// Static-only variants (b3World_*_Static): only static bodies are tested
	// and, by upstream design, these may run while an async step is in flight,
	// so they deliberately do NOT join the async step.
	Dictionary cast_ray_static(const Vector3 &p_from, const Vector3 &p_to, uint32_t p_mask = 0xFFFFFFFFu);
	Array overlap_aabb_static(const AABB &p_aabb, uint32_t p_mask = 0xFFFFFFFFu);
	Array overlap_shape_static(const Dictionary &p_shape, const Transform3D &p_transform, uint32_t p_mask = 0xFFFFFFFFu);
	Dictionary cast_shape_static(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_motion, uint32_t p_mask = 0xFFFFFFFFu);
	// Capsule mover sweep (b3World_CastMover). Capsule is Y-aligned, centered on
	// `from`; returns the fraction [0, 1] of `motion` that can be travelled.
	double cast_mover(const Vector3 &p_from, const Vector3 &p_motion, double p_radius, double p_height, uint32_t p_mask = 0xFFFFFFFFu, const Array &p_exclude = Array());

	// Events.
	Array get_body_move_events();

	// Debug draw (b3World_Draw) collected into plain data.
	Dictionary get_debug_draw_data(const Dictionary &p_options = Dictionary(), int64_t p_mask = -1);

	// Data-driven custom filter / pre-solve rules (thread-safe; see .cpp).
	void set_body_pair_collision_enabled(Box3DBody *p_a, Box3DBody *p_b, bool p_enabled);
	bool is_body_pair_collision_enabled(Box3DBody *p_a, Box3DBody *p_b) const;
	void set_layer_pair_collision_enabled(int64_t p_layers_a, int64_t p_layers_b, bool p_enabled);
	void clear_collision_filters();
	void set_one_way_platform(Box3DBody *p_body, const Vector3 &p_normal = Vector3(0, 1, 0), double p_min_dot = 0.5);
	void clear_one_way_platform(Box3DBody *p_body);

	// Internal: called from Box3D worker threads. Never touch Godot here.
	bool filter_allows_pair(b3ShapeId p_a, b3ShapeId p_b) const;
	bool presolve_allows(b3ShapeId p_a, b3ShapeId p_b, b3Vec3 p_normal) const;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DWorld::MixRule);
