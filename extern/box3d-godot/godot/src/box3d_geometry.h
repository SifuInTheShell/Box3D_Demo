// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// --- Extended core access III: standalone geometry ---
//
// Box3DGeometry exposes the world-independent part of the Box3D C API
// (collision.h, base.h, constants.h and the non-inline math_functions.h
// helpers) as static methods: Box3DGeometry.ray_cast(...), etc.
// Box3DDynamicTree wraps b3DynamicTree as a RefCounted object, because a tree
// owns state across calls.
//
// All transforms are rigid: any scale/shear in a Transform3D is ignored (only
// origin + rotation are used). Non-uniform scale is expressed explicitly where
// Box3D supports it (mesh "scale", box "scale", clone_and_transform_hull).
//
// Shape Dictionary formats (the "type" key selects the kind):
//   {type:"sphere", center:Vector3 = ZERO, radius:float}
//   {type:"capsule", center1:Vector3, center2:Vector3, radius:float}
//   {type:"box", half_extents:Vector3, transform:Transform3D = IDENTITY,
//        scale:Vector3 (optional post scale, may be negative)}           -> hull
//   {type:"hull", points:PackedVector3Array, max_vertex_count:int = 128}  -> hull
//        (every hull dictionary returned by this class has this form, plus
//         read-only extra data, so it can be passed straight back in)
//   {type:"cylinder", height, radius, y_offset = 0, sides = 16}           -> hull
//   {type:"cone", height, radius1, radius2, slices = 16}                  -> hull
//   {type:"rock", radius} / {type:"complex_hull", radius}                 -> hull
//   {type:"mesh", vertices:PackedVector3Array, indices:PackedInt32Array
//        (3 per triangle), material_indices:PackedByteArray (optional, 1 per
//        triangle), scale:Vector3 = ONE, weld_vertices = false,
//        weld_tolerance = 0, use_median_split = false, identify_edges = true,
//        clockwise = false}
//   {type:"heightfield", heights:PackedFloat32Array (count_x * count_z,
//        row-major along x), count_x:int, count_z:int, scale:Vector3 = ONE,
//        material_indices:PackedByteArray (optional, (count_x-1)*(count_z-1),
//        255 = hole), global_min_height / global_max_height (optional, default
//        min/max of heights), clockwise = false}
//   {type:"compound", bytes:PackedByteArray}   (baked, from create_compound)
//   {type:"compound", children:Array}          (baked on the fly; each child is
//        a sphere/capsule/hull-kind/mesh dictionary with optional
//        transform:Transform3D, material:Dictionary, and for meshes
//        materials:Array[Dictionary])
//   {type:"triangle", v1:Vector3, v2:Vector3, v3:Vector3}   (collide/proxy only)
//   {type:"proxy", points:PackedVector3Array, radius:float = 0} (GJK point cloud)
// Proxies (overlap / shape casts / distance / TOI) accept sphere, capsule, any
// hull kind, triangle and proxy dictionaries.
//
// Material Dictionary: {friction, restitution, rolling_resistance,
//   tangent_velocity:Vector3, user_material_id:int, custom_color:int}
// Sweep Dictionary: {local_center:Vector3, c1:Vector3, c2:Vector3,
//   q1:Quaternion, q2:Quaternion}
// Collision plane Dictionary: {plane:Plane, push_limit:float = INF,
//   push:float = 0, clip_velocity:bool = true}
//
// Unbound on purpose: b3SetAllocator (would route every engine allocation,
// including worker-thread ones, through a script VM), b3SetAssertFcn /
// b3InternalAssert (called from arbitrary engine threads mid-failure; the
// engine state is not safe to touch from script). b3SetLogFcn is exposed as a
// mode switch (set_log_mode) that routes to Godot's print/push_warning from a
// static C function rather than to a Callable.

#pragma once

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <box3d/box3d.h>
#include <box3d/collision.h>
#include <box3d/constants.h>

namespace godot {

class Box3DGeometry : public Object {
	GDCLASS(Box3DGeometry, Object)

protected:
	static void _bind_methods();

public:
	enum LogMode {
		LOG_STDOUT = 0, // Box3D default: printf("Box3D: ...")
		LOG_GODOT_WARNING = 1, // push_warning
		LOG_GODOT_PRINT = 2, // print
		LOG_SILENT = 3,
	};

	// --- base.h ---
	static Dictionary get_version();
	static bool is_double_precision();
	static int get_max_manifold_points();
	static bool is_avx2_available();
	static int64_t get_byte_count();
	static int64_t get_ticks();
	static float get_milliseconds(int64_t p_ticks);
	static Dictionary get_milliseconds_and_reset(int64_t p_ticks);
	static void yield_cpu();
	static void sleep(int p_milliseconds);
	static int64_t hash(const PackedByteArray &p_data, int64_t p_seed);
	static void set_log_mode(int p_mode);
	static int get_log_mode();

	// --- constants.h ---
	static void set_length_units_per_meter(float p_units);
	static float get_length_units_per_meter();
	static Dictionary get_constants();
	// b3DefaultFilter: { category_bits, mask_bits, group_index }.
	static Dictionary get_default_filter();
	// b3GetGraphColor: debug colour of a constraint-graph colour slot.
	static Color get_graph_color(int p_index);

	// --- math_functions.h ---
	static Dictionary compute_cos_sin(float p_radians);
	static Quaternion make_quat_from_matrix(const Basis &p_matrix);
	static Quaternion compute_quat_between_unit_vectors(const Vector3 &p_v1, const Vector3 &p_v2);
	static Basis steiner(float p_mass, const Vector3 &p_origin);
	static Vector3 point_to_segment_distance(const Vector3 &p_a, const Vector3 &p_b, const Vector3 &p_q);
	static Dictionary line_distance(const Vector3 &p_p1, const Vector3 &p_d1, const Vector3 &p_p2, const Vector3 &p_d2);
	static Dictionary segment_distance(const Vector3 &p_p1, const Vector3 &p_q1, const Vector3 &p_p2, const Vector3 &p_q2);
	static bool is_valid_float(float p_value);
	static bool is_valid_vec3(const Vector3 &p_value);
	static bool is_valid_quat(const Quaternion &p_value);
	static bool is_valid_transform(const Vector3 &p_origin, const Quaternion &p_rotation);
	static bool is_valid_matrix3(const Basis &p_value);
	static bool is_valid_aabb(const AABB &p_value);
	static bool is_bounded_aabb(const AABB &p_value);
	static bool is_sane_aabb(const AABB &p_value);
	static bool is_valid_plane(const Plane &p_value);
	static bool is_valid_position(const Vector3 &p_value);
	static bool is_valid_world_transform(const Vector3 &p_origin, const Quaternion &p_rotation);

	// --- hulls ---
	static Dictionary create_hull(const PackedVector3Array &p_points, int p_max_vertex_count);
	static Dictionary create_cylinder(float p_height, float p_radius, float p_y_offset, int p_sides);
	static Dictionary create_cone(float p_height, float p_radius1, float p_radius2, int p_slices);
	static Dictionary create_rock(float p_radius);
	static Dictionary create_complex_hull(float p_radius);
	static Dictionary clone_hull(const Dictionary &p_shape);
	static Dictionary clone_and_transform_hull(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_scale);
	static Dictionary make_cube_hull(float p_half_width);
	static Dictionary make_box_hull(const Vector3 &p_half_extents);
	static Dictionary make_offset_box_hull(const Vector3 &p_half_extents, const Vector3 &p_offset);
	static Dictionary make_transformed_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform);
	static Dictionary make_scaled_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform, const Vector3 &p_post_scale);
	static Dictionary scale_box(const Vector3 &p_half_extents, const Transform3D &p_transform, const Vector3 &p_post_scale, float p_min_half_width);
	static Dictionary get_hull_data(const Dictionary &p_shape);

	// --- meshes ---
	static Dictionary create_mesh(const Dictionary &p_def);
	static Dictionary create_grid_mesh(int p_x_count, int p_z_count, float p_cell_width, int p_material_count, bool p_identify_edges);
	static Dictionary create_wave_mesh(int p_x_count, int p_z_count, float p_cell_width, float p_amplitude, float p_row_frequency, float p_column_frequency);
	static Dictionary create_torus_mesh(int p_radial_resolution, int p_tubular_resolution, float p_radius, float p_thickness);
	static Dictionary create_box_mesh(const Vector3 &p_center, const Vector3 &p_extent, bool p_identify_edges);
	static Dictionary create_hollow_box_mesh(const Vector3 &p_center, const Vector3 &p_extent);
	static Dictionary create_platform_mesh(const Vector3 &p_center, float p_height, float p_top_width, float p_bottom_width);
	static Dictionary get_mesh_data(const Dictionary &p_shape);
	static int get_mesh_bvh_height(const Dictionary &p_shape);
	static Array query_mesh(const Dictionary &p_shape, const AABB &p_bounds);

	// --- height fields ---
	static Dictionary create_height_field(const Dictionary &p_def);
	static Dictionary create_grid_height_field(int p_row_count, int p_column_count, const Vector3 &p_scale, bool p_make_holes);
	static Dictionary create_wave_height_field(int p_row_count, int p_column_count, const Vector3 &p_scale, float p_row_frequency, float p_column_frequency, bool p_make_holes);
	static Dictionary get_height_field_data(const Dictionary &p_shape);
	static bool dump_height_data(const Dictionary &p_def, const String &p_path);
	static Dictionary load_height_field(const String &p_path);
	static Array query_height_field(const Dictionary &p_shape, const AABB &p_bounds);

	// --- compounds ---
	static Dictionary create_compound(const Dictionary &p_def);
	static bool validate_compound(const PackedByteArray &p_bytes);
	static Dictionary get_compound_info(const Dictionary &p_shape);
	static Dictionary get_compound_child(const Dictionary &p_shape, int p_child_index);
	static PackedInt32Array query_compound(const Dictionary &p_shape, const AABB &p_bounds);

	// --- mass / bounds ---
	static Dictionary compute_mass(const Dictionary &p_shape, float p_density);
	static AABB compute_aabb(const Dictionary &p_shape, const Transform3D &p_transform);

	// --- queries ---
	static bool is_valid_ray(const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction);
	static bool overlap(const Dictionary &p_shape, const Transform3D &p_shape_transform, const Dictionary &p_proxy, const Transform3D &p_proxy_transform);
	static Dictionary ray_cast(const Dictionary &p_shape, const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, const Transform3D &p_shape_transform);
	static Dictionary ray_cast_hollow_sphere(const Dictionary &p_shape, const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, const Transform3D &p_shape_transform);
	static Dictionary shape_cast(const Dictionary &p_shape, const Dictionary &p_proxy, const Vector3 &p_translation, float p_max_fraction, bool p_can_encroach, const Transform3D &p_shape_transform, const Transform3D &p_proxy_transform);
	static Dictionary shape_distance(const Dictionary &p_proxy_a, const Transform3D &p_transform_a, const Dictionary &p_proxy_b, const Transform3D &p_transform_b, bool p_use_radii, const Dictionary &p_cache, int p_simplex_capacity);
	static Dictionary shape_cast_pair(const Dictionary &p_proxy_a, const Transform3D &p_transform_a, const Dictionary &p_proxy_b, const Transform3D &p_transform_b, const Vector3 &p_translation_b, float p_max_fraction, bool p_can_encroach);
	static Transform3D get_sweep_transform(const Dictionary &p_sweep, float p_time);
	static Dictionary time_of_impact(const Dictionary &p_proxy_a, const Dictionary &p_sweep_a, const Dictionary &p_proxy_b, const Dictionary &p_sweep_b, float p_max_fraction);

	// --- manifolds ---
	static Dictionary collide(const Dictionary &p_shape_a, const Dictionary &p_shape_b, const Transform3D &p_transform_b_to_a, int p_capacity, const Dictionary &p_cache, bool p_enable_speculative, bool p_handle_ghosts);
	static Array hull_2d(const PackedVector2Array &p_points, const PackedFloat32Array &p_separations, int p_flags);
	static Array simplify_hull_2d(const PackedVector2Array &p_points, const PackedFloat32Array &p_separations, int p_target);

	// --- character planes ---
	static Dictionary solve_planes(const Vector3 &p_target_delta, const Array &p_planes);
	static Vector3 clip_vector(const Vector3 &p_vector, const Array &p_planes);
};

// Wraps b3DynamicTree: a standalone AABB tree for user spatial data.
// Callables passed to queries are invoked synchronously on the calling thread;
// the tree must not be modified from inside them (such calls are rejected).
class Box3DDynamicTree : public RefCounted {
	GDCLASS(Box3DDynamicTree, RefCounted)

private:
	b3DynamicTree tree = {};
	bool valid = false;
	bool in_query = false;

	bool check_proxy(int p_proxy_id) const;
	bool check_mutable() const;

protected:
	static void _bind_methods();

public:
	Box3DDynamicTree();
	~Box3DDynamicTree();

	void reset(int p_proxy_capacity);
	int create_proxy(const AABB &p_aabb, int64_t p_category_bits, int64_t p_user_data);
	void destroy_proxy(int p_proxy_id);
	void move_proxy(int p_proxy_id, const AABB &p_aabb);
	void enlarge_proxy(int p_proxy_id, const AABB &p_aabb);
	void set_category_bits(int p_proxy_id, int64_t p_category_bits);
	int64_t get_category_bits(int p_proxy_id) const;
	int64_t get_user_data(int p_proxy_id) const;
	AABB get_proxy_aabb(int p_proxy_id) const;
	bool is_proxy_valid(int p_proxy_id) const;

	Dictionary query(const AABB &p_aabb, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback);
	Dictionary query_closest(const Vector3 &p_point, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback, float p_min_distance_sqr);
	Dictionary ray_cast(const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback);
	Dictionary box_cast(const AABB &p_box, const Vector3 &p_translation, float p_max_fraction, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback);

	int get_height() const;
	float get_area_ratio() const;
	AABB get_root_bounds() const;
	int get_proxy_count() const;
	int rebuild(bool p_full_build);
	int get_byte_count() const;
	void validate() const;
	void validate_no_moved() const;
	void save(const String &p_path) const;
	bool load(const String &p_path, float p_scale);
};

} // namespace godot

VARIANT_ENUM_CAST(Box3DGeometry::LogMode);
