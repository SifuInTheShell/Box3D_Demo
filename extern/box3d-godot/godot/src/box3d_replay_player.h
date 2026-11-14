// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// --- Extended core access III: replay playback ---
//
// Box3DReplayPlayer wraps Box3D's incremental recording player (b3RecPlayer):
// it re-simulates a recording produced by Box3DWorld.start_recording() /
// stop_recording() inside a private replay world, frame by frame, with a
// keyframe ring for fast backward seeking and StateHash divergence checks.
//
// Typical GDScript usage:
//
//   var bytes := world.stop_recording()                 # or Box3DReplayPlayer.load_recording(path)
//   var player := Box3DReplayPlayer.create(bytes, 1)    # null on a bad recording
//   var info := player.get_info()                       # frame_count, time_step, bounds, ...
//   while not player.is_at_end():
//       player.step_frame()
//       for xf in player.get_body_transforms():        # Transform3D, or null for destroyed bodies
//           ...
//       var dd := player.draw_frame_queries()           # Dictionary of packed primitive arrays
//   player.seek_frame(10)                               # backward seek restores a keyframe
//
// The player owns a private copy of the recording bytes and its own world; the
// world id changes on set_debug_shape_tracking(), so never cache it. All calls
// are no-ops returning neutral values when no recording is open.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>

#include <cstdint>
#include <unordered_map>

namespace godot {

class Box3DReplayPlayer : public RefCounted {
	GDCLASS(Box3DReplayPlayer, RefCounted)

public:
	// Mirrors b3RecQueryType.
	enum QueryType {
		QUERY_OVERLAP_AABB = b3_recQueryOverlapAABB,
		QUERY_OVERLAP_SHAPE = b3_recQueryOverlapShape,
		QUERY_CAST_RAY = b3_recQueryCastRay,
		QUERY_CAST_SHAPE = b3_recQueryCastShape,
		QUERY_CAST_RAY_CLOSEST = b3_recQueryCastRayClosest,
		QUERY_CAST_MOVER = b3_recQueryCastMover,
		QUERY_COLLIDE_MOVER = b3_recQueryCollideMover,
	};

	// Registry entry for a replayed shape created through the debug-shape
	// callbacks (see set_debug_shape_tracking).
	struct DebugShapeRecord {
		uintptr_t handle = 0;
		uint64_t shape_key = 0;
		int type = 0;
		b3Vec3 center1 = { 0.0f, 0.0f, 0.0f };
		b3Vec3 center2 = { 0.0f, 0.0f, 0.0f };
		float radius = 0.0f;
	};

private:
	b3RecPlayer *player = nullptr;

	bool debug_shape_tracking = false;
	uintptr_t next_debug_handle = 1;
	std::unordered_map<uint64_t, DebugShapeRecord> debug_shapes; // keyed by stored shape id
	std::unordered_map<uintptr_t, uint64_t> debug_handles; // user handle -> stored shape id

	static void *_create_debug_shape(const b3DebugShape *p_shape, void *p_context);
	static void _destroy_debug_shape(void *p_user_shape, void *p_context);
	void _clear_debug_shapes();

	b3BodyId _body(int p_index) const;

protected:
	static void _bind_methods();

public:
	Box3DReplayPlayer() = default;
	~Box3DReplayPlayer();

	// Lifecycle (b3CreatePlayer / b3DestroyPlayer).
	bool open(const PackedByteArray &p_data, int p_worker_count = 1);
	void close();
	bool is_open() const;
	static Ref<Box3DReplayPlayer> create(const PackedByteArray &p_data, int p_worker_count = 1);
	static Ref<Box3DReplayPlayer> create_from_file(const String &p_path, int p_worker_count = 1);

	// Playback.
	bool step_frame();
	void sub_step_frame();
	void restart();
	void seek_frame(int p_frame);
	int get_frame() const;
	int get_frame_count() const;
	bool is_at_end() const;
	bool is_at_pre_step() const;
	bool has_diverged() const;
	int get_diverge_frame() const;
	Dictionary get_info() const;
	int64_t get_world_id() const;
	bool is_world_valid() const;
	void set_worker_count(int p_count);

	// Keyframe ring.
	void set_keyframe_policy(int64_t p_budget_bytes, int p_min_interval_frames);
	int64_t get_keyframe_budget() const;
	int get_keyframe_min_interval() const;
	int get_keyframe_interval() const;
	int64_t get_keyframe_bytes() const;

	// Body readout from the replay world (creation-ordinal indexed).
	int get_body_count() const;
	int64_t get_body_id(int p_index) const;
	bool is_body_valid(int p_index) const;
	Transform3D get_body_transform(int p_index) const;
	Vector3 get_body_position(int p_index) const;
	Quaternion get_body_rotation(int p_index) const;
	Vector3 get_body_linear_velocity(int p_index) const;
	Vector3 get_body_angular_velocity(int p_index) const;
	int get_body_type(int p_index) const;
	bool is_body_awake(int p_index) const;
	String get_body_name(int p_index) const;
	Array get_body_transforms() const;

	// Recorded spatial queries of the most recently replayed frame.
	int get_frame_query_count() const;
	Dictionary get_frame_query(int p_index) const;
	Dictionary get_frame_query_hit(int p_query_index, int p_hit_index) const;
	Array get_frame_queries() const;
	Dictionary draw_frame_queries(int p_query_index = -1, int p_selected_index = -1);

	// Debug drawing of the replay world (b3World_Draw on the player's world).
	Dictionary draw_world(const Dictionary &p_options = Dictionary(), int64_t p_mask_bits = -1);

	// Debug-shape callbacks (b3RecPlayer_SetDebugShapeCallbacks).
	void set_debug_shape_tracking(bool p_enabled);
	bool is_debug_shape_tracking() const;
	Array get_debug_shapes() const;

	// Recording files.
	static bool save_recording(const PackedByteArray &p_data, const String &p_path);
	static PackedByteArray load_recording(const String &p_path);
	static PackedByteArray load_recording_from_file(const String &p_path);
};

} // namespace godot

VARIANT_ENUM_CAST(godot::Box3DReplayPlayer::QueryType);
