// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// --- Extended core access III: replay playback ---
//
// See box3d_replay_player.h for usage. Notes on the C callback surfaces:
//
// * b3RecPlayer_DrawFrameQueries / b3World_Draw take a b3DebugDraw of C function
//   pointers. GDScript cannot provide those, so draw_frame_queries() and
//   draw_world() install internal collectors and return every primitive emitted
//   in a Dictionary of packed arrays (see _collector_to_dict for the keys).
// * b3RecPlayer_SetDebugShapeCallbacks takes create/destroy callbacks that hand
//   back an opaque per-shape render handle. From GDScript the useful part is
//   knowing which shapes exist and being able to match DrawShapeFcn calls to
//   them, so set_debug_shape_tracking(true) installs internal callbacks that keep
//   a registry (shape id, type, sphere/capsule geometry) readable with
//   get_debug_shapes(), and draw_world() then reports per-shape draws by shape id.

#include "box3d_replay_player.h"

#include "box3d_conversions.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

using namespace godot;

namespace {

// b3WorldTransform is b3Transform in single precision and a distinct
// double-position struct in large-world builds; this works for both.
Transform3D wt_to_gd(const b3WorldTransform &t) {
	return Transform3D(Basis(to_gd(t.q)), to_gd_pos(t.p));
}

AABB aabb_to_gd(const b3AABB &b) {
	Vector3 lo = to_gd(b.lowerBound);
	Vector3 hi = to_gd(b.upperBound);
	return AABB(lo, hi - lo);
}

b3AABB aabb_to_b3(const AABB &a) {
	b3AABB r;
	r.lowerBound = to_b3(a.position);
	r.upperBound = to_b3(a.position + a.size);
	return r;
}

Color hex_to_color(b3HexColor c, float alpha = 1.0f) {
	uint32_t h = (uint32_t)c;
	return Color(((h >> 16) & 0xFF) / 255.0f, ((h >> 8) & 0xFF) / 255.0f, (h & 0xFF) / 255.0f, alpha);
}

String cstr(const char *s) {
	return s != nullptr ? String::utf8(s) : String();
}

// Collects every primitive a b3DebugDraw emits.
struct DrawCollector {
	const std::unordered_map<uintptr_t, uint64_t> *handles = nullptr;

	PackedInt64Array shape_ids;
	Array shape_transforms;
	PackedColorArray shape_colors;

	PackedVector3Array segments; // pairs
	PackedColorArray segment_colors; // one per segment

	Array transforms;

	PackedVector3Array points;
	PackedFloat32Array point_sizes;
	PackedColorArray point_colors;

	PackedVector3Array sphere_centers;
	PackedFloat32Array sphere_radii;
	PackedColorArray sphere_colors; // alpha carries the draw alpha

	PackedVector3Array capsule_p1;
	PackedVector3Array capsule_p2;
	PackedFloat32Array capsule_radii;
	PackedColorArray capsule_colors;

	Array bounds;
	PackedColorArray bounds_colors;

	PackedVector3Array box_extents;
	Array box_transforms;
	PackedColorArray box_colors;

	PackedVector3Array string_positions;
	PackedStringArray string_texts;
	PackedColorArray string_colors;

	Dictionary to_dict() const {
		Dictionary d;
		d["shape_ids"] = shape_ids;
		d["shape_transforms"] = shape_transforms;
		d["shape_colors"] = shape_colors;
		d["segments"] = segments;
		d["segment_colors"] = segment_colors;
		d["transforms"] = transforms;
		d["points"] = points;
		d["point_sizes"] = point_sizes;
		d["point_colors"] = point_colors;
		d["sphere_centers"] = sphere_centers;
		d["sphere_radii"] = sphere_radii;
		d["sphere_colors"] = sphere_colors;
		d["capsule_p1"] = capsule_p1;
		d["capsule_p2"] = capsule_p2;
		d["capsule_radii"] = capsule_radii;
		d["capsule_colors"] = capsule_colors;
		d["bounds"] = bounds;
		d["bounds_colors"] = bounds_colors;
		d["box_extents"] = box_extents;
		d["box_transforms"] = box_transforms;
		d["box_colors"] = box_colors;
		d["string_positions"] = string_positions;
		d["string_texts"] = string_texts;
		d["string_colors"] = string_colors;
		return d;
	}

	static DrawCollector *self(void *ctx) { return static_cast<DrawCollector *>(ctx); }

	static void draw_shape(void *user_shape, b3WorldTransform transform, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		int64_t id = 0;
		if (c->handles != nullptr) {
			auto it = c->handles->find((uintptr_t)user_shape);
			if (it != c->handles->end()) {
				id = (int64_t)it->second;
			}
		}
		c->shape_ids.push_back(id);
		c->shape_transforms.push_back(wt_to_gd(transform));
		c->shape_colors.push_back(hex_to_color(color));
	}
	static void draw_segment(b3Pos p1, b3Pos p2, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		c->segments.push_back(to_gd_pos(p1));
		c->segments.push_back(to_gd_pos(p2));
		c->segment_colors.push_back(hex_to_color(color));
	}
	static void draw_transform(b3WorldTransform transform, void *ctx) {
		self(ctx)->transforms.push_back(wt_to_gd(transform));
	}
	static void draw_point(b3Pos p, float size, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		c->points.push_back(to_gd_pos(p));
		c->point_sizes.push_back(size);
		c->point_colors.push_back(hex_to_color(color));
	}
	static void draw_sphere(b3Pos p, float radius, b3HexColor color, float alpha, void *ctx) {
		DrawCollector *c = self(ctx);
		c->sphere_centers.push_back(to_gd_pos(p));
		c->sphere_radii.push_back(radius);
		c->sphere_colors.push_back(hex_to_color(color, alpha));
	}
	static void draw_capsule(b3Pos p1, b3Pos p2, float radius, b3HexColor color, float alpha, void *ctx) {
		DrawCollector *c = self(ctx);
		c->capsule_p1.push_back(to_gd_pos(p1));
		c->capsule_p2.push_back(to_gd_pos(p2));
		c->capsule_radii.push_back(radius);
		c->capsule_colors.push_back(hex_to_color(color, alpha));
	}
	static void draw_bounds(b3AABB aabb, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		c->bounds.push_back(aabb_to_gd(aabb));
		c->bounds_colors.push_back(hex_to_color(color));
	}
	static void draw_box(b3Vec3 extents, b3WorldTransform transform, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		c->box_extents.push_back(to_gd(extents));
		c->box_transforms.push_back(wt_to_gd(transform));
		c->box_colors.push_back(hex_to_color(color));
	}
	static void draw_string(b3Pos p, const char *s, b3HexColor color, void *ctx) {
		DrawCollector *c = self(ctx);
		c->string_positions.push_back(to_gd_pos(p));
		c->string_texts.push_back(cstr(s));
		c->string_colors.push_back(hex_to_color(color));
	}

	void install(b3DebugDraw &draw) {
		draw.DrawShapeFcn = &draw_shape;
		draw.DrawSegmentFcn = &draw_segment;
		draw.DrawTransformFcn = &draw_transform;
		draw.DrawPointFcn = &draw_point;
		draw.DrawSphereFcn = &draw_sphere;
		draw.DrawCapsuleFcn = &draw_capsule;
		draw.DrawBoundsFcn = &draw_bounds;
		draw.DrawBoxFcn = &draw_box;
		draw.DrawStringFcn = &draw_string;
		draw.context = this;
	}
};

void apply_draw_options(b3DebugDraw &draw, const Dictionary &o) {
	if (o.has("drawing_bounds")) {
		draw.drawingBounds = aabb_to_b3(o["drawing_bounds"]);
	}
	if (o.has("force_scale")) {
		draw.forceScale = (float)(double)o["force_scale"];
	}
	if (o.has("joint_scale")) {
		draw.jointScale = (float)(double)o["joint_scale"];
	}
#define B3R_FLAG(key, field) \
	if (o.has(key)) {        \
		draw.field = o[key]; \
	}
	B3R_FLAG("draw_shapes", drawShapes)
	B3R_FLAG("draw_joints", drawJoints)
	B3R_FLAG("draw_joint_extras", drawJointExtras)
	B3R_FLAG("draw_bounds", drawBounds)
	B3R_FLAG("draw_mass", drawMass)
	B3R_FLAG("draw_sleep", drawSleep)
	B3R_FLAG("draw_body_names", drawBodyNames)
	B3R_FLAG("draw_contacts", drawContacts)
	B3R_FLAG("draw_anchor_a", drawAnchorA)
	B3R_FLAG("draw_graph_colors", drawGraphColors)
	B3R_FLAG("draw_contact_features", drawContactFeatures)
	B3R_FLAG("draw_contact_normals", drawContactNormals)
	B3R_FLAG("draw_contact_forces", drawContactForces)
	B3R_FLAG("draw_islands", drawIslands)
#undef B3R_FLAG
}

} // namespace

// ---------------------------------------------------------------------------
// Lifecycle

Box3DReplayPlayer::~Box3DReplayPlayer() {
	close();
}

bool Box3DReplayPlayer::open(const PackedByteArray &p_data, int p_worker_count) {
	close();
	if (p_data.is_empty()) {
		return false;
	}
	player = b3CreatePlayer(p_data.ptr(), (int)p_data.size(), p_worker_count < 1 ? 1 : p_worker_count);
	return player != nullptr;
}

void Box3DReplayPlayer::close() {
	if (player != nullptr) {
		b3DestroyPlayer(player);
		player = nullptr;
	}
	debug_shape_tracking = false;
	_clear_debug_shapes();
}

bool Box3DReplayPlayer::is_open() const {
	return player != nullptr;
}

Ref<Box3DReplayPlayer> Box3DReplayPlayer::create(const PackedByteArray &p_data, int p_worker_count) {
	Ref<Box3DReplayPlayer> r;
	r.instantiate();
	if (!r->open(p_data, p_worker_count)) {
		return Ref<Box3DReplayPlayer>();
	}
	return r;
}

Ref<Box3DReplayPlayer> Box3DReplayPlayer::create_from_file(const String &p_path, int p_worker_count) {
	PackedByteArray data = load_recording(p_path);
	if (data.is_empty()) {
		return Ref<Box3DReplayPlayer>();
	}
	return create(data, p_worker_count);
}

// ---------------------------------------------------------------------------
// Playback

bool Box3DReplayPlayer::step_frame() {
	return player != nullptr && b3RecPlayer_StepFrame(player);
}

void Box3DReplayPlayer::sub_step_frame() {
	if (player != nullptr) {
		b3RecPlayer_SubStepFrame(player);
	}
}

void Box3DReplayPlayer::restart() {
	if (player != nullptr) {
		b3RecPlayer_Restart(player);
	}
}

void Box3DReplayPlayer::seek_frame(int p_frame) {
	if (player != nullptr) {
		b3RecPlayer_SeekFrame(player, p_frame < 0 ? 0 : p_frame);
	}
}

int Box3DReplayPlayer::get_frame() const {
	return player != nullptr ? b3RecPlayer_GetFrame(player) : 0;
}

int Box3DReplayPlayer::get_frame_count() const {
	return player != nullptr ? b3RecPlayer_GetFrameCount(player) : 0;
}

bool Box3DReplayPlayer::is_at_end() const {
	return player == nullptr || b3RecPlayer_IsAtEnd(player);
}

bool Box3DReplayPlayer::is_at_pre_step() const {
	return player != nullptr && b3RecPlayer_IsAtPreStep(player);
}

bool Box3DReplayPlayer::has_diverged() const {
	return player != nullptr && b3RecPlayer_HasDiverged(player);
}

int Box3DReplayPlayer::get_diverge_frame() const {
	return player != nullptr ? b3RecPlayer_GetDivergeFrame(player) : -1;
}

Dictionary Box3DReplayPlayer::get_info() const {
	Dictionary d;
	if (player == nullptr) {
		return d;
	}
	b3RecPlayerInfo info = b3RecPlayer_GetInfo(player);
	d["frame_count"] = info.frameCount;
	d["worker_count"] = info.workerCount;
	d["time_step"] = info.timeStep;
	d["sub_step_count"] = info.subStepCount;
	d["length_scale"] = info.lengthScale;
	d["bounds"] = aabb_to_gd(info.bounds);
	return d;
}

int64_t Box3DReplayPlayer::get_world_id() const {
	if (player == nullptr) {
		return 0;
	}
	return (int64_t)b3StoreWorldId(b3RecPlayer_GetWorldId(player));
}

bool Box3DReplayPlayer::is_world_valid() const {
	return player != nullptr && b3World_IsValid(b3RecPlayer_GetWorldId(player));
}

void Box3DReplayPlayer::set_worker_count(int p_count) {
	if (player != nullptr) {
		b3RecPlayer_SetWorkerCount(player, p_count);
	}
}

// ---------------------------------------------------------------------------
// Keyframes

void Box3DReplayPlayer::set_keyframe_policy(int64_t p_budget_bytes, int p_min_interval_frames) {
	if (player != nullptr) {
		b3RecPlayer_SetKeyframePolicy(player, p_budget_bytes > 0 ? (size_t)p_budget_bytes : 0, p_min_interval_frames);
	}
}

int64_t Box3DReplayPlayer::get_keyframe_budget() const {
	return player != nullptr ? (int64_t)b3RecPlayer_GetKeyframeBudget(player) : 0;
}

int Box3DReplayPlayer::get_keyframe_min_interval() const {
	return player != nullptr ? b3RecPlayer_GetKeyframeMinInterval(player) : 0;
}

int Box3DReplayPlayer::get_keyframe_interval() const {
	return player != nullptr ? b3RecPlayer_GetKeyframeInterval(player) : 0;
}

int64_t Box3DReplayPlayer::get_keyframe_bytes() const {
	return player != nullptr ? (int64_t)b3RecPlayer_GetKeyframeBytes(player) : 0;
}

// ---------------------------------------------------------------------------
// Bodies

b3BodyId Box3DReplayPlayer::_body(int p_index) const {
	if (player == nullptr || p_index < 0 || p_index >= b3RecPlayer_GetBodyCount(player)) {
		return b3_nullBodyId;
	}
	b3BodyId id = b3RecPlayer_GetBodyId(player, p_index);
	if (B3_IS_NULL(id) || !b3Body_IsValid(id)) {
		return b3_nullBodyId;
	}
	return id;
}

int Box3DReplayPlayer::get_body_count() const {
	return player != nullptr ? b3RecPlayer_GetBodyCount(player) : 0;
}

int64_t Box3DReplayPlayer::get_body_id(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? 0 : (int64_t)b3StoreBodyId(id);
}

bool Box3DReplayPlayer::is_body_valid(int p_index) const {
	return B3_IS_NON_NULL(_body(p_index));
}

Transform3D Box3DReplayPlayer::get_body_transform(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? Transform3D() : wt_to_gd(b3Body_GetTransform(id));
}

Vector3 Box3DReplayPlayer::get_body_position(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? Vector3() : to_gd_pos(b3Body_GetPosition(id));
}

Quaternion Box3DReplayPlayer::get_body_rotation(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? Quaternion() : to_gd(b3Body_GetRotation(id));
}

Vector3 Box3DReplayPlayer::get_body_linear_velocity(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? Vector3() : to_gd(b3Body_GetLinearVelocity(id));
}

Vector3 Box3DReplayPlayer::get_body_angular_velocity(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? Vector3() : to_gd(b3Body_GetAngularVelocity(id));
}

int Box3DReplayPlayer::get_body_type(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? -1 : (int)b3Body_GetType(id);
}

bool Box3DReplayPlayer::is_body_awake(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NON_NULL(id) && b3Body_IsAwake(id);
}

String Box3DReplayPlayer::get_body_name(int p_index) const {
	b3BodyId id = _body(p_index);
	return B3_IS_NULL(id) ? String() : cstr(b3Body_GetName(id));
}

Array Box3DReplayPlayer::get_body_transforms() const {
	Array out;
	if (player == nullptr) {
		return out;
	}
	int count = b3RecPlayer_GetBodyCount(player);
	out.resize(count);
	for (int i = 0; i < count; ++i) {
		b3BodyId id = b3RecPlayer_GetBodyId(player, i);
		if (B3_IS_NON_NULL(id) && b3Body_IsValid(id)) {
			out[i] = wt_to_gd(b3Body_GetTransform(id));
		} // else stays null: hole left by a destroyed body
	}
	return out;
}

// ---------------------------------------------------------------------------
// Frame queries

int Box3DReplayPlayer::get_frame_query_count() const {
	return player != nullptr ? b3RecPlayer_GetFrameQueryCount(player) : 0;
}

Dictionary Box3DReplayPlayer::get_frame_query(int p_index) const {
	Dictionary d;
	if (player == nullptr || p_index < 0 || p_index >= b3RecPlayer_GetFrameQueryCount(player)) {
		return d;
	}
	b3RecQueryInfo q = b3RecPlayer_GetFrameQuery(player, p_index);
	d["type"] = (int)q.type;
	d["category_bits"] = (int64_t)q.filter.categoryBits;
	d["mask_bits"] = (int64_t)q.filter.maskBits;
	d["filter_id"] = (int64_t)q.filter.id;
	d["filter_name"] = cstr(q.filter.name);
	d["aabb"] = aabb_to_gd(q.aabb);
	d["origin"] = to_gd_pos(q.origin);
	d["translation"] = to_gd(q.translation);
	d["hit_count"] = q.hitCount;
	d["key"] = (int64_t)q.key;
	d["id"] = (int64_t)q.id;
	d["name"] = cstr(q.name);
	return d;
}

Dictionary Box3DReplayPlayer::get_frame_query_hit(int p_query_index, int p_hit_index) const {
	Dictionary d;
	if (player == nullptr || p_query_index < 0 || p_query_index >= b3RecPlayer_GetFrameQueryCount(player) || p_hit_index < 0) {
		return d;
	}
	if (p_hit_index >= b3RecPlayer_GetFrameQuery(player, p_query_index).hitCount) {
		return d;
	}
	b3RecQueryHit h = b3RecPlayer_GetFrameQueryHit(player, p_query_index, p_hit_index);
	d["shape_id"] = (int64_t)b3StoreShapeId(h.shape);
	d["point"] = to_gd_pos(h.point);
	d["normal"] = to_gd(h.normal);
	d["fraction"] = h.fraction;
	return d;
}

Array Box3DReplayPlayer::get_frame_queries() const {
	Array out;
	int n = get_frame_query_count();
	for (int i = 0; i < n; ++i) {
		Dictionary q = get_frame_query(i);
		Array hits;
		int hc = q.get("hit_count", 0);
		for (int j = 0; j < hc; ++j) {
			hits.push_back(get_frame_query_hit(i, j));
		}
		q["hits"] = hits;
		out.push_back(q);
	}
	return out;
}

Dictionary Box3DReplayPlayer::draw_frame_queries(int p_query_index, int p_selected_index) {
	DrawCollector c;
	if (player == nullptr) {
		return c.to_dict();
	}
	c.handles = &debug_handles;
	b3DebugDraw draw = b3DefaultDebugDraw();
	c.install(draw);
	b3RecPlayer_DrawFrameQueries(player, &draw, p_query_index, p_selected_index);
	return c.to_dict();
}

Dictionary Box3DReplayPlayer::draw_world(const Dictionary &p_options, int64_t p_mask_bits) {
	DrawCollector c;
	if (player == nullptr) {
		return c.to_dict();
	}
	b3WorldId world_id = b3RecPlayer_GetWorldId(player);
	if (!b3World_IsValid(world_id)) {
		return c.to_dict();
	}
	c.handles = &debug_handles;
	b3DebugDraw draw = b3DefaultDebugDraw();
	draw.drawShapes = true;
	apply_draw_options(draw, p_options);
	c.install(draw);
	b3World_Draw(world_id, &draw, (uint64_t)p_mask_bits);
	return c.to_dict();
}

// ---------------------------------------------------------------------------
// Debug-shape callbacks

void *Box3DReplayPlayer::_create_debug_shape(const b3DebugShape *p_shape, void *p_context) {
	Box3DReplayPlayer *self = static_cast<Box3DReplayPlayer *>(p_context);
	if (self == nullptr || p_shape == nullptr) {
		return nullptr;
	}
	uint64_t key = b3StoreShapeId(p_shape->shapeId);

	// A world rebuilt without destroy callbacks can leave a stale entry for a
	// recycled shape id; replace it.
	auto old = self->debug_shapes.find(key);
	if (old != self->debug_shapes.end()) {
		self->debug_handles.erase(old->second.handle);
		self->debug_shapes.erase(old);
	}

	DebugShapeRecord rec;
	rec.handle = self->next_debug_handle++;
	if (self->next_debug_handle == 0) {
		self->next_debug_handle = 1; // handle 0 would read as "no user shape"
	}
	rec.shape_key = key;
	rec.type = (int)p_shape->type;
	if (p_shape->type == b3_sphereShape && p_shape->sphere != nullptr) {
		rec.center1 = p_shape->sphere->center;
		rec.center2 = p_shape->sphere->center;
		rec.radius = p_shape->sphere->radius;
	} else if (p_shape->type == b3_capsuleShape && p_shape->capsule != nullptr) {
		rec.center1 = p_shape->capsule->center1;
		rec.center2 = p_shape->capsule->center2;
		rec.radius = p_shape->capsule->radius;
	}
	self->debug_shapes[key] = rec;
	self->debug_handles[rec.handle] = key;
	return reinterpret_cast<void *>(rec.handle);
}

void Box3DReplayPlayer::_destroy_debug_shape(void *p_user_shape, void *p_context) {
	Box3DReplayPlayer *self = static_cast<Box3DReplayPlayer *>(p_context);
	if (self == nullptr) {
		return;
	}
	auto it = self->debug_handles.find(reinterpret_cast<uintptr_t>(p_user_shape));
	if (it == self->debug_handles.end()) {
		return;
	}
	auto rec = self->debug_shapes.find(it->second);
	if (rec != self->debug_shapes.end() && rec->second.handle == it->first) {
		self->debug_shapes.erase(rec);
	}
	self->debug_handles.erase(it);
}

void Box3DReplayPlayer::_clear_debug_shapes() {
	debug_shapes.clear();
	debug_handles.clear();
}

void Box3DReplayPlayer::set_debug_shape_tracking(bool p_enabled) {
	if (player == nullptr) {
		return;
	}
	debug_shape_tracking = p_enabled;
	// The player rebuilds its world (rewinding to frame 0) and recreates every
	// shape through the new callbacks, so start from an empty registry.
	_clear_debug_shapes();
	if (p_enabled) {
		b3RecPlayer_SetDebugShapeCallbacks(player, &_create_debug_shape, &_destroy_debug_shape, this);
	} else {
		b3RecPlayer_SetDebugShapeCallbacks(player, nullptr, nullptr, nullptr);
	}
}

bool Box3DReplayPlayer::is_debug_shape_tracking() const {
	return debug_shape_tracking;
}

Array Box3DReplayPlayer::get_debug_shapes() const {
	Array out;
	for (const auto &kv : debug_shapes) {
		const DebugShapeRecord &r = kv.second;
		b3ShapeId sid = b3LoadShapeId(r.shape_key);
		if (!b3Shape_IsValid(sid)) {
			continue; // stale entry left by an internal world rebuild
		}
		Dictionary d;
		d["shape_id"] = (int64_t)r.shape_key;
		d["type"] = r.type;
		d["body_id"] = (int64_t)b3StoreBodyId(b3Shape_GetBody(sid));
		if (r.type == b3_sphereShape) {
			d["center"] = to_gd(r.center1);
			d["radius"] = r.radius;
		} else if (r.type == b3_capsuleShape) {
			d["center1"] = to_gd(r.center1);
			d["center2"] = to_gd(r.center2);
			d["radius"] = r.radius;
		}
		out.push_back(d);
	}
	return out;
}

// ---------------------------------------------------------------------------
// Recording files

bool Box3DReplayPlayer::save_recording(const PackedByteArray &p_data, const String &p_path) {
	// A recording file is the raw byte buffer (exactly what b3SaveRecordingToFile
	// writes), so FileAccess handles res:// and user:// paths directly.
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::WRITE);
	if (f.is_null()) {
		return false;
	}
	bool ok = f->store_buffer(p_data);
	f->close();
	return ok;
}

PackedByteArray Box3DReplayPlayer::load_recording(const String &p_path) {
	if (!FileAccess::file_exists(p_path)) {
		return PackedByteArray();
	}
	return FileAccess::get_file_as_bytes(p_path);
}

PackedByteArray Box3DReplayPlayer::load_recording_from_file(const String &p_path) {
	// Native loader: validates size against the recording header.
	PackedByteArray out;
	String global = ProjectSettings::get_singleton()->globalize_path(p_path);
	CharString utf8 = global.utf8();
	b3Recording *rec = b3LoadRecordingFromFile(utf8.get_data());
	if (rec == nullptr) {
		return out;
	}
	int size = b3Recording_GetSize(rec);
	const uint8_t *data = b3Recording_GetData(rec);
	if (size > 0 && data != nullptr) {
		out.resize(size);
		memcpy(out.ptrw(), data, (size_t)size);
	}
	b3DestroyRecording(rec);
	return out;
}

// ---------------------------------------------------------------------------

void Box3DReplayPlayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "data", "worker_count"), &Box3DReplayPlayer::open, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("close"), &Box3DReplayPlayer::close);
	ClassDB::bind_method(D_METHOD("is_open"), &Box3DReplayPlayer::is_open);
	ClassDB::bind_static_method("Box3DReplayPlayer", D_METHOD("create", "data", "worker_count"), &Box3DReplayPlayer::create, DEFVAL(1));
	ClassDB::bind_static_method("Box3DReplayPlayer", D_METHOD("create_from_file", "path", "worker_count"), &Box3DReplayPlayer::create_from_file, DEFVAL(1));

	ClassDB::bind_method(D_METHOD("step_frame"), &Box3DReplayPlayer::step_frame);
	ClassDB::bind_method(D_METHOD("sub_step_frame"), &Box3DReplayPlayer::sub_step_frame);
	ClassDB::bind_method(D_METHOD("restart"), &Box3DReplayPlayer::restart);
	ClassDB::bind_method(D_METHOD("seek_frame", "frame"), &Box3DReplayPlayer::seek_frame);
	ClassDB::bind_method(D_METHOD("get_frame"), &Box3DReplayPlayer::get_frame);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &Box3DReplayPlayer::get_frame_count);
	ClassDB::bind_method(D_METHOD("is_at_end"), &Box3DReplayPlayer::is_at_end);
	ClassDB::bind_method(D_METHOD("is_at_pre_step"), &Box3DReplayPlayer::is_at_pre_step);
	ClassDB::bind_method(D_METHOD("has_diverged"), &Box3DReplayPlayer::has_diverged);
	ClassDB::bind_method(D_METHOD("get_diverge_frame"), &Box3DReplayPlayer::get_diverge_frame);
	ClassDB::bind_method(D_METHOD("get_info"), &Box3DReplayPlayer::get_info);
	ClassDB::bind_method(D_METHOD("get_world_id"), &Box3DReplayPlayer::get_world_id);
	ClassDB::bind_method(D_METHOD("is_world_valid"), &Box3DReplayPlayer::is_world_valid);
	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &Box3DReplayPlayer::set_worker_count);

	ClassDB::bind_method(D_METHOD("set_keyframe_policy", "budget_bytes", "min_interval_frames"), &Box3DReplayPlayer::set_keyframe_policy);
	ClassDB::bind_method(D_METHOD("get_keyframe_budget"), &Box3DReplayPlayer::get_keyframe_budget);
	ClassDB::bind_method(D_METHOD("get_keyframe_min_interval"), &Box3DReplayPlayer::get_keyframe_min_interval);
	ClassDB::bind_method(D_METHOD("get_keyframe_interval"), &Box3DReplayPlayer::get_keyframe_interval);
	ClassDB::bind_method(D_METHOD("get_keyframe_bytes"), &Box3DReplayPlayer::get_keyframe_bytes);

	ClassDB::bind_method(D_METHOD("get_body_count"), &Box3DReplayPlayer::get_body_count);
	ClassDB::bind_method(D_METHOD("get_body_id", "index"), &Box3DReplayPlayer::get_body_id);
	ClassDB::bind_method(D_METHOD("is_body_valid", "index"), &Box3DReplayPlayer::is_body_valid);
	ClassDB::bind_method(D_METHOD("get_body_transform", "index"), &Box3DReplayPlayer::get_body_transform);
	ClassDB::bind_method(D_METHOD("get_body_position", "index"), &Box3DReplayPlayer::get_body_position);
	ClassDB::bind_method(D_METHOD("get_body_rotation", "index"), &Box3DReplayPlayer::get_body_rotation);
	ClassDB::bind_method(D_METHOD("get_body_linear_velocity", "index"), &Box3DReplayPlayer::get_body_linear_velocity);
	ClassDB::bind_method(D_METHOD("get_body_angular_velocity", "index"), &Box3DReplayPlayer::get_body_angular_velocity);
	ClassDB::bind_method(D_METHOD("get_body_type", "index"), &Box3DReplayPlayer::get_body_type);
	ClassDB::bind_method(D_METHOD("is_body_awake", "index"), &Box3DReplayPlayer::is_body_awake);
	ClassDB::bind_method(D_METHOD("get_body_name", "index"), &Box3DReplayPlayer::get_body_name);
	ClassDB::bind_method(D_METHOD("get_body_transforms"), &Box3DReplayPlayer::get_body_transforms);

	ClassDB::bind_method(D_METHOD("get_frame_query_count"), &Box3DReplayPlayer::get_frame_query_count);
	ClassDB::bind_method(D_METHOD("get_frame_query", "index"), &Box3DReplayPlayer::get_frame_query);
	ClassDB::bind_method(D_METHOD("get_frame_query_hit", "query_index", "hit_index"), &Box3DReplayPlayer::get_frame_query_hit);
	ClassDB::bind_method(D_METHOD("get_frame_queries"), &Box3DReplayPlayer::get_frame_queries);
	ClassDB::bind_method(D_METHOD("draw_frame_queries", "query_index", "selected_index"), &Box3DReplayPlayer::draw_frame_queries, DEFVAL(-1), DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("draw_world", "options", "mask_bits"), &Box3DReplayPlayer::draw_world, DEFVAL(Dictionary()), DEFVAL(-1));

	ClassDB::bind_method(D_METHOD("set_debug_shape_tracking", "enabled"), &Box3DReplayPlayer::set_debug_shape_tracking);
	ClassDB::bind_method(D_METHOD("is_debug_shape_tracking"), &Box3DReplayPlayer::is_debug_shape_tracking);
	ClassDB::bind_method(D_METHOD("get_debug_shapes"), &Box3DReplayPlayer::get_debug_shapes);

	ClassDB::bind_static_method("Box3DReplayPlayer", D_METHOD("save_recording", "data", "path"), &Box3DReplayPlayer::save_recording);
	ClassDB::bind_static_method("Box3DReplayPlayer", D_METHOD("load_recording", "path"), &Box3DReplayPlayer::load_recording);
	ClassDB::bind_static_method("Box3DReplayPlayer", D_METHOD("load_recording_from_file", "path"), &Box3DReplayPlayer::load_recording_from_file);

	BIND_ENUM_CONSTANT(QUERY_OVERLAP_AABB);
	BIND_ENUM_CONSTANT(QUERY_OVERLAP_SHAPE);
	BIND_ENUM_CONSTANT(QUERY_CAST_RAY);
	BIND_ENUM_CONSTANT(QUERY_CAST_SHAPE);
	BIND_ENUM_CONSTANT(QUERY_CAST_RAY_CLOSEST);
	BIND_ENUM_CONSTANT(QUERY_CAST_MOVER);
	BIND_ENUM_CONSTANT(QUERY_COLLIDE_MOVER);
}
