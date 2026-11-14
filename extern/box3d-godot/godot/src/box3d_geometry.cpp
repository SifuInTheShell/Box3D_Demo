// SPDX-FileCopyrightText: 2026 box3d-godot contributors
// SPDX-License-Identifier: MIT
//
// --- Extended core access III: standalone geometry ---
// See box3d_geometry.h for the Dictionary formats used by this file.

#include "box3d_geometry.h"

#include "box3d_conversions.h"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <atomic>
#include <cfloat>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

using namespace godot;

namespace {

// ---------------------------------------------------------------------------
// Small conversion helpers
// ---------------------------------------------------------------------------

template <typename T>
T dget(const Dictionary &p_dict, const char *p_key, const T &p_default) {
	Variant v = p_dict.get(p_key, Variant());
	if (v.get_type() == Variant::NIL) {
		return p_default;
	}
	T out = v;
	return out;
}

int64_t u64_to_i64(uint64_t p_value) {
	int64_t out;
	memcpy(&out, &p_value, sizeof(out));
	return out;
}

uint64_t i64_to_u64(int64_t p_value) {
	uint64_t out;
	memcpy(&out, &p_value, sizeof(out));
	return out;
}

// Raw: preserves negative sizes (used by the validators).
b3AABB to_b3_aabb_raw(const AABB &p_aabb) {
	b3AABB r;
	r.lowerBound = to_b3(p_aabb.position);
	r.upperBound = to_b3(p_aabb.position + p_aabb.size);
	return r;
}

// Normalized: negative sizes are flipped (used for query inputs).
b3AABB to_b3_aabb(const AABB &p_aabb) {
	return to_b3_aabb_raw(p_aabb.abs());
}

AABB to_gd_aabb(const b3AABB &p_aabb) {
	Vector3 lower = to_gd(p_aabb.lowerBound);
	return AABB(lower, to_gd(p_aabb.upperBound) - lower);
}

Basis to_gd_matrix(const b3Matrix3 &p_m) {
	return Basis(to_gd(p_m.cx), to_gd(p_m.cy), to_gd(p_m.cz));
}

b3Matrix3 to_b3_matrix(const Basis &p_b) {
	b3Matrix3 m;
	m.cx = to_b3(p_b.get_column(0));
	m.cy = to_b3(p_b.get_column(1));
	m.cz = to_b3(p_b.get_column(2));
	return m;
}

Plane to_gd_plane(const b3Plane &p_plane) {
	return Plane(to_gd(p_plane.normal), (real_t)p_plane.offset);
}

b3Plane to_b3_plane(const Plane &p_plane) {
	b3Plane r;
	r.normal = to_b3(p_plane.normal);
	r.offset = (float)p_plane.d;
	return r;
}

b3Transform make_b3_transform(const Vector3 &p_origin, const Quaternion &p_rotation) {
	b3Transform t;
	t.p = to_b3(p_origin);
	t.q = to_b3(p_rotation);
	return t;
}

Dictionary material_to_dict(const b3SurfaceMaterial &p_m) {
	Dictionary d;
	d["friction"] = p_m.friction;
	d["restitution"] = p_m.restitution;
	d["rolling_resistance"] = p_m.rollingResistance;
	d["tangent_velocity"] = to_gd(p_m.tangentVelocity);
	d["user_material_id"] = u64_to_i64(p_m.userMaterialId);
	d["custom_color"] = (int64_t)p_m.customColor;
	return d;
}

b3SurfaceMaterial material_from_variant(const Variant &p_value) {
	b3SurfaceMaterial m = b3DefaultSurfaceMaterial();
	if (p_value.get_type() != Variant::DICTIONARY) {
		return m;
	}
	Dictionary d = p_value;
	m.friction = dget<float>(d, "friction", m.friction);
	m.restitution = dget<float>(d, "restitution", m.restitution);
	m.rollingResistance = dget<float>(d, "rolling_resistance", m.rollingResistance);
	m.tangentVelocity = to_b3(dget<Vector3>(d, "tangent_velocity", to_gd(m.tangentVelocity)));
	m.userMaterialId = i64_to_u64(dget<int64_t>(d, "user_material_id", u64_to_i64(m.userMaterialId)));
	m.customColor = (uint32_t)dget<int64_t>(d, "custom_color", (int64_t)m.customColor);
	return m;
}

Dictionary segment_result_to_dict(const b3SegmentDistanceResult &p_r) {
	Dictionary d;
	d["point1"] = to_gd(p_r.point1);
	d["fraction1"] = p_r.fraction1;
	d["point2"] = to_gd(p_r.point2);
	d["fraction2"] = p_r.fraction2;
	return d;
}

Dictionary mass_to_dict(const b3MassData &p_m) {
	Dictionary d;
	d["mass"] = p_m.mass;
	d["center"] = to_gd(p_m.center);
	d["inertia"] = to_gd_matrix(p_m.inertia);
	return d;
}

// Cast output with point/normal mapped through `p_xf` (shape local -> world).
Dictionary cast_output_to_dict(const b3CastOutput &p_o, const b3Transform &p_xf) {
	Dictionary d;
	d["hit"] = p_o.hit;
	d["point"] = to_gd(b3TransformPoint(p_xf, p_o.point));
	d["normal"] = to_gd(b3RotateVector(p_xf.q, p_o.normal));
	d["fraction"] = p_o.fraction;
	d["iterations"] = p_o.iterations;
	d["triangle_index"] = p_o.triangleIndex;
	d["child_index"] = p_o.childIndex;
	d["material_index"] = p_o.materialIndex;
	return d;
}

Dictionary simplex_cache_to_dict(const b3SimplexCache &p_c) {
	Dictionary d;
	d["metric"] = p_c.metric;
	d["count"] = (int)p_c.count;
	PackedInt32Array a, b;
	for (int i = 0; i < 4; ++i) {
		a.push_back(p_c.indexA[i]);
		b.push_back(p_c.indexB[i]);
	}
	d["index_a"] = a;
	d["index_b"] = b;
	return d;
}

// Reads a simplex cache; indices are checked against the proxy point counts so a
// stale/foreign cache can never index out of bounds (falls back to empty).
b3SimplexCache simplex_cache_from_dict(const Dictionary &p_d, int p_count_a, int p_count_b) {
	b3SimplexCache c = {};
	if (p_d.is_empty()) {
		return c;
	}
	int count = dget<int>(p_d, "count", 0);
	PackedInt32Array a = dget<PackedInt32Array>(p_d, "index_a", PackedInt32Array());
	PackedInt32Array b = dget<PackedInt32Array>(p_d, "index_b", PackedInt32Array());
	if (count < 0 || count > 4 || a.size() < count || b.size() < count) {
		return c;
	}
	for (int i = 0; i < count; ++i) {
		if (a[i] < 0 || a[i] >= p_count_a || b[i] < 0 || b[i] >= p_count_b) {
			return b3SimplexCache{};
		}
		c.indexA[i] = (uint8_t)a[i];
		c.indexB[i] = (uint8_t)b[i];
	}
	c.count = (uint16_t)count;
	c.metric = dget<float>(p_d, "metric", 0.0f);
	return c;
}

Dictionary sat_cache_to_dict(const b3SATCache &p_c) {
	Dictionary d;
	d["separation"] = p_c.separation;
	d["type"] = (int)p_c.type;
	d["index_a"] = (int)p_c.indexA;
	d["index_b"] = (int)p_c.indexB;
	d["hit"] = (int)p_c.hit;
	return d;
}

Dictionary local_manifold_to_dict(const b3LocalManifold &p_m) {
	Dictionary d;
	d["normal"] = to_gd(p_m.normal);
	d["triangle_normal"] = to_gd(p_m.triangleNormal);
	d["point_count"] = p_m.pointCount;
	d["triangle_index"] = p_m.triangleIndex;
	d["feature"] = (int)p_m.feature;
	Array points;
	for (int i = 0; i < p_m.pointCount; ++i) {
		const b3LocalManifoldPoint &mp = p_m.points[i];
		Dictionary p;
		p["point"] = to_gd(mp.point);
		p["separation"] = mp.separation;
		Dictionary pair;
		pair["owner1"] = (int)mp.pair.owner1;
		pair["index1"] = (int)mp.pair.index1;
		pair["owner2"] = (int)mp.pair.owner2;
		pair["index2"] = (int)mp.pair.index2;
		p["feature_pair"] = pair;
		p["triangle_index"] = mp.triangleIndex;
		p["triangle_feature"] = (int)mp.triangleFeature;
		p["mesh_flags"] = (int)mp.meshFlags;
		points.push_back(p);
	}
	d["points"] = points;
	return d;
}

Dictionary manifold_to_dict(const b3Manifold &p_m) {
	Dictionary d;
	d["normal"] = to_gd(p_m.normal);
	d["twist_impulse"] = p_m.twistImpulse;
	d["friction_impulse"] = to_gd(p_m.frictionImpulse);
	d["rolling_impulse"] = to_gd(p_m.rollingImpulse);
	d["point_count"] = p_m.pointCount;
	Array points;
	for (int i = 0; i < p_m.pointCount && i < B3_MAX_MANIFOLD_POINTS; ++i) {
		const b3ManifoldPoint &mp = p_m.points[i];
		Dictionary p;
		p["anchor_a"] = to_gd(mp.anchorA);
		p["anchor_b"] = to_gd(mp.anchorB);
		p["separation"] = mp.separation;
		p["normal_impulse"] = mp.normalImpulse;
		p["total_normal_impulse"] = mp.totalNormalImpulse;
		p["normal_velocity"] = mp.normalVelocity;
		p["base_separation"] = mp.baseSeparation;
		p["feature_id"] = (int64_t)mp.featureId;
		p["triangle_index"] = mp.triangleIndex;
		p["persisted"] = mp.persisted;
		p["triangle_feature"] = (int)mp.triangleFeature;
		p["mesh_flags"] = (int)mp.meshFlags;
		points.push_back(p);
	}
	d["points"] = points;
	return d;
}

b3Sweep sweep_from_dict(const Dictionary &p_d) {
	b3Sweep s;
	s.localCenter = to_b3(dget<Vector3>(p_d, "local_center", Vector3()));
	s.c1 = to_b3(dget<Vector3>(p_d, "c1", Vector3()));
	s.c2 = to_b3(dget<Vector3>(p_d, "c2", Vector3()));
	s.q1 = to_b3(dget<Quaternion>(p_d, "q1", Quaternion()).normalized());
	s.q2 = to_b3(dget<Quaternion>(p_d, "q2", Quaternion()).normalized());
	return s;
}

String globalize(const String &p_path) {
	ProjectSettings *ps = ProjectSettings::get_singleton();
	return ps ? ps->globalize_path(p_path) : p_path;
}

// ---------------------------------------------------------------------------
// Blob -> Dictionary
// ---------------------------------------------------------------------------

Dictionary hull_to_dict(const b3HullData *p_hull) {
	Dictionary d;
	if (p_hull == nullptr) {
		return d;
	}
	const b3Vec3 *points = b3GetHullPoints(p_hull);
	const b3HullHalfEdge *edges = b3GetHullEdges(p_hull);
	const b3HullFace *faces = b3GetHullFaces(p_hull);
	const b3Plane *planes = b3GetHullPlanes(p_hull);
	const b3HullVertex *vertices = b3GetHullVertices(p_hull);
	const float *cosines = b3GetHullEdgeCosines(p_hull);

	PackedVector3Array pts;
	if (points != nullptr) {
		for (int i = 0; i < p_hull->vertexCount; ++i) {
			pts.push_back(to_gd(points[i]));
		}
	}

	PackedInt32Array vertex_edges;
	if (vertices != nullptr) {
		for (int i = 0; i < p_hull->vertexCount; ++i) {
			vertex_edges.push_back(vertices[i].edge);
		}
	}

	PackedInt32Array edge_data;
	if (edges != nullptr) {
		for (int i = 0; i < p_hull->edgeCount; ++i) {
			edge_data.push_back(edges[i].next);
			edge_data.push_back(edges[i].twin);
			edge_data.push_back(edges[i].origin);
			edge_data.push_back(edges[i].face);
		}
	}

	Array face_list;
	Array plane_list;
	for (int i = 0; i < p_hull->faceCount; ++i) {
		PackedInt32Array face;
		if (faces != nullptr && edges != nullptr) {
			int start = faces[i].edge;
			int e = start;
			int guard = 0;
			do {
				if (e < 0 || e >= p_hull->edgeCount) {
					break;
				}
				face.push_back(edges[e].origin);
				e = edges[e].next;
			} while (e != start && ++guard < p_hull->edgeCount);
		}
		face_list.push_back(face);
		if (planes != nullptr) {
			plane_list.push_back(to_gd_plane(planes[i]));
		}
	}

	PackedFloat32Array edge_cosines;
	if (cosines != nullptr) {
		for (int i = 0; i < p_hull->edgeCount / 2; ++i) {
			edge_cosines.push_back(cosines[i]);
		}
	}

	d["type"] = "hull";
	d["points"] = pts;
	d["max_vertex_count"] = MAX(4, p_hull->vertexCount);
	d["faces"] = face_list;
	d["planes"] = plane_list;
	d["edges"] = edge_data;
	d["vertex_edges"] = vertex_edges;
	d["edge_cosines"] = edge_cosines;
	d["vertex_count"] = p_hull->vertexCount;
	d["edge_count"] = p_hull->edgeCount;
	d["face_count"] = p_hull->faceCount;
	d["aabb"] = to_gd_aabb(p_hull->aabb);
	d["surface_area"] = p_hull->surfaceArea;
	d["volume"] = p_hull->volume;
	d["inner_radius"] = p_hull->innerRadius;
	d["center"] = to_gd(p_hull->center);
	d["central_inertia"] = to_gd_matrix(p_hull->centralInertia);
	d["byte_count"] = p_hull->byteCount;
	d["hash"] = u64_to_i64(p_hull->hash);
	return d;
}

Dictionary mesh_to_dict(const b3MeshData *p_mesh, const Vector3 &p_scale) {
	Dictionary d;
	if (p_mesh == nullptr) {
		return d;
	}
	const b3Vec3 *vertices = b3GetMeshVertices(p_mesh);
	const b3MeshTriangle *triangles = b3GetMeshTriangles(p_mesh);
	const uint8_t *materials = b3GetMeshMaterialIndices(p_mesh);
	const uint8_t *flags = b3GetMeshFlags(p_mesh);
	const int8_t *edge_angles = b3GetMeshEdgeAngles(p_mesh);
	const uint8_t *vertex_flags = b3GetMeshVertexFlags(p_mesh);

	PackedVector3Array verts;
	if (vertices != nullptr) {
		verts.resize(p_mesh->vertexCount);
		for (int i = 0; i < p_mesh->vertexCount; ++i) {
			verts.set(i, to_gd(vertices[i]));
		}
	}
	PackedInt32Array indices;
	PackedByteArray material_indices;
	PackedByteArray triangle_flags;
	PackedInt32Array angles;
	if (triangles != nullptr) {
		indices.resize(3 * p_mesh->triangleCount);
		for (int i = 0; i < p_mesh->triangleCount; ++i) {
			indices.set(3 * i + 0, triangles[i].index1);
			indices.set(3 * i + 1, triangles[i].index2);
			indices.set(3 * i + 2, triangles[i].index3);
		}
	}
	if (materials != nullptr) {
		material_indices.resize(p_mesh->triangleCount);
		memcpy(material_indices.ptrw(), materials, (size_t)p_mesh->triangleCount);
	}
	if (flags != nullptr) {
		triangle_flags.resize(p_mesh->triangleCount);
		memcpy(triangle_flags.ptrw(), flags, (size_t)p_mesh->triangleCount);
	}
	if (edge_angles != nullptr) {
		angles.resize(3 * p_mesh->triangleCount);
		for (int i = 0; i < 3 * p_mesh->triangleCount; ++i) {
			angles.set(i, edge_angles[i]);
		}
	}
	PackedByteArray vflags;
	if (vertex_flags != nullptr) {
		vflags.resize(p_mesh->vertexCount);
		memcpy(vflags.ptrw(), vertex_flags, (size_t)p_mesh->vertexCount);
	}

	d["type"] = "mesh";
	d["vertices"] = verts;
	d["indices"] = indices;
	d["material_indices"] = material_indices;
	d["scale"] = p_scale;
	d["identify_edges"] = p_mesh->edgeAngleOffset != 0;
	d["triangle_flags"] = triangle_flags;
	d["edge_angles"] = angles;
	d["vertex_flags"] = vflags;
	d["bounds"] = to_gd_aabb(p_mesh->bounds);
	d["surface_area"] = p_mesh->surfaceArea;
	d["tree_height"] = p_mesh->treeHeight;
	d["degenerate_count"] = p_mesh->degenerateCount;
	d["node_count"] = p_mesh->nodeCount;
	d["vertex_count"] = p_mesh->vertexCount;
	d["triangle_count"] = p_mesh->triangleCount;
	d["material_count"] = p_mesh->materialCount;
	d["byte_count"] = p_mesh->byteCount;
	d["hash"] = u64_to_i64(p_mesh->hash);
	return d;
}

Dictionary height_field_to_dict(const b3HeightFieldData *p_hf) {
	Dictionary d;
	if (p_hf == nullptr) {
		return d;
	}
	int height_count = p_hf->columnCount * p_hf->rowCount;
	int cell_count = (p_hf->columnCount - 1) * (p_hf->rowCount - 1);
	const uint16_t *compressed = b3GetHeightFieldCompressedHeights(p_hf);
	const uint8_t *materials = b3GetHeightFieldMaterialIndices(p_hf);
	const uint8_t *flags = b3GetHeightFieldFlags(p_hf);

	PackedFloat32Array heights;
	PackedInt32Array compressed_heights;
	if (compressed != nullptr && height_count > 0) {
		heights.resize(height_count);
		compressed_heights.resize(height_count);
		for (int i = 0; i < height_count; ++i) {
			heights.set(i, p_hf->minHeight + p_hf->heightScale * compressed[i]);
			compressed_heights.set(i, compressed[i]);
		}
	}
	PackedByteArray material_indices;
	if (materials != nullptr && cell_count > 0) {
		material_indices.resize(cell_count);
		memcpy(material_indices.ptrw(), materials, (size_t)cell_count);
	}
	PackedByteArray triangle_flags;
	if (flags != nullptr && cell_count > 0) {
		triangle_flags.resize(2 * cell_count);
		memcpy(triangle_flags.ptrw(), flags, (size_t)(2 * cell_count));
	}

	d["type"] = "heightfield";
	d["heights"] = heights;
	d["count_x"] = p_hf->columnCount;
	d["count_z"] = p_hf->rowCount;
	d["scale"] = to_gd(p_hf->scale);
	d["material_indices"] = material_indices;
	d["global_min_height"] = p_hf->minHeight;
	d["global_max_height"] = p_hf->maxHeight;
	d["clockwise"] = p_hf->clockwise != 0;
	d["compressed_heights"] = compressed_heights;
	d["height_scale"] = p_hf->heightScale;
	d["triangle_flags"] = triangle_flags;
	d["aabb"] = to_gd_aabb(p_hf->aabb);
	d["byte_count"] = p_hf->byteCount;
	d["hash"] = u64_to_i64(p_hf->hash);
	return d;
}

const char *shape_type_name(b3ShapeType p_type) {
	switch (p_type) {
		case b3_capsuleShape:
			return "capsule";
		case b3_compoundShape:
			return "compound";
		case b3_heightShape:
			return "heightfield";
		case b3_hullShape:
			return "hull";
		case b3_meshShape:
			return "mesh";
		case b3_sphereShape:
			return "sphere";
		default:
			return "unknown";
	}
}

Dictionary compound_to_dict(const b3CompoundData *p_c) {
	Dictionary d;
	if (p_c == nullptr) {
		return d;
	}
	PackedByteArray bytes;
	bytes.resize(p_c->byteCount);
	memcpy(bytes.ptrw(), p_c, (size_t)p_c->byteCount);

	d["type"] = "compound";
	d["bytes"] = bytes;
	d["byte_count"] = p_c->byteCount;
	d["bounds"] = to_gd_aabb(p_c->bounds);
	d["tree_height"] = p_c->treeHeight;
	d["node_count"] = p_c->nodeCount;
	d["material_count"] = p_c->materialCount;
	d["capsule_count"] = p_c->capsuleCount;
	d["hull_count"] = p_c->hullCount;
	d["shared_hull_count"] = p_c->sharedHullCount;
	d["mesh_count"] = p_c->meshCount;
	d["shared_mesh_count"] = p_c->sharedMeshCount;
	d["sphere_count"] = p_c->sphereCount;
	d["child_count"] = p_c->capsuleCount + p_c->hullCount + p_c->meshCount + p_c->sphereCount;

	Array materials;
	const b3SurfaceMaterial *mats = b3GetCompoundMaterials(p_c);
	if (mats != nullptr) {
		for (int i = 0; i < p_c->materialCount; ++i) {
			materials.push_back(material_to_dict(mats[i]));
		}
	}
	d["materials"] = materials;

	Array capsules;
	for (int i = 0; i < p_c->capsuleCount; ++i) {
		b3CompoundCapsule cc = b3GetCompoundCapsule(p_c, i);
		Dictionary e;
		e["type"] = "capsule";
		e["center1"] = to_gd(cc.capsule.center1);
		e["center2"] = to_gd(cc.capsule.center2);
		e["radius"] = cc.capsule.radius;
		e["material_index"] = (int)cc.materialIndex;
		capsules.push_back(e);
	}
	d["capsules"] = capsules;

	Array hulls;
	for (int i = 0; i < p_c->hullCount; ++i) {
		b3CompoundHull ch = b3GetCompoundHull(p_c, i);
		Dictionary e = hull_to_dict(ch.hull);
		e["transform"] = to_gd_transform(ch.transform);
		e["material_index"] = (int)ch.materialIndex;
		hulls.push_back(e);
	}
	d["hulls"] = hulls;

	Array meshes;
	for (int i = 0; i < p_c->meshCount; ++i) {
		b3CompoundMesh cm = b3GetCompoundMesh(p_c, i);
		Dictionary e = mesh_to_dict(cm.meshData, to_gd(cm.scale));
		e["transform"] = to_gd_transform(cm.transform);
		PackedInt32Array mi;
		if (cm.materialIndices != nullptr) {
			for (int k = 0; k < cm.materialCount; ++k) {
				mi.push_back(cm.materialIndices[k]);
			}
		}
		e["compound_material_indices"] = mi;
		meshes.push_back(e);
	}
	d["meshes"] = meshes;

	Array spheres;
	for (int i = 0; i < p_c->sphereCount; ++i) {
		b3CompoundSphere cs = b3GetCompoundSphere(p_c, i);
		Dictionary e;
		e["type"] = "sphere";
		e["center"] = to_gd(cs.sphere.center);
		e["radius"] = cs.sphere.radius;
		e["material_index"] = (int)cs.materialIndex;
		spheres.push_back(e);
	}
	d["spheres"] = spheres;
	return d;
}

// ---------------------------------------------------------------------------
// Dictionary -> shape (RAII holder; frees whatever it created)
// ---------------------------------------------------------------------------

enum class Kind {
	Invalid,
	Sphere,
	Capsule,
	Hull,
	Mesh,
	HeightField,
	Compound,
	Triangle,
	Proxy,
};

struct GeoShape {
	Kind kind = Kind::Invalid;
	b3Sphere sphere = {};
	b3Capsule capsule = {};
	b3BoxHull box = {};
	b3HullData *owned_hull = nullptr;
	const b3HullData *hull = nullptr;
	b3MeshData *owned_mesh = nullptr;
	b3Mesh mesh = {};
	Vector3 mesh_scale = Vector3(1, 1, 1);
	b3HeightFieldData *owned_hf = nullptr;
	const b3HeightFieldData *hf = nullptr;
	b3CompoundData *owned_compound = nullptr;
	std::vector<uint64_t> compound_storage; // 8-byte aligned copy of serialized bytes
	const b3CompoundData *compound = nullptr;
	b3Vec3 triangle[3] = {};
	std::vector<b3Vec3> points; // proxy point cloud
	float radius = 0.0f; // proxy / triangle radius
	PackedInt32Array degenerate_triangles; // filled by mesh creation

	GeoShape() = default;
	GeoShape(const GeoShape &) = delete;
	GeoShape &operator=(const GeoShape &) = delete;
	~GeoShape() {
		if (owned_hull != nullptr) {
			b3DestroyHull(owned_hull);
		}
		if (owned_mesh != nullptr) {
			b3DestroyMesh(owned_mesh);
		}
		if (owned_hf != nullptr) {
			b3DestroyHeightField(owned_hf);
		}
		if (owned_compound != nullptr) {
			b3DestroyCompound(owned_compound);
		}
	}
};

bool parse_shape(const Dictionary &p_dict, GeoShape &r_shape, int p_depth = 0);

bool to_vec3_vector(const PackedVector3Array &p_in, std::vector<b3Vec3> &r_out) {
	r_out.resize((size_t)p_in.size());
	for (int64_t i = 0; i < p_in.size(); ++i) {
		r_out[(size_t)i] = to_b3(p_in[i]);
	}
	return true;
}

bool parse_mesh(const Dictionary &p_dict, GeoShape &r_shape) {
	PackedVector3Array vertices = dget<PackedVector3Array>(p_dict, "vertices", PackedVector3Array());
	PackedInt32Array indices = dget<PackedInt32Array>(p_dict, "indices", PackedInt32Array());
	PackedByteArray materials = dget<PackedByteArray>(p_dict, "material_indices", PackedByteArray());
	ERR_FAIL_COND_V_MSG(vertices.size() < 3, false, "Box3DGeometry: mesh needs at least 3 vertices.");
	ERR_FAIL_COND_V_MSG(indices.size() < 3 || indices.size() % 3 != 0, false, "Box3DGeometry: mesh indices must be a non-empty multiple of 3.");
	const int vertex_count = (int)vertices.size();
	const int triangle_count = (int)(indices.size() / 3);
	ERR_FAIL_COND_V_MSG(!materials.is_empty() && materials.size() != triangle_count, false,
			"Box3DGeometry: mesh material_indices must have one entry per triangle.");

	std::vector<b3Vec3> verts;
	to_vec3_vector(vertices, verts);
	std::vector<int32_t> idx((size_t)indices.size());
	for (int64_t i = 0; i < indices.size(); ++i) {
		int32_t v = indices[i];
		ERR_FAIL_COND_V_MSG(v < 0 || v >= vertex_count, false, "Box3DGeometry: mesh index out of range.");
		idx[(size_t)i] = v;
	}
	std::vector<uint8_t> mats((size_t)materials.size());
	if (!mats.empty()) {
		memcpy(mats.data(), materials.ptr(), mats.size());
	}

	b3MeshDef def = {};
	def.vertices = verts.data();
	def.stride = 0;
	def.indices = idx.data();
	def.materialIndices = mats.empty() ? nullptr : mats.data();
	def.weldTolerance = dget<float>(p_dict, "weld_tolerance", 0.0f);
	def.vertexCount = vertex_count;
	def.triangleCount = triangle_count;
	def.weldVertices = dget<bool>(p_dict, "weld_vertices", false);
	def.useMedianSplit = dget<bool>(p_dict, "use_median_split", false);
	def.identifyEdges = dget<bool>(p_dict, "identify_edges", true);
	def.clockWiseWinding = dget<bool>(p_dict, "clockwise", false);

	std::vector<int> degenerate((size_t)triangle_count);
	r_shape.owned_mesh = b3CreateMesh(&def, degenerate.data(), triangle_count);
	ERR_FAIL_NULL_V_MSG(r_shape.owned_mesh, false, "Box3DGeometry: b3CreateMesh failed.");
	int deg_count = MIN(r_shape.owned_mesh->degenerateCount, triangle_count);
	for (int i = 0; i < deg_count; ++i) {
		r_shape.degenerate_triangles.push_back(degenerate[(size_t)i]);
	}
	r_shape.mesh_scale = dget<Vector3>(p_dict, "scale", Vector3(1, 1, 1));
	r_shape.mesh.data = r_shape.owned_mesh;
	r_shape.mesh.scale = to_b3(r_shape.mesh_scale);
	r_shape.kind = Kind::Mesh;
	return true;
}

// Fills `r_def` (pointing into the vectors) from a heightfield dictionary.
bool parse_height_field_def(const Dictionary &p_dict, b3HeightFieldDef &r_def, std::vector<float> &r_heights, std::vector<uint8_t> &r_materials) {
	PackedFloat32Array heights = dget<PackedFloat32Array>(p_dict, "heights", PackedFloat32Array());
	PackedByteArray materials = dget<PackedByteArray>(p_dict, "material_indices", PackedByteArray());
	int count_x = dget<int>(p_dict, "count_x", 0);
	int count_z = dget<int>(p_dict, "count_z", 0);
	Vector3 scale = dget<Vector3>(p_dict, "scale", Vector3(1, 1, 1));
	ERR_FAIL_COND_V_MSG(count_x < 2 || count_z < 2, false, "Box3DGeometry: heightfield count_x and count_z must be >= 2.");
	ERR_FAIL_COND_V_MSG((int64_t)count_x * (int64_t)count_z != heights.size(), false,
			"Box3DGeometry: heightfield heights.size() must equal count_x * count_z.");
	const int cell_count = (count_x - 1) * (count_z - 1);
	ERR_FAIL_COND_V_MSG(!materials.is_empty() && materials.size() != cell_count, false,
			"Box3DGeometry: heightfield material_indices must have (count_x-1)*(count_z-1) entries.");
	ERR_FAIL_COND_V_MSG(scale.x <= 0 || scale.y <= 0 || scale.z <= 0, false, "Box3DGeometry: heightfield scale must be positive.");

	r_heights.resize((size_t)heights.size());
	float min_h = FLT_MAX;
	float max_h = -FLT_MAX;
	for (int64_t i = 0; i < heights.size(); ++i) {
		float h = heights[i];
		r_heights[(size_t)i] = h;
		min_h = MIN(min_h, h);
		max_h = MAX(max_h, h);
	}
	// Always provide a material array (b3DumpHeightData requires one).
	r_materials.assign((size_t)cell_count, 0);
	if (!materials.is_empty()) {
		memcpy(r_materials.data(), materials.ptr(), (size_t)cell_count);
	}

	r_def = {};
	r_def.heights = r_heights.data();
	r_def.materialIndices = r_materials.data();
	r_def.scale = to_b3(scale);
	r_def.countX = count_x;
	r_def.countZ = count_z;
	r_def.globalMinimumHeight = dget<float>(p_dict, "global_min_height", min_h);
	r_def.globalMaximumHeight = dget<float>(p_dict, "global_max_height", max_h);
	r_def.clockwiseWinding = dget<bool>(p_dict, "clockwise", false);
	ERR_FAIL_COND_V_MSG(r_def.globalMinimumHeight > r_def.globalMaximumHeight, false,
			"Box3DGeometry: heightfield global_min_height must be <= global_max_height.");
	return true;
}

bool parse_compound_children(const Array &p_children, GeoShape &r_shape, int p_depth) {
	ERR_FAIL_COND_V_MSG(p_children.is_empty(), false, "Box3DGeometry: compound needs at least one child.");
	const size_t n = (size_t)p_children.size();
	std::vector<std::unique_ptr<GeoShape>> holders;
	std::vector<b3CompoundCapsuleDef> capsules;
	std::vector<b3CompoundHullDef> hulls;
	std::vector<b3CompoundMeshDef> meshes;
	std::vector<b3CompoundSphereDef> spheres;
	std::vector<std::vector<b3SurfaceMaterial>> mesh_materials;
	mesh_materials.reserve(n); // pointers into the inner vectors must stay stable

	for (size_t i = 0; i < n; ++i) {
		Variant v = p_children[(int64_t)i];
		ERR_FAIL_COND_V_MSG(v.get_type() != Variant::DICTIONARY, false, "Box3DGeometry: compound children must be Dictionaries.");
		Dictionary child = v;
		holders.push_back(std::make_unique<GeoShape>());
		GeoShape &cs = *holders.back();
		if (!parse_shape(child, cs, p_depth + 1)) {
			return false;
		}
		b3Transform xf = b3Transform_identity;
		if (child.has("transform")) {
			xf = to_b3_transform(dget<Transform3D>(child, "transform", Transform3D()));
		}
		b3SurfaceMaterial material = material_from_variant(child.get("material", Variant()));
		switch (cs.kind) {
			case Kind::Sphere: {
				b3CompoundSphereDef def = {};
				def.sphere.center = b3TransformPoint(xf, cs.sphere.center);
				def.sphere.radius = cs.sphere.radius;
				def.material = material;
				spheres.push_back(def);
			} break;
			case Kind::Capsule: {
				b3CompoundCapsuleDef def = {};
				def.capsule.center1 = b3TransformPoint(xf, cs.capsule.center1);
				def.capsule.center2 = b3TransformPoint(xf, cs.capsule.center2);
				def.capsule.radius = cs.capsule.radius;
				def.material = material;
				capsules.push_back(def);
			} break;
			case Kind::Hull: {
				b3CompoundHullDef def = {};
				def.hull = cs.hull;
				def.transform = xf;
				def.material = material;
				hulls.push_back(def);
			} break;
			case Kind::Mesh: {
				mesh_materials.emplace_back();
				std::vector<b3SurfaceMaterial> &mats = mesh_materials.back();
				Array list = dget<Array>(child, "materials", Array());
				for (int64_t k = 0; k < list.size(); ++k) {
					mats.push_back(material_from_variant(list[k]));
				}
				int needed = MAX(1, cs.owned_mesh->materialCount);
				const uint8_t *tri_mats = b3GetMeshMaterialIndices(cs.owned_mesh);
				if (tri_mats != nullptr) {
					for (int k = 0; k < cs.owned_mesh->triangleCount; ++k) {
						needed = MAX(needed, (int)tri_mats[k] + 1);
					}
				}
				while ((int)mats.size() < needed) {
					mats.push_back(mats.empty() ? material : b3DefaultSurfaceMaterial());
				}
				b3CompoundMeshDef def = {};
				def.meshData = cs.owned_mesh;
				def.transform = xf;
				def.scale = cs.mesh.scale;
				def.materials = mats.data();
				def.materialCount = (int)mats.size();
				meshes.push_back(def);
			} break;
			default:
				ERR_FAIL_V_MSG(false, "Box3DGeometry: compound children must be sphere, capsule, hull-kind or mesh.");
		}
	}

	b3CompoundDef def = {};
	def.capsules = capsules.empty() ? nullptr : capsules.data();
	def.capsuleCount = (int)capsules.size();
	def.hulls = hulls.empty() ? nullptr : hulls.data();
	def.hullCount = (int)hulls.size();
	def.meshes = meshes.empty() ? nullptr : meshes.data();
	def.meshCount = (int)meshes.size();
	def.spheres = spheres.empty() ? nullptr : spheres.data();
	def.sphereCount = (int)spheres.size();
	r_shape.owned_compound = b3CreateCompound(&def);
	ERR_FAIL_NULL_V_MSG(r_shape.owned_compound, false, "Box3DGeometry: b3CreateCompound failed.");
	r_shape.compound = r_shape.owned_compound;
	r_shape.kind = Kind::Compound;
	return true;
}

bool parse_shape(const Dictionary &p_dict, GeoShape &r_shape, int p_depth) {
	ERR_FAIL_COND_V_MSG(p_depth > 1, false, "Box3DGeometry: compounds cannot be nested.");
	String type = String(p_dict.get("type", "")).to_lower();

	if (type == "sphere") {
		r_shape.sphere.center = to_b3(dget<Vector3>(p_dict, "center", Vector3()));
		r_shape.sphere.radius = dget<float>(p_dict, "radius", 0.5f);
		ERR_FAIL_COND_V_MSG(!(r_shape.sphere.radius >= 0.0f), false, "Box3DGeometry: sphere radius must be >= 0.");
		r_shape.kind = Kind::Sphere;
		return true;
	}
	if (type == "capsule") {
		r_shape.capsule.center1 = to_b3(dget<Vector3>(p_dict, "center1", Vector3(0, -0.5, 0)));
		r_shape.capsule.center2 = to_b3(dget<Vector3>(p_dict, "center2", Vector3(0, 0.5, 0)));
		r_shape.capsule.radius = dget<float>(p_dict, "radius", 0.25f);
		ERR_FAIL_COND_V_MSG(!(r_shape.capsule.radius >= 0.0f), false, "Box3DGeometry: capsule radius must be >= 0.");
		r_shape.kind = Kind::Capsule;
		return true;
	}
	if (type == "box") {
		Vector3 he = dget<Vector3>(p_dict, "half_extents", Vector3(0.5, 0.5, 0.5));
		ERR_FAIL_COND_V_MSG(!(he.x > 0 && he.y > 0 && he.z > 0), false, "Box3DGeometry: box half_extents must be positive.");
		b3Transform xf = to_b3_transform(dget<Transform3D>(p_dict, "transform", Transform3D()));
		if (p_dict.has("scale")) {
			r_shape.box = b3MakeScaledBoxHull(to_b3(he), xf, to_b3(dget<Vector3>(p_dict, "scale", Vector3(1, 1, 1))));
		} else {
			r_shape.box = b3MakeTransformedBoxHull((float)he.x, (float)he.y, (float)he.z, xf);
		}
		r_shape.hull = &r_shape.box.base;
		r_shape.kind = Kind::Hull;
		return true;
	}
	if (type == "hull") {
		PackedVector3Array pts = dget<PackedVector3Array>(p_dict, "points", PackedVector3Array());
		ERR_FAIL_COND_V_MSG(pts.size() < 4, false, "Box3DGeometry: hull needs at least 4 points.");
		std::vector<b3Vec3> points;
		to_vec3_vector(pts, points);
		int max_vertices = dget<int>(p_dict, "max_vertex_count", B3_MAX_HULL_VERTICES);
		r_shape.owned_hull = b3CreateHull(points.data(), (int)points.size(), max_vertices);
		ERR_FAIL_NULL_V_MSG(r_shape.owned_hull, false, "Box3DGeometry: b3CreateHull failed (degenerate input or limits exceeded).");
		r_shape.hull = r_shape.owned_hull;
		r_shape.kind = Kind::Hull;
		return true;
	}
	if (type == "cylinder") {
		float height = dget<float>(p_dict, "height", 1.0f);
		float radius = dget<float>(p_dict, "radius", 0.5f);
		int sides = dget<int>(p_dict, "sides", 16);
		ERR_FAIL_COND_V_MSG(!(height > 0 && radius > 0) || sides < 3 || sides > 32, false,
				"Box3DGeometry: cylinder needs height > 0, radius > 0, 3 <= sides <= 32.");
		r_shape.owned_hull = b3CreateCylinder(height, radius, dget<float>(p_dict, "y_offset", 0.0f), sides);
		ERR_FAIL_NULL_V(r_shape.owned_hull, false);
		r_shape.hull = r_shape.owned_hull;
		r_shape.kind = Kind::Hull;
		return true;
	}
	if (type == "cone") {
		float height = dget<float>(p_dict, "height", 1.0f);
		float r1 = dget<float>(p_dict, "radius1", 0.5f);
		float r2 = dget<float>(p_dict, "radius2", 0.25f);
		int slices = dget<int>(p_dict, "slices", 16);
		ERR_FAIL_COND_V_MSG(!(height > 0 && r1 > 0 && r2 > 0) || slices < 4 || slices > 32, false,
				"Box3DGeometry: cone needs height, radius1, radius2 > 0 and 4 <= slices <= 32.");
		r_shape.owned_hull = b3CreateCone(height, r1, r2, slices);
		ERR_FAIL_NULL_V(r_shape.owned_hull, false);
		r_shape.hull = r_shape.owned_hull;
		r_shape.kind = Kind::Hull;
		return true;
	}
	if (type == "rock" || type == "complex_hull") {
		float radius = dget<float>(p_dict, "radius", 0.5f);
		ERR_FAIL_COND_V_MSG(!(radius > 0), false, "Box3DGeometry: radius must be > 0.");
		r_shape.owned_hull = type == "rock" ? b3CreateRock(radius) : b3CreateComplexHull(radius);
		ERR_FAIL_NULL_V(r_shape.owned_hull, false);
		r_shape.hull = r_shape.owned_hull;
		r_shape.kind = Kind::Hull;
		return true;
	}
	if (type == "mesh") {
		return parse_mesh(p_dict, r_shape);
	}
	if (type == "heightfield" || type == "height_field") {
		b3HeightFieldDef def;
		std::vector<float> heights;
		std::vector<uint8_t> materials;
		if (!parse_height_field_def(p_dict, def, heights, materials)) {
			return false;
		}
		r_shape.owned_hf = b3CreateHeightField(&def);
		ERR_FAIL_NULL_V_MSG(r_shape.owned_hf, false, "Box3DGeometry: b3CreateHeightField failed.");
		r_shape.hf = r_shape.owned_hf;
		r_shape.kind = Kind::HeightField;
		return true;
	}
	if (type == "compound") {
		if (p_dict.has("bytes")) {
			PackedByteArray bytes = dget<PackedByteArray>(p_dict, "bytes", PackedByteArray());
			ERR_FAIL_COND_V_MSG(bytes.size() < (int64_t)sizeof(b3CompoundData) || bytes.size() > INT32_MAX, false,
					"Box3DGeometry: compound bytes are too small.");
			r_shape.compound_storage.assign(((size_t)bytes.size() + 7) / 8, 0);
			memcpy(r_shape.compound_storage.data(), bytes.ptr(), (size_t)bytes.size());
			r_shape.compound = b3ValidateCompound((const uint8_t *)r_shape.compound_storage.data(), (int)bytes.size());
			ERR_FAIL_NULL_V_MSG(r_shape.compound, false, "Box3DGeometry: compound bytes failed b3ValidateCompound.");
			r_shape.kind = Kind::Compound;
			return true;
		}
		return parse_compound_children(dget<Array>(p_dict, "children", Array()), r_shape, p_depth);
	}
	if (type == "triangle") {
		r_shape.triangle[0] = to_b3(dget<Vector3>(p_dict, "v1", Vector3()));
		r_shape.triangle[1] = to_b3(dget<Vector3>(p_dict, "v2", Vector3()));
		r_shape.triangle[2] = to_b3(dget<Vector3>(p_dict, "v3", Vector3()));
		r_shape.radius = dget<float>(p_dict, "radius", 0.0f);
		r_shape.kind = Kind::Triangle;
		return true;
	}
	if (type == "proxy") {
		PackedVector3Array pts = dget<PackedVector3Array>(p_dict, "points", PackedVector3Array());
		ERR_FAIL_COND_V_MSG(pts.is_empty() || pts.size() > B3_MAX_SHAPE_CAST_POINTS, false,
				"Box3DGeometry: proxy needs 1..B3_MAX_SHAPE_CAST_POINTS points.");
		to_vec3_vector(pts, r_shape.points);
		r_shape.radius = dget<float>(p_dict, "radius", 0.0f);
		r_shape.kind = Kind::Proxy;
		return true;
	}
	ERR_FAIL_V_MSG(false, "Box3DGeometry: unknown shape type '" + type + "'.");
}

// Builds the GJK point cloud of a convex shape, transformed by `p_xf`.
bool build_proxy(const Dictionary &p_dict, const b3Transform &p_xf, std::vector<b3Vec3> &r_points, float &r_radius) {
	GeoShape s;
	if (!parse_shape(p_dict, s)) {
		return false;
	}
	r_points.clear();
	switch (s.kind) {
		case Kind::Sphere:
			r_points.push_back(s.sphere.center);
			r_radius = s.sphere.radius;
			break;
		case Kind::Capsule:
			r_points.push_back(s.capsule.center1);
			r_points.push_back(s.capsule.center2);
			r_radius = s.capsule.radius;
			break;
		case Kind::Hull: {
			const b3Vec3 *pts = b3GetHullPoints(s.hull);
			ERR_FAIL_NULL_V(pts, false);
			for (int i = 0; i < s.hull->vertexCount; ++i) {
				r_points.push_back(pts[i]);
			}
			r_radius = 0.0f;
		} break;
		case Kind::Triangle:
			r_points.assign(s.triangle, s.triangle + 3);
			r_radius = s.radius;
			break;
		case Kind::Proxy:
			r_points = s.points;
			r_radius = s.radius;
			break;
		default:
			ERR_FAIL_V_MSG(false, "Box3DGeometry: proxies must be sphere, capsule, hull-kind, triangle or proxy.");
	}
	ERR_FAIL_COND_V_MSG(r_points.empty() || r_points.size() > B3_MAX_SHAPE_CAST_POINTS, false, "Box3DGeometry: invalid proxy point count.");
	ERR_FAIL_COND_V_MSG(!(r_radius >= 0.0f), false, "Box3DGeometry: proxy radius must be >= 0.");
	for (b3Vec3 &p : r_points) {
		p = b3TransformPoint(p_xf, p);
	}
	return true;
}

b3ShapeProxy make_proxy(const std::vector<b3Vec3> &p_points, float p_radius) {
	b3ShapeProxy proxy;
	proxy.points = p_points.data();
	proxy.count = (int)p_points.size();
	proxy.radius = p_radius;
	return proxy;
}

// ---------------------------------------------------------------------------
// Callbacks (synchronous; the context lives on the caller's stack)
// ---------------------------------------------------------------------------

bool mesh_query_fcn(b3Vec3 p_a, b3Vec3 p_b, b3Vec3 p_c, int p_triangle_index, void *p_context) {
	Array *out = static_cast<Array *>(p_context);
	Dictionary d;
	d["triangle_index"] = p_triangle_index;
	d["a"] = to_gd(p_a);
	d["b"] = to_gd(p_b);
	d["c"] = to_gd(p_c);
	out->push_back(d);
	return true;
}

bool compound_query_fcn(const b3CompoundData *, int p_child_index, void *p_context) {
	static_cast<PackedInt32Array *>(p_context)->push_back(p_child_index);
	return true;
}

std::atomic<int> s_log_mode{ Box3DGeometry::LOG_STDOUT };

void geometry_log_fcn(const char *p_message) {
	switch (s_log_mode.load(std::memory_order_relaxed)) {
		case Box3DGeometry::LOG_GODOT_WARNING:
			UtilityFunctions::push_warning(String("Box3D: ") + String::utf8(p_message));
			break;
		case Box3DGeometry::LOG_GODOT_PRINT:
			UtilityFunctions::print(String("Box3D: ") + String::utf8(p_message));
			break;
		case Box3DGeometry::LOG_SILENT:
			break;
		default:
			printf("Box3D: %s\n", p_message);
			break;
	}
}

} // namespace

// ===========================================================================
// base.h
// ===========================================================================

Dictionary Box3DGeometry::get_version() {
	b3Version v = b3GetVersion();
	Dictionary d;
	d["major"] = v.major;
	d["minor"] = v.minor;
	d["revision"] = v.revision;
	return d;
}

bool Box3DGeometry::is_double_precision() {
	return b3IsDoublePrecision();
}

int Box3DGeometry::get_max_manifold_points() {
	return b3GetMaxManifoldPoints();
}

bool Box3DGeometry::is_avx2_available() {
	return b3IsAVX2Available();
}

int64_t Box3DGeometry::get_byte_count() {
	return b3GetByteCount();
}

int64_t Box3DGeometry::get_ticks() {
	return u64_to_i64(b3GetTicks());
}

float Box3DGeometry::get_milliseconds(int64_t p_ticks) {
	return b3GetMilliseconds(i64_to_u64(p_ticks));
}

Dictionary Box3DGeometry::get_milliseconds_and_reset(int64_t p_ticks) {
	uint64_t ticks = i64_to_u64(p_ticks);
	float ms = b3GetMillisecondsAndReset(&ticks);
	Dictionary d;
	d["milliseconds"] = ms;
	d["ticks"] = u64_to_i64(ticks);
	return d;
}

void Box3DGeometry::yield_cpu() {
	b3Yield();
}

void Box3DGeometry::sleep(int p_milliseconds) {
	ERR_FAIL_COND(p_milliseconds < 0);
	b3Sleep(p_milliseconds);
}

int64_t Box3DGeometry::hash(const PackedByteArray &p_data, int64_t p_seed) {
	ERR_FAIL_COND_V(p_data.size() > INT32_MAX, 0);
	return (int64_t)b3Hash((uint32_t)p_seed, p_data.ptr(), (int)p_data.size());
}

void Box3DGeometry::set_log_mode(int p_mode) {
	ERR_FAIL_COND_MSG(p_mode < LOG_STDOUT || p_mode > LOG_SILENT, "Box3DGeometry: invalid log mode.");
	s_log_mode.store(p_mode, std::memory_order_relaxed);
	b3SetLogFcn(&geometry_log_fcn);
}

int Box3DGeometry::get_log_mode() {
	return s_log_mode.load(std::memory_order_relaxed);
}

// ===========================================================================
// constants.h
// ===========================================================================

void Box3DGeometry::set_length_units_per_meter(float p_units) {
	ERR_FAIL_COND_MSG(!(p_units > 0.0f), "Box3DGeometry: length units per meter must be > 0.");
	b3SetLengthUnitsPerMeter(p_units);
}

float Box3DGeometry::get_length_units_per_meter() {
	return b3GetLengthUnitsPerMeter();
}

Dictionary Box3DGeometry::get_default_filter() {
	b3Filter f = b3DefaultFilter();
	Dictionary d;
	d["category_bits"] = (int64_t)f.categoryBits;
	d["mask_bits"] = (int64_t)f.maskBits;
	d["group_index"] = (int64_t)f.groupIndex;
	return d;
}

Color Box3DGeometry::get_graph_color(int p_index) {
	if (p_index < 0 || p_index >= B3_GRAPH_COLOR_COUNT) {
		return Color();
	}
	uint32_t c = (uint32_t)b3GetGraphColor(p_index);
	return Color(((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f, (c & 0xFF) / 255.0f);
}

Dictionary Box3DGeometry::get_constants() {
	Dictionary d;
	d["huge"] = (float)B3_HUGE;
	d["linear_slop"] = (float)B3_LINEAR_SLOP;
	d["min_capsule_length"] = (float)B3_MIN_CAPSULE_LENGTH;
	d["overlap_slop"] = (float)B3_OVERLAP_SLOP;
	d["speculative_distance"] = (float)B3_SPECULATIVE_DISTANCE;
	d["max_rotation"] = (float)B3_MAX_ROTATION;
	d["max_aabb_margin"] = (float)B3_MAX_AABB_MARGIN;
	d["aabb_margin_fraction"] = (float)B3_AABB_MARGIN_FRACTION;
	d["time_to_sleep"] = (float)B3_TIME_TO_SLEEP;
	d["max_workers"] = B3_MAX_WORKERS;
	d["max_worlds"] = B3_MAX_WORLDS;
	d["max_manifold_points"] = B3_MAX_MANIFOLD_POINTS;
	d["max_hull_vertices"] = B3_MAX_HULL_VERTICES;
	d["max_hull_faces"] = B3_MAX_HULL_FACES;
	d["max_hull_edges"] = B3_MAX_HULL_EDGES;
	d["max_shape_cast_points"] = B3_MAX_SHAPE_CAST_POINTS;
	d["height_field_hole"] = B3_HEIGHT_FIELD_HOLE;
	d["hash_init"] = B3_HASH_INIT;
	d["min_scale"] = (float)B3_MIN_SCALE;
	d["pi"] = (float)B3_PI;
	return d;
}

// ===========================================================================
// math_functions.h
// ===========================================================================

Dictionary Box3DGeometry::compute_cos_sin(float p_radians) {
	b3CosSin cs = b3ComputeCosSin(p_radians);
	Dictionary d;
	d["cosine"] = cs.cosine;
	d["sine"] = cs.sine;
	return d;
}

Quaternion Box3DGeometry::make_quat_from_matrix(const Basis &p_matrix) {
	b3Matrix3 m = to_b3_matrix(p_matrix);
	return to_gd(b3MakeQuatFromMatrix(&m));
}

Quaternion Box3DGeometry::compute_quat_between_unit_vectors(const Vector3 &p_v1, const Vector3 &p_v2) {
	return to_gd(b3ComputeQuatBetweenUnitVectors(to_b3(p_v1), to_b3(p_v2)));
}

Basis Box3DGeometry::steiner(float p_mass, const Vector3 &p_origin) {
	return to_gd_matrix(b3Steiner(p_mass, to_b3(p_origin)));
}

Vector3 Box3DGeometry::point_to_segment_distance(const Vector3 &p_a, const Vector3 &p_b, const Vector3 &p_q) {
	return to_gd(b3PointToSegmentDistance(to_b3(p_a), to_b3(p_b), to_b3(p_q)));
}

Dictionary Box3DGeometry::line_distance(const Vector3 &p_p1, const Vector3 &p_d1, const Vector3 &p_p2, const Vector3 &p_d2) {
	return segment_result_to_dict(b3LineDistance(to_b3(p_p1), to_b3(p_d1), to_b3(p_p2), to_b3(p_d2)));
}

Dictionary Box3DGeometry::segment_distance(const Vector3 &p_p1, const Vector3 &p_q1, const Vector3 &p_p2, const Vector3 &p_q2) {
	return segment_result_to_dict(b3SegmentDistance(to_b3(p_p1), to_b3(p_q1), to_b3(p_p2), to_b3(p_q2)));
}

bool Box3DGeometry::is_valid_float(float p_value) {
	return b3IsValidFloat(p_value);
}

bool Box3DGeometry::is_valid_vec3(const Vector3 &p_value) {
	return b3IsValidVec3(to_b3(p_value));
}

bool Box3DGeometry::is_valid_quat(const Quaternion &p_value) {
	return b3IsValidQuat(to_b3(p_value));
}

bool Box3DGeometry::is_valid_transform(const Vector3 &p_origin, const Quaternion &p_rotation) {
	return b3IsValidTransform(make_b3_transform(p_origin, p_rotation));
}

bool Box3DGeometry::is_valid_matrix3(const Basis &p_value) {
	return b3IsValidMatrix3(to_b3_matrix(p_value));
}

bool Box3DGeometry::is_valid_aabb(const AABB &p_value) {
	return b3IsValidAABB(to_b3_aabb_raw(p_value));
}

bool Box3DGeometry::is_bounded_aabb(const AABB &p_value) {
	return b3IsBoundedAABB(to_b3_aabb_raw(p_value));
}

bool Box3DGeometry::is_sane_aabb(const AABB &p_value) {
	return b3IsSaneAABB(to_b3_aabb_raw(p_value));
}

bool Box3DGeometry::is_valid_plane(const Plane &p_value) {
	return b3IsValidPlane(to_b3_plane(p_value));
}

bool Box3DGeometry::is_valid_position(const Vector3 &p_value) {
	return b3IsValidPosition(to_b3_pos(p_value));
}

bool Box3DGeometry::is_valid_world_transform(const Vector3 &p_origin, const Quaternion &p_rotation) {
	b3WorldTransform t;
	t.p = to_b3_pos(p_origin);
	t.q = to_b3(p_rotation);
	return b3IsValidWorldTransform(t);
}

// ===========================================================================
// Hulls
// ===========================================================================

namespace {

Dictionary take_hull(b3HullData *p_hull) {
	ERR_FAIL_NULL_V_MSG(p_hull, Dictionary(), "Box3DGeometry: hull creation failed.");
	Dictionary d = hull_to_dict(p_hull);
	b3DestroyHull(p_hull);
	return d;
}

Dictionary take_mesh(b3MeshData *p_mesh) {
	ERR_FAIL_NULL_V_MSG(p_mesh, Dictionary(), "Box3DGeometry: mesh creation failed.");
	Dictionary d = mesh_to_dict(p_mesh, Vector3(1, 1, 1));
	b3DestroyMesh(p_mesh);
	return d;
}

Dictionary take_height_field(b3HeightFieldData *p_hf) {
	ERR_FAIL_NULL_V_MSG(p_hf, Dictionary(), "Box3DGeometry: height field creation failed.");
	Dictionary d = height_field_to_dict(p_hf);
	b3DestroyHeightField(p_hf);
	return d;
}

bool check_half_extents(const Vector3 &p_he) {
	ERR_FAIL_COND_V_MSG(!(p_he.x > 0 && p_he.y > 0 && p_he.z > 0), false, "Box3DGeometry: half extents must be positive.");
	return true;
}

} // namespace

Dictionary Box3DGeometry::create_hull(const PackedVector3Array &p_points, int p_max_vertex_count) {
	ERR_FAIL_COND_V_MSG(p_points.size() < 4, Dictionary(), "Box3DGeometry: hull needs at least 4 points.");
	std::vector<b3Vec3> points;
	to_vec3_vector(p_points, points);
	return take_hull(b3CreateHull(points.data(), (int)points.size(), p_max_vertex_count));
}

Dictionary Box3DGeometry::create_cylinder(float p_height, float p_radius, float p_y_offset, int p_sides) {
	ERR_FAIL_COND_V_MSG(!(p_height > 0 && p_radius > 0) || p_sides < 3 || p_sides > 32, Dictionary(),
			"Box3DGeometry: cylinder needs height > 0, radius > 0, 3 <= sides <= 32.");
	return take_hull(b3CreateCylinder(p_height, p_radius, p_y_offset, p_sides));
}

Dictionary Box3DGeometry::create_cone(float p_height, float p_radius1, float p_radius2, int p_slices) {
	ERR_FAIL_COND_V_MSG(!(p_height > 0 && p_radius1 > 0 && p_radius2 > 0) || p_slices < 4 || p_slices > 32, Dictionary(),
			"Box3DGeometry: cone needs height, radius1, radius2 > 0 and 4 <= slices <= 32.");
	return take_hull(b3CreateCone(p_height, p_radius1, p_radius2, p_slices));
}

Dictionary Box3DGeometry::create_rock(float p_radius) {
	ERR_FAIL_COND_V(!(p_radius > 0), Dictionary());
	return take_hull(b3CreateRock(p_radius));
}

Dictionary Box3DGeometry::create_complex_hull(float p_radius) {
	ERR_FAIL_COND_V(!(p_radius > 0), Dictionary());
	return take_hull(b3CreateComplexHull(p_radius));
}

Dictionary Box3DGeometry::clone_hull(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Hull, Dictionary(), "Box3DGeometry: clone_hull needs a hull-kind shape.");
	return take_hull(b3CloneHull(s.hull));
}

Dictionary Box3DGeometry::clone_and_transform_hull(const Dictionary &p_shape, const Transform3D &p_transform, const Vector3 &p_scale) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Hull, Dictionary(), "Box3DGeometry: clone_and_transform_hull needs a hull-kind shape.");
	return take_hull(b3CloneAndTransformHull(s.hull, to_b3_transform(p_transform), to_b3(p_scale)));
}

Dictionary Box3DGeometry::make_cube_hull(float p_half_width) {
	ERR_FAIL_COND_V(!(p_half_width > 0), Dictionary());
	b3BoxHull box = b3MakeCubeHull(p_half_width);
	return hull_to_dict(&box.base);
}

Dictionary Box3DGeometry::make_box_hull(const Vector3 &p_half_extents) {
	ERR_FAIL_COND_V(!check_half_extents(p_half_extents), Dictionary());
	b3BoxHull box = b3MakeBoxHull((float)p_half_extents.x, (float)p_half_extents.y, (float)p_half_extents.z);
	return hull_to_dict(&box.base);
}

Dictionary Box3DGeometry::make_offset_box_hull(const Vector3 &p_half_extents, const Vector3 &p_offset) {
	ERR_FAIL_COND_V(!check_half_extents(p_half_extents), Dictionary());
	b3BoxHull box = b3MakeOffsetBoxHull((float)p_half_extents.x, (float)p_half_extents.y, (float)p_half_extents.z, to_b3(p_offset));
	return hull_to_dict(&box.base);
}

Dictionary Box3DGeometry::make_transformed_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform) {
	ERR_FAIL_COND_V(!check_half_extents(p_half_extents), Dictionary());
	b3BoxHull box = b3MakeTransformedBoxHull((float)p_half_extents.x, (float)p_half_extents.y, (float)p_half_extents.z,
			to_b3_transform(p_transform));
	return hull_to_dict(&box.base);
}

Dictionary Box3DGeometry::make_scaled_box_hull(const Vector3 &p_half_extents, const Transform3D &p_transform, const Vector3 &p_post_scale) {
	ERR_FAIL_COND_V(!check_half_extents(p_half_extents), Dictionary());
	b3BoxHull box = b3MakeScaledBoxHull(to_b3(p_half_extents), to_b3_transform(p_transform), to_b3(p_post_scale));
	return hull_to_dict(&box.base);
}

Dictionary Box3DGeometry::scale_box(const Vector3 &p_half_extents, const Transform3D &p_transform, const Vector3 &p_post_scale, float p_min_half_width) {
	ERR_FAIL_COND_V_MSG(!(p_min_half_width > 0.0f) || !b3IsValidFloat(p_min_half_width), Dictionary(),
			"Box3DGeometry: min_half_width must be a positive finite number.");
	b3Vec3 half_widths = to_b3(p_half_extents);
	b3Transform xf = to_b3_transform(p_transform);
	b3ScaleBox(&half_widths, &xf, to_b3(p_post_scale), p_min_half_width);
	Dictionary d;
	d["half_extents"] = to_gd(half_widths);
	d["transform"] = to_gd_transform(xf);
	return d;
}

Dictionary Box3DGeometry::get_hull_data(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Hull, Dictionary(), "Box3DGeometry: get_hull_data needs a hull-kind shape.");
	return hull_to_dict(s.hull);
}

// ===========================================================================
// Meshes
// ===========================================================================

Dictionary Box3DGeometry::create_mesh(const Dictionary &p_def) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_mesh(p_def, s), Dictionary());
	Dictionary d = mesh_to_dict(s.owned_mesh, s.mesh_scale);
	d["degenerate_triangles"] = s.degenerate_triangles;
	return d;
}

Dictionary Box3DGeometry::create_grid_mesh(int p_x_count, int p_z_count, float p_cell_width, int p_material_count, bool p_identify_edges) {
	ERR_FAIL_COND_V(p_x_count < 1 || p_z_count < 1 || !(p_cell_width > 0), Dictionary());
	ERR_FAIL_COND_V(p_material_count < 0 || p_material_count > 255, Dictionary());
	return take_mesh(b3CreateGridMesh(p_x_count, p_z_count, p_cell_width, p_material_count, p_identify_edges));
}

Dictionary Box3DGeometry::create_wave_mesh(int p_x_count, int p_z_count, float p_cell_width, float p_amplitude, float p_row_frequency, float p_column_frequency) {
	ERR_FAIL_COND_V(p_x_count < 1 || p_z_count < 1 || !(p_cell_width > 0), Dictionary());
	return take_mesh(b3CreateWaveMesh(p_x_count, p_z_count, p_cell_width, p_amplitude, p_row_frequency, p_column_frequency));
}

Dictionary Box3DGeometry::create_torus_mesh(int p_radial_resolution, int p_tubular_resolution, float p_radius, float p_thickness) {
	ERR_FAIL_COND_V(p_radial_resolution < 3 || p_tubular_resolution < 3 || !(p_radius > 0) || !(p_thickness > 0), Dictionary());
	return take_mesh(b3CreateTorusMesh(p_radial_resolution, p_tubular_resolution, p_radius, p_thickness));
}

Dictionary Box3DGeometry::create_box_mesh(const Vector3 &p_center, const Vector3 &p_extent, bool p_identify_edges) {
	ERR_FAIL_COND_V(!check_half_extents(p_extent), Dictionary());
	return take_mesh(b3CreateBoxMesh(to_b3(p_center), to_b3(p_extent), p_identify_edges));
}

Dictionary Box3DGeometry::create_hollow_box_mesh(const Vector3 &p_center, const Vector3 &p_extent) {
	ERR_FAIL_COND_V(!check_half_extents(p_extent), Dictionary());
	return take_mesh(b3CreateHollowBoxMesh(to_b3(p_center), to_b3(p_extent)));
}

Dictionary Box3DGeometry::create_platform_mesh(const Vector3 &p_center, float p_height, float p_top_width, float p_bottom_width) {
	ERR_FAIL_COND_V(!(p_height > 0 && p_top_width > 0 && p_bottom_width > 0), Dictionary());
	return take_mesh(b3CreatePlatformMesh(to_b3(p_center), p_height, p_top_width, p_bottom_width));
}

Dictionary Box3DGeometry::get_mesh_data(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Mesh, Dictionary(), "Box3DGeometry: get_mesh_data needs a mesh shape.");
	return mesh_to_dict(s.owned_mesh, s.mesh_scale);
}

int Box3DGeometry::get_mesh_bvh_height(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), -1);
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Mesh, -1, "Box3DGeometry: get_mesh_bvh_height needs a mesh shape.");
	return b3GetHeight(s.owned_mesh);
}

Array Box3DGeometry::query_mesh(const Dictionary &p_shape, const AABB &p_bounds) {
	Array out;
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), out);
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Mesh, out, "Box3DGeometry: query_mesh needs a mesh shape.");
	b3QueryMesh(&s.mesh, to_b3_aabb(p_bounds), &mesh_query_fcn, &out);
	return out;
}

// ===========================================================================
// Height fields
// ===========================================================================

Dictionary Box3DGeometry::create_height_field(const Dictionary &p_def) {
	b3HeightFieldDef def;
	std::vector<float> heights;
	std::vector<uint8_t> materials;
	ERR_FAIL_COND_V(!parse_height_field_def(p_def, def, heights, materials), Dictionary());
	return take_height_field(b3CreateHeightField(&def));
}

Dictionary Box3DGeometry::create_grid_height_field(int p_row_count, int p_column_count, const Vector3 &p_scale, bool p_make_holes) {
	ERR_FAIL_COND_V(p_row_count < 2 || p_column_count < 2, Dictionary());
	ERR_FAIL_COND_V(!(p_scale.x > 0 && p_scale.y > 0 && p_scale.z > 0), Dictionary());
	return take_height_field(b3CreateGrid(p_row_count, p_column_count, to_b3(p_scale), p_make_holes));
}

Dictionary Box3DGeometry::create_wave_height_field(int p_row_count, int p_column_count, const Vector3 &p_scale, float p_row_frequency, float p_column_frequency, bool p_make_holes) {
	ERR_FAIL_COND_V(p_row_count < 2 || p_column_count < 2, Dictionary());
	ERR_FAIL_COND_V(!(p_scale.x > 0 && p_scale.y > 0 && p_scale.z > 0), Dictionary());
	return take_height_field(b3CreateWave(p_row_count, p_column_count, to_b3(p_scale), p_row_frequency, p_column_frequency, p_make_holes));
}

Dictionary Box3DGeometry::get_height_field_data(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::HeightField, Dictionary(), "Box3DGeometry: get_height_field_data needs a heightfield shape.");
	return height_field_to_dict(s.hf);
}

bool Box3DGeometry::dump_height_data(const Dictionary &p_def, const String &p_path) {
	b3HeightFieldDef def;
	std::vector<float> heights;
	std::vector<uint8_t> materials;
	ERR_FAIL_COND_V(!parse_height_field_def(p_def, def, heights, materials), false);
	CharString path = globalize(p_path).utf8();
	b3DumpHeightData(&def, path.get_data());
	FILE *f = fopen(path.get_data(), "r");
	if (f == nullptr) {
		return false;
	}
	fclose(f);
	return true;
}

Dictionary Box3DGeometry::load_height_field(const String &p_path) {
	CharString path = globalize(p_path).utf8();
	b3HeightFieldData *hf = b3LoadHeightField(path.get_data());
	ERR_FAIL_NULL_V_MSG(hf, Dictionary(), "Box3DGeometry: b3LoadHeightField failed for '" + p_path + "'.");
	return take_height_field(hf);
}

Array Box3DGeometry::query_height_field(const Dictionary &p_shape, const AABB &p_bounds) {
	Array out;
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), out);
	ERR_FAIL_COND_V_MSG(s.kind != Kind::HeightField, out, "Box3DGeometry: query_height_field needs a heightfield shape.");
	b3QueryHeightField(s.hf, to_b3_aabb(p_bounds), &mesh_query_fcn, &out);
	return out;
}

// ===========================================================================
// Compounds
// ===========================================================================

Dictionary Box3DGeometry::create_compound(const Dictionary &p_def) {
	GeoShape s;
	Dictionary def = p_def.duplicate();
	def["type"] = "compound";
	ERR_FAIL_COND_V(!parse_shape(def, s), Dictionary());
	return compound_to_dict(s.compound);
}

bool Box3DGeometry::validate_compound(const PackedByteArray &p_bytes) {
	if (p_bytes.size() < (int64_t)sizeof(b3CompoundData) || p_bytes.size() > INT32_MAX) {
		return false;
	}
	std::vector<uint64_t> storage(((size_t)p_bytes.size() + 7) / 8, 0);
	memcpy(storage.data(), p_bytes.ptr(), (size_t)p_bytes.size());
	return b3ValidateCompound((const uint8_t *)storage.data(), (int)p_bytes.size()) != nullptr;
}

Dictionary Box3DGeometry::get_compound_info(const Dictionary &p_shape) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Compound, Dictionary(), "Box3DGeometry: get_compound_info needs a compound shape.");
	return compound_to_dict(s.compound);
}

Dictionary Box3DGeometry::get_compound_child(const Dictionary &p_shape, int p_child_index) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Compound, Dictionary(), "Box3DGeometry: get_compound_child needs a compound shape.");
	const b3CompoundData *c = s.compound;
	int child_count = c->capsuleCount + c->hullCount + c->meshCount + c->sphereCount;
	ERR_FAIL_INDEX_V(p_child_index, child_count, Dictionary());

	b3ChildShape child = b3GetCompoundChild(c, p_child_index);
	Dictionary d;
	switch (child.type) {
		case b3_capsuleShape:
			d["center1"] = to_gd(child.capsule.center1);
			d["center2"] = to_gd(child.capsule.center2);
			d["radius"] = child.capsule.radius;
			break;
		case b3_sphereShape:
			d["center"] = to_gd(child.sphere.center);
			d["radius"] = child.sphere.radius;
			break;
		case b3_hullShape:
			d = hull_to_dict(child.hull);
			break;
		case b3_meshShape:
			d = mesh_to_dict(child.mesh.data, to_gd(child.mesh.scale));
			break;
		default:
			break;
	}
	d["type"] = shape_type_name(child.type);
	d["transform"] = to_gd_transform(child.transform);
	d["material_count"] = child.materialCount;
	PackedInt32Array material_indices;
	if (child.materialIndices != nullptr) {
		for (int i = 0; i < child.materialCount; ++i) {
			material_indices.push_back(child.materialIndices[i]);
		}
	}
	d["compound_material_indices"] = material_indices;
	return d;
}

PackedInt32Array Box3DGeometry::query_compound(const Dictionary &p_shape, const AABB &p_bounds) {
	PackedInt32Array out;
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), out);
	ERR_FAIL_COND_V_MSG(s.kind != Kind::Compound, out, "Box3DGeometry: query_compound needs a compound shape.");
	b3QueryCompound(s.compound, to_b3_aabb(p_bounds), &compound_query_fcn, &out);
	return out;
}

// ===========================================================================
// Mass and bounds
// ===========================================================================

Dictionary Box3DGeometry::compute_mass(const Dictionary &p_shape, float p_density) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), Dictionary());
	switch (s.kind) {
		case Kind::Sphere:
			return mass_to_dict(b3ComputeSphereMass(&s.sphere, p_density));
		case Kind::Capsule:
			return mass_to_dict(b3ComputeCapsuleMass(&s.capsule, p_density));
		case Kind::Hull:
			return mass_to_dict(b3ComputeHullMass(s.hull, p_density));
		default:
			ERR_FAIL_V_MSG(Dictionary(), "Box3DGeometry: compute_mass supports sphere, capsule and hull-kind shapes.");
	}
}

AABB Box3DGeometry::compute_aabb(const Dictionary &p_shape, const Transform3D &p_transform) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), AABB());
	b3Transform xf = to_b3_transform(p_transform);
	switch (s.kind) {
		case Kind::Sphere:
			return to_gd_aabb(b3ComputeSphereAABB(&s.sphere, xf));
		case Kind::Capsule:
			return to_gd_aabb(b3ComputeCapsuleAABB(&s.capsule, xf));
		case Kind::Hull:
			return to_gd_aabb(b3ComputeHullAABB(s.hull, xf));
		case Kind::Mesh:
			return to_gd_aabb(b3ComputeMeshAABB(s.owned_mesh, xf, s.mesh.scale));
		case Kind::HeightField:
			return to_gd_aabb(b3ComputeHeightFieldAABB(s.hf, xf));
		case Kind::Compound:
			return to_gd_aabb(b3ComputeCompoundAABB(s.compound, xf));
		default:
			ERR_FAIL_V_MSG(AABB(), "Box3DGeometry: compute_aabb does not support this shape type.");
	}
}

// ===========================================================================
// Queries
// ===========================================================================

bool Box3DGeometry::is_valid_ray(const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction) {
	b3RayCastInput input;
	input.origin = to_b3(p_origin);
	input.translation = to_b3(p_translation);
	input.maxFraction = p_max_fraction;
	return b3IsValidRay(&input);
}

bool Box3DGeometry::overlap(const Dictionary &p_shape, const Transform3D &p_shape_transform, const Dictionary &p_proxy, const Transform3D &p_proxy_transform) {
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), false);
	std::vector<b3Vec3> points;
	float radius = 0.0f;
	ERR_FAIL_COND_V(!build_proxy(p_proxy, to_b3_transform(p_proxy_transform), points, radius), false);
	b3ShapeProxy proxy = make_proxy(points, radius);
	b3Transform xf = to_b3_transform(p_shape_transform);
	switch (s.kind) {
		case Kind::Sphere:
			return b3OverlapSphere(&s.sphere, xf, &proxy);
		case Kind::Capsule:
			return b3OverlapCapsule(&s.capsule, xf, &proxy);
		case Kind::Hull:
			return b3OverlapHull(s.hull, xf, &proxy);
		case Kind::Mesh:
			return b3OverlapMesh(&s.mesh, xf, &proxy);
		case Kind::HeightField:
			return b3OverlapHeightField(s.hf, xf, &proxy);
		case Kind::Compound:
			return b3OverlapCompound(s.compound, xf, &proxy);
		default:
			ERR_FAIL_V_MSG(false, "Box3DGeometry: overlap does not support this shape type.");
	}
}

namespace {

Dictionary do_ray_cast(const Dictionary &p_shape, const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, const Transform3D &p_shape_transform, bool p_hollow) {
	Dictionary miss;
	miss["hit"] = false;
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), miss);
	b3Transform xf = to_b3_transform(p_shape_transform);
	b3RayCastInput input;
	input.origin = b3InvTransformPoint(xf, to_b3(p_origin));
	input.translation = b3InvRotateVector(xf.q, to_b3(p_translation));
	input.maxFraction = p_max_fraction;
	ERR_FAIL_COND_V_MSG(!b3IsValidRay(&input), miss, "Box3DGeometry: invalid ray (non-finite values or bad max_fraction).");

	b3CastOutput out = {};
	if (p_hollow) {
		ERR_FAIL_COND_V_MSG(s.kind != Kind::Sphere, miss, "Box3DGeometry: ray_cast_hollow_sphere needs a sphere.");
		out = b3RayCastHollowSphere(&s.sphere, &input);
		return cast_output_to_dict(out, xf);
	}
	switch (s.kind) {
		case Kind::Sphere:
			out = b3RayCastSphere(&s.sphere, &input);
			break;
		case Kind::Capsule:
			out = b3RayCastCapsule(&s.capsule, &input);
			break;
		case Kind::Hull:
			out = b3RayCastHull(s.hull, &input);
			break;
		case Kind::Mesh:
			out = b3RayCastMesh(&s.mesh, &input);
			break;
		case Kind::HeightField:
			out = b3RayCastHeightField(s.hf, &input);
			break;
		case Kind::Compound:
			out = b3RayCastCompound(s.compound, &input);
			break;
		default:
			ERR_FAIL_V_MSG(miss, "Box3DGeometry: ray_cast does not support this shape type.");
	}
	return cast_output_to_dict(out, xf);
}

} // namespace

Dictionary Box3DGeometry::ray_cast(const Dictionary &p_shape, const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, const Transform3D &p_shape_transform) {
	return do_ray_cast(p_shape, p_origin, p_translation, p_max_fraction, p_shape_transform, false);
}

Dictionary Box3DGeometry::ray_cast_hollow_sphere(const Dictionary &p_shape, const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, const Transform3D &p_shape_transform) {
	return do_ray_cast(p_shape, p_origin, p_translation, p_max_fraction, p_shape_transform, true);
}

Dictionary Box3DGeometry::shape_cast(const Dictionary &p_shape, const Dictionary &p_proxy, const Vector3 &p_translation, float p_max_fraction, bool p_can_encroach, const Transform3D &p_shape_transform, const Transform3D &p_proxy_transform) {
	Dictionary miss;
	miss["hit"] = false;
	GeoShape s;
	ERR_FAIL_COND_V(!parse_shape(p_shape, s), miss);
	b3Transform shape_xf = to_b3_transform(p_shape_transform);
	b3Transform proxy_to_shape = b3InvMulTransforms(shape_xf, to_b3_transform(p_proxy_transform));
	std::vector<b3Vec3> points;
	float radius = 0.0f;
	ERR_FAIL_COND_V(!build_proxy(p_proxy, proxy_to_shape, points, radius), miss);
	ERR_FAIL_COND_V_MSG(!(p_max_fraction >= 0.0f) || !is_valid_vec3(p_translation), miss, "Box3DGeometry: invalid shape cast input.");

	b3ShapeCastInput input;
	input.proxy = make_proxy(points, radius);
	input.translation = b3InvRotateVector(shape_xf.q, to_b3(p_translation));
	input.maxFraction = p_max_fraction;
	input.canEncroach = p_can_encroach;

	b3CastOutput out = {};
	switch (s.kind) {
		case Kind::Sphere:
			out = b3ShapeCastSphere(&s.sphere, &input);
			break;
		case Kind::Capsule:
			out = b3ShapeCastCapsule(&s.capsule, &input);
			break;
		case Kind::Hull:
			out = b3ShapeCastHull(s.hull, &input);
			break;
		case Kind::Mesh:
			out = b3ShapeCastMesh(&s.mesh, &input);
			break;
		case Kind::HeightField:
			out = b3ShapeCastHeightField(s.hf, &input);
			break;
		case Kind::Compound:
			out = b3ShapeCastCompound(s.compound, &input);
			break;
		default:
			ERR_FAIL_V_MSG(miss, "Box3DGeometry: shape_cast does not support this target shape type.");
	}
	return cast_output_to_dict(out, shape_xf);
}

Dictionary Box3DGeometry::shape_distance(const Dictionary &p_proxy_a, const Transform3D &p_transform_a, const Dictionary &p_proxy_b, const Transform3D &p_transform_b, bool p_use_radii, const Dictionary &p_cache, int p_simplex_capacity) {
	std::vector<b3Vec3> points_a, points_b;
	float radius_a = 0.0f, radius_b = 0.0f;
	ERR_FAIL_COND_V(!build_proxy(p_proxy_a, b3Transform_identity, points_a, radius_a), Dictionary());
	ERR_FAIL_COND_V(!build_proxy(p_proxy_b, b3Transform_identity, points_b, radius_b), Dictionary());
	ERR_FAIL_COND_V(p_simplex_capacity < 0 || p_simplex_capacity > 1024, Dictionary());

	b3Transform xf_a = to_b3_transform(p_transform_a);
	b3DistanceInput input;
	input.proxyA = make_proxy(points_a, radius_a);
	input.proxyB = make_proxy(points_b, radius_b);
	input.transform = b3InvMulTransforms(xf_a, to_b3_transform(p_transform_b));
	input.useRadii = p_use_radii;

	b3SimplexCache cache = simplex_cache_from_dict(p_cache, (int)points_a.size(), (int)points_b.size());
	std::vector<b3Simplex> simplexes((size_t)p_simplex_capacity);
	b3DistanceOutput out = b3ShapeDistance(&input, &cache, simplexes.empty() ? nullptr : simplexes.data(), p_simplex_capacity);

	Dictionary d;
	d["point_a"] = to_gd(b3TransformPoint(xf_a, out.pointA));
	d["point_b"] = to_gd(b3TransformPoint(xf_a, out.pointB));
	d["normal"] = to_gd(b3RotateVector(xf_a.q, out.normal));
	d["distance"] = out.distance;
	d["iterations"] = out.iterations;
	d["simplex_count"] = out.simplexCount;
	d["cache"] = simplex_cache_to_dict(cache);
	Array simplex_list;
	for (int i = 0; i < out.simplexCount && i < p_simplex_capacity; ++i) {
		const b3Simplex &sx = simplexes[(size_t)i];
		Array verts;
		for (int k = 0; k < sx.count && k < 4; ++k) {
			const b3SimplexVertex &v = sx.vertices[k];
			Dictionary vd;
			vd["w_a"] = to_gd(v.wA);
			vd["w_b"] = to_gd(v.wB);
			vd["w"] = to_gd(v.w);
			vd["a"] = v.a;
			vd["index_a"] = v.indexA;
			vd["index_b"] = v.indexB;
			verts.push_back(vd);
		}
		simplex_list.push_back(verts);
	}
	d["simplexes"] = simplex_list; // in frame A
	return d;
}

Dictionary Box3DGeometry::shape_cast_pair(const Dictionary &p_proxy_a, const Transform3D &p_transform_a, const Dictionary &p_proxy_b, const Transform3D &p_transform_b, const Vector3 &p_translation_b, float p_max_fraction, bool p_can_encroach) {
	Dictionary miss;
	miss["hit"] = false;
	std::vector<b3Vec3> points_a, points_b;
	float radius_a = 0.0f, radius_b = 0.0f;
	ERR_FAIL_COND_V(!build_proxy(p_proxy_a, b3Transform_identity, points_a, radius_a), miss);
	ERR_FAIL_COND_V(!build_proxy(p_proxy_b, b3Transform_identity, points_b, radius_b), miss);
	ERR_FAIL_COND_V_MSG(!(p_max_fraction >= 0.0f) || !is_valid_vec3(p_translation_b), miss, "Box3DGeometry: invalid shape cast input.");

	b3Transform xf_a = to_b3_transform(p_transform_a);
	b3ShapeCastPairInput input;
	input.proxyA = make_proxy(points_a, radius_a);
	input.proxyB = make_proxy(points_b, radius_b);
	input.transform = b3InvMulTransforms(xf_a, to_b3_transform(p_transform_b));
	input.translationB = b3InvRotateVector(xf_a.q, to_b3(p_translation_b));
	input.maxFraction = p_max_fraction;
	input.canEncroach = p_can_encroach;
	return cast_output_to_dict(b3ShapeCast(&input), xf_a);
}

Transform3D Box3DGeometry::get_sweep_transform(const Dictionary &p_sweep, float p_time) {
	b3Sweep sweep = sweep_from_dict(p_sweep);
	return to_gd_transform(b3GetSweepTransform(&sweep, p_time));
}

Dictionary Box3DGeometry::time_of_impact(const Dictionary &p_proxy_a, const Dictionary &p_sweep_a, const Dictionary &p_proxy_b, const Dictionary &p_sweep_b, float p_max_fraction) {
	std::vector<b3Vec3> points_a, points_b;
	float radius_a = 0.0f, radius_b = 0.0f;
	ERR_FAIL_COND_V(!build_proxy(p_proxy_a, b3Transform_identity, points_a, radius_a), Dictionary());
	ERR_FAIL_COND_V(!build_proxy(p_proxy_b, b3Transform_identity, points_b, radius_b), Dictionary());

	b3TOIInput input;
	input.proxyA = make_proxy(points_a, radius_a);
	input.proxyB = make_proxy(points_b, radius_b);
	input.sweepA = sweep_from_dict(p_sweep_a);
	input.sweepB = sweep_from_dict(p_sweep_b);
	input.maxFraction = p_max_fraction;
	b3TOIOutput out = b3TimeOfImpact(&input);

	Dictionary d;
	d["state"] = (int)out.state;
	d["point"] = to_gd(out.point);
	d["normal"] = to_gd(out.normal);
	d["fraction"] = out.fraction;
	d["distance"] = out.distance;
	d["distance_iterations"] = out.distanceIterations;
	d["push_back_iterations"] = out.pushBackIterations;
	d["root_iterations"] = out.rootIterations;
	d["used_fallback"] = out.usedFallback;
	return d;
}

// ===========================================================================
// Manifolds
// ===========================================================================

namespace {

b3SATCache sat_cache_from_dict(const Dictionary &p_d, const b3HullData *p_a, const b3HullData *p_b) {
	b3SATCache c = {};
	if (p_d.is_empty()) {
		return c;
	}
	int type = dget<int>(p_d, "type", 0);
	int ia = dget<int>(p_d, "index_a", 0);
	int ib = dget<int>(p_d, "index_b", 0);
	bool ok = false;
	switch (type) {
		case b3_faceAxisA:
			ok = ia >= 0 && ia < p_a->faceCount && ib >= 0 && ib < 256;
			break;
		case b3_faceAxisB:
			ok = ib >= 0 && ib < p_b->faceCount && ia >= 0 && ia < 256;
			break;
		case b3_edgePairAxis:
			ok = ia >= 0 && ia < p_a->edgeCount && ib >= 0 && ib < p_b->edgeCount;
			break;
		default:
			ok = false; // other cache types carry no indices worth restoring
			break;
	}
	if (!ok) {
		return c;
	}
	c.separation = dget<float>(p_d, "separation", 0.0f);
	c.type = (uint8_t)type;
	c.indexA = (uint8_t)ia;
	c.indexB = (uint8_t)ib;
	return c;
}

void transform_local_manifold(b3LocalManifold &r_m, const b3Transform &p_xf) {
	r_m.normal = b3RotateVector(p_xf.q, r_m.normal);
	r_m.triangleNormal = b3RotateVector(p_xf.q, r_m.triangleNormal);
	for (int i = 0; i < r_m.pointCount; ++i) {
		r_m.points[i].point = b3TransformPoint(p_xf, r_m.points[i].point);
	}
}

} // namespace

Dictionary Box3DGeometry::collide(const Dictionary &p_shape_a, const Dictionary &p_shape_b, const Transform3D &p_transform_b_to_a, int p_capacity, const Dictionary &p_cache, bool p_enable_speculative, bool p_handle_ghosts) {
	ERR_FAIL_COND_V_MSG(p_capacity < 1 || p_capacity > 256, Dictionary(), "Box3DGeometry: capacity must be in [1, 256].");
	GeoShape a, b;
	ERR_FAIL_COND_V(!parse_shape(p_shape_a, a), Dictionary());
	ERR_FAIL_COND_V(!parse_shape(p_shape_b, b), Dictionary());
	b3Transform xf = to_b3_transform(p_transform_b_to_a);

	// Mesh (A) versus convex (B): returns full manifolds.
	if (a.kind == Kind::Mesh && (b.kind == Kind::Hull || b.kind == Kind::Sphere)) {
		std::vector<b3Manifold> manifolds((size_t)p_capacity);
		int count = 0;
		if (b.kind == Kind::Hull) {
			count = b3CollideMeshAndHull(manifolds.data(), p_capacity, &a.mesh, b.hull, xf, p_enable_speculative, p_handle_ghosts);
		} else {
			count = b3CollideMeshAndSphere(manifolds.data(), p_capacity, &a.mesh, &b.sphere, xf, p_enable_speculative, p_handle_ghosts);
		}
		Array list;
		for (int i = 0; i < count && i < p_capacity; ++i) {
			list.push_back(manifold_to_dict(manifolds[(size_t)i]));
		}
		Dictionary d;
		d["manifold_count"] = count;
		d["manifolds"] = list;
		return d;
	}

	std::vector<b3LocalManifoldPoint> point_buffer((size_t)p_capacity);
	b3LocalManifold m = {};
	m.points = point_buffer.data();
	Dictionary d;

	if (a.kind == Kind::Sphere && b.kind == Kind::Sphere) {
		b3CollideSpheres(&m, p_capacity, &a.sphere, &b.sphere, xf);
	} else if (a.kind == Kind::Capsule && b.kind == Kind::Sphere) {
		b3CollideCapsuleAndSphere(&m, p_capacity, &a.capsule, &b.sphere, xf);
	} else if (a.kind == Kind::Capsule && b.kind == Kind::Capsule) {
		b3CollideCapsules(&m, p_capacity, &a.capsule, &b.capsule, xf);
	} else if (a.kind == Kind::Hull && b.kind == Kind::Sphere) {
		b3SimplexCache cache = simplex_cache_from_dict(p_cache, a.hull->vertexCount, 1);
		b3CollideHullAndSphere(&m, p_capacity, a.hull, &b.sphere, xf, &cache);
		d["cache"] = simplex_cache_to_dict(cache);
	} else if (a.kind == Kind::Hull && b.kind == Kind::Capsule) {
		b3SimplexCache cache = simplex_cache_from_dict(p_cache, a.hull->vertexCount, 2);
		b3CollideHullAndCapsule(&m, p_capacity, a.hull, &b.capsule, xf, &cache);
		d["cache"] = simplex_cache_to_dict(cache);
	} else if (a.kind == Kind::Hull && b.kind == Kind::Hull) {
		b3SATCache cache = sat_cache_from_dict(p_cache, a.hull, b.hull);
		b3CollideHulls(&m, p_capacity, a.hull, b.hull, xf, &cache);
		d["cache"] = sat_cache_to_dict(cache);
	} else if (a.kind == Kind::Triangle && (b.kind == Kind::Sphere || b.kind == Kind::Capsule || b.kind == Kind::Hull)) {
		// The triangle functions work in a single frame. Bring the triangle into B's
		// frame, collide, then map the result back into frame A.
		b3Vec3 tri[3];
		for (int i = 0; i < 3; ++i) {
			tri[i] = b3InvTransformPoint(xf, a.triangle[i]);
		}
		if (b.kind == Kind::Sphere) {
			b3CollideTriangleAndSphere(&m, p_capacity, tri, &b.sphere);
		} else if (b.kind == Kind::Capsule) {
			b3SimplexCache cache = simplex_cache_from_dict(p_cache, 3, 2);
			b3CollideTriangleAndCapsule(&m, p_capacity, tri, &b.capsule, &cache);
			d["cache"] = simplex_cache_to_dict(cache);
		} else {
			// The triangle SAT cache layout is internal; always start fresh.
			b3SATCache cache = {};
			b3CollideTriangleAndHull(&m, p_capacity, tri[0], tri[1], tri[2], b.hull, &cache, p_enable_speculative);
			d["cache"] = sat_cache_to_dict(cache);
		}
		transform_local_manifold(m, xf);
	} else {
		ERR_FAIL_V_MSG(Dictionary(),
				"Box3DGeometry: unsupported collide pair. Supported (A, B): sphere/sphere, capsule/sphere, capsule/capsule, "
				"hull/sphere, hull/capsule, hull/hull, triangle/{sphere,capsule,hull}, mesh/{hull,sphere}.");
	}

	Dictionary md = local_manifold_to_dict(m);
	Array keys = md.keys();
	for (int64_t i = 0; i < keys.size(); ++i) {
		d[keys[i]] = md[keys[i]];
	}
	return d;
}

namespace {

bool fill_points_2d(const PackedVector2Array &p_points, const PackedFloat32Array &p_separations, std::vector<b3Point2D> &r_out) {
	ERR_FAIL_COND_V_MSG(!p_separations.is_empty() && p_separations.size() != p_points.size(), false,
			"Box3DGeometry: separations must be empty or match the point count.");
	r_out.resize((size_t)p_points.size());
	for (int64_t i = 0; i < p_points.size(); ++i) {
		b3Point2D &p = r_out[(size_t)i];
		p.p.x = (float)p_points[i].x;
		p.p.y = (float)p_points[i].y;
		p.separation = p_separations.is_empty() ? 0.0f : p_separations[i];
		p.originalIndex = (int)i;
	}
	return true;
}

Array points_2d_to_array(const b3Point2D *p_points, int p_count) {
	Array out;
	for (int i = 0; i < p_count; ++i) {
		Dictionary d;
		d["point"] = Vector2(p_points[i].p.x, p_points[i].p.y);
		d["separation"] = p_points[i].separation;
		d["original_index"] = p_points[i].originalIndex;
		out.push_back(d);
	}
	return out;
}

} // namespace

Array Box3DGeometry::hull_2d(const PackedVector2Array &p_points, const PackedFloat32Array &p_separations, int p_flags) {
	std::vector<b3Point2D> pts;
	ERR_FAIL_COND_V(!fill_points_2d(p_points, p_separations, pts), Array());
	if (pts.empty()) {
		return Array();
	}
	std::vector<b3Point2D> hull(2 * pts.size() + 2);
	int count = b3Hull2D(pts.data(), (int)pts.size(), hull.data(), p_flags);
	return points_2d_to_array(hull.data(), MIN(count, (int)hull.size()));
}

Array Box3DGeometry::simplify_hull_2d(const PackedVector2Array &p_points, const PackedFloat32Array &p_separations, int p_target) {
	ERR_FAIL_COND_V_MSG(p_target < 3, Array(), "Box3DGeometry: simplify_hull_2d target must be >= 3.");
	std::vector<b3Point2D> pts;
	ERR_FAIL_COND_V(!fill_points_2d(p_points, p_separations, pts), Array());
	int count = b3SimplifyHull2D(pts.data(), (int)pts.size(), p_target);
	return points_2d_to_array(pts.data(), MIN(count, (int)pts.size()));
}

// ===========================================================================
// Character planes
// ===========================================================================

namespace {

bool planes_from_array(const Array &p_planes, std::vector<b3CollisionPlane> &r_out) {
	r_out.resize((size_t)p_planes.size());
	for (int64_t i = 0; i < p_planes.size(); ++i) {
		Variant v = p_planes[i];
		ERR_FAIL_COND_V_MSG(v.get_type() != Variant::DICTIONARY, false, "Box3DGeometry: collision planes must be Dictionaries.");
		Dictionary d = v;
		b3CollisionPlane &cp = r_out[(size_t)i];
		cp.plane = to_b3_plane(dget<Plane>(d, "plane", Plane()));
		cp.pushLimit = dget<float>(d, "push_limit", FLT_MAX);
		cp.push = dget<float>(d, "push", 0.0f);
		cp.clipVelocity = dget<bool>(d, "clip_velocity", true);
	}
	return true;
}

} // namespace

Dictionary Box3DGeometry::solve_planes(const Vector3 &p_target_delta, const Array &p_planes) {
	std::vector<b3CollisionPlane> planes;
	ERR_FAIL_COND_V(!planes_from_array(p_planes, planes), Dictionary());
	b3PlaneSolverResult r = b3SolvePlanes(to_b3(p_target_delta), planes.empty() ? nullptr : planes.data(), (int)planes.size());
	PackedFloat32Array pushes;
	for (const b3CollisionPlane &cp : planes) {
		pushes.push_back(cp.push);
	}
	Dictionary d;
	d["delta"] = to_gd(r.delta);
	d["iteration_count"] = r.iterationCount;
	d["pushes"] = pushes;
	return d;
}

Vector3 Box3DGeometry::clip_vector(const Vector3 &p_vector, const Array &p_planes) {
	std::vector<b3CollisionPlane> planes;
	ERR_FAIL_COND_V(!planes_from_array(p_planes, planes), p_vector);
	return to_gd(b3ClipVector(to_b3(p_vector), planes.empty() ? nullptr : planes.data(), (int)planes.size()));
}

// ===========================================================================
// Bindings
// ===========================================================================

void Box3DGeometry::_bind_methods() {
	const StringName cls = get_class_static();
	const Transform3D identity;

	// base.h
	ClassDB::bind_static_method(cls, D_METHOD("get_version"), &Box3DGeometry::get_version);
	ClassDB::bind_static_method(cls, D_METHOD("is_double_precision"), &Box3DGeometry::is_double_precision);
	ClassDB::bind_static_method(cls, D_METHOD("get_max_manifold_points"), &Box3DGeometry::get_max_manifold_points);
	ClassDB::bind_static_method(cls, D_METHOD("is_avx2_available"), &Box3DGeometry::is_avx2_available);
	ClassDB::bind_static_method(cls, D_METHOD("get_byte_count"), &Box3DGeometry::get_byte_count);
	ClassDB::bind_static_method(cls, D_METHOD("get_ticks"), &Box3DGeometry::get_ticks);
	ClassDB::bind_static_method(cls, D_METHOD("get_milliseconds", "ticks"), &Box3DGeometry::get_milliseconds);
	ClassDB::bind_static_method(cls, D_METHOD("get_milliseconds_and_reset", "ticks"), &Box3DGeometry::get_milliseconds_and_reset);
	ClassDB::bind_static_method(cls, D_METHOD("yield_cpu"), &Box3DGeometry::yield_cpu);
	ClassDB::bind_static_method(cls, D_METHOD("sleep", "milliseconds"), &Box3DGeometry::sleep);
	ClassDB::bind_static_method(cls, D_METHOD("hash", "data", "seed"), &Box3DGeometry::hash, DEFVAL(B3_HASH_INIT));
	ClassDB::bind_static_method(cls, D_METHOD("set_log_mode", "mode"), &Box3DGeometry::set_log_mode);
	ClassDB::bind_static_method(cls, D_METHOD("get_log_mode"), &Box3DGeometry::get_log_mode);

	// constants.h
	ClassDB::bind_static_method(cls, D_METHOD("set_length_units_per_meter", "units"), &Box3DGeometry::set_length_units_per_meter);
	ClassDB::bind_static_method(cls, D_METHOD("get_length_units_per_meter"), &Box3DGeometry::get_length_units_per_meter);
	ClassDB::bind_static_method(cls, D_METHOD("get_constants"), &Box3DGeometry::get_constants);
	ClassDB::bind_static_method(cls, D_METHOD("get_default_filter"), &Box3DGeometry::get_default_filter);
	ClassDB::bind_static_method(cls, D_METHOD("get_graph_color", "index"), &Box3DGeometry::get_graph_color);

	// math_functions.h
	ClassDB::bind_static_method(cls, D_METHOD("compute_cos_sin", "radians"), &Box3DGeometry::compute_cos_sin);
	ClassDB::bind_static_method(cls, D_METHOD("make_quat_from_matrix", "matrix"), &Box3DGeometry::make_quat_from_matrix);
	ClassDB::bind_static_method(cls, D_METHOD("compute_quat_between_unit_vectors", "v1", "v2"), &Box3DGeometry::compute_quat_between_unit_vectors);
	ClassDB::bind_static_method(cls, D_METHOD("steiner", "mass", "origin"), &Box3DGeometry::steiner);
	ClassDB::bind_static_method(cls, D_METHOD("point_to_segment_distance", "a", "b", "q"), &Box3DGeometry::point_to_segment_distance);
	ClassDB::bind_static_method(cls, D_METHOD("line_distance", "p1", "d1", "p2", "d2"), &Box3DGeometry::line_distance);
	ClassDB::bind_static_method(cls, D_METHOD("segment_distance", "p1", "q1", "p2", "q2"), &Box3DGeometry::segment_distance);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_float", "value"), &Box3DGeometry::is_valid_float);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_vec3", "value"), &Box3DGeometry::is_valid_vec3);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_quat", "value"), &Box3DGeometry::is_valid_quat);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_transform", "origin", "rotation"), &Box3DGeometry::is_valid_transform);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_matrix3", "value"), &Box3DGeometry::is_valid_matrix3);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_aabb", "value"), &Box3DGeometry::is_valid_aabb);
	ClassDB::bind_static_method(cls, D_METHOD("is_bounded_aabb", "value"), &Box3DGeometry::is_bounded_aabb);
	ClassDB::bind_static_method(cls, D_METHOD("is_sane_aabb", "value"), &Box3DGeometry::is_sane_aabb);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_plane", "value"), &Box3DGeometry::is_valid_plane);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_position", "value"), &Box3DGeometry::is_valid_position);
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_world_transform", "origin", "rotation"), &Box3DGeometry::is_valid_world_transform);

	// hulls
	ClassDB::bind_static_method(cls, D_METHOD("create_hull", "points", "max_vertex_count"), &Box3DGeometry::create_hull, DEFVAL(B3_MAX_HULL_VERTICES));
	ClassDB::bind_static_method(cls, D_METHOD("create_cylinder", "height", "radius", "y_offset", "sides"), &Box3DGeometry::create_cylinder, DEFVAL(0.0f), DEFVAL(16));
	ClassDB::bind_static_method(cls, D_METHOD("create_cone", "height", "radius1", "radius2", "slices"), &Box3DGeometry::create_cone, DEFVAL(16));
	ClassDB::bind_static_method(cls, D_METHOD("create_rock", "radius"), &Box3DGeometry::create_rock);
	ClassDB::bind_static_method(cls, D_METHOD("create_complex_hull", "radius"), &Box3DGeometry::create_complex_hull);
	ClassDB::bind_static_method(cls, D_METHOD("clone_hull", "shape"), &Box3DGeometry::clone_hull);
	ClassDB::bind_static_method(cls, D_METHOD("clone_and_transform_hull", "shape", "transform", "scale"), &Box3DGeometry::clone_and_transform_hull, DEFVAL(Vector3(1, 1, 1)));
	ClassDB::bind_static_method(cls, D_METHOD("make_cube_hull", "half_width"), &Box3DGeometry::make_cube_hull);
	ClassDB::bind_static_method(cls, D_METHOD("make_box_hull", "half_extents"), &Box3DGeometry::make_box_hull);
	ClassDB::bind_static_method(cls, D_METHOD("make_offset_box_hull", "half_extents", "offset"), &Box3DGeometry::make_offset_box_hull);
	ClassDB::bind_static_method(cls, D_METHOD("make_transformed_box_hull", "half_extents", "transform"), &Box3DGeometry::make_transformed_box_hull);
	ClassDB::bind_static_method(cls, D_METHOD("make_scaled_box_hull", "half_extents", "transform", "post_scale"), &Box3DGeometry::make_scaled_box_hull);
	ClassDB::bind_static_method(cls, D_METHOD("scale_box", "half_extents", "transform", "post_scale", "min_half_width"), &Box3DGeometry::scale_box);
	ClassDB::bind_static_method(cls, D_METHOD("get_hull_data", "shape"), &Box3DGeometry::get_hull_data);

	// meshes
	ClassDB::bind_static_method(cls, D_METHOD("create_mesh", "def"), &Box3DGeometry::create_mesh);
	ClassDB::bind_static_method(cls, D_METHOD("create_grid_mesh", "x_count", "z_count", "cell_width", "material_count", "identify_edges"), &Box3DGeometry::create_grid_mesh, DEFVAL(0), DEFVAL(true));
	ClassDB::bind_static_method(cls, D_METHOD("create_wave_mesh", "x_count", "z_count", "cell_width", "amplitude", "row_frequency", "column_frequency"), &Box3DGeometry::create_wave_mesh);
	ClassDB::bind_static_method(cls, D_METHOD("create_torus_mesh", "radial_resolution", "tubular_resolution", "radius", "thickness"), &Box3DGeometry::create_torus_mesh);
	ClassDB::bind_static_method(cls, D_METHOD("create_box_mesh", "center", "extent", "identify_edges"), &Box3DGeometry::create_box_mesh, DEFVAL(true));
	ClassDB::bind_static_method(cls, D_METHOD("create_hollow_box_mesh", "center", "extent"), &Box3DGeometry::create_hollow_box_mesh);
	ClassDB::bind_static_method(cls, D_METHOD("create_platform_mesh", "center", "height", "top_width", "bottom_width"), &Box3DGeometry::create_platform_mesh);
	ClassDB::bind_static_method(cls, D_METHOD("get_mesh_data", "shape"), &Box3DGeometry::get_mesh_data);
	ClassDB::bind_static_method(cls, D_METHOD("get_mesh_bvh_height", "shape"), &Box3DGeometry::get_mesh_bvh_height);
	ClassDB::bind_static_method(cls, D_METHOD("query_mesh", "shape", "bounds"), &Box3DGeometry::query_mesh);

	// height fields
	ClassDB::bind_static_method(cls, D_METHOD("create_height_field", "def"), &Box3DGeometry::create_height_field);
	ClassDB::bind_static_method(cls, D_METHOD("create_grid_height_field", "row_count", "column_count", "scale", "make_holes"), &Box3DGeometry::create_grid_height_field, DEFVAL(false));
	ClassDB::bind_static_method(cls, D_METHOD("create_wave_height_field", "row_count", "column_count", "scale", "row_frequency", "column_frequency", "make_holes"), &Box3DGeometry::create_wave_height_field, DEFVAL(false));
	ClassDB::bind_static_method(cls, D_METHOD("get_height_field_data", "shape"), &Box3DGeometry::get_height_field_data);
	ClassDB::bind_static_method(cls, D_METHOD("dump_height_data", "def", "path"), &Box3DGeometry::dump_height_data);
	ClassDB::bind_static_method(cls, D_METHOD("load_height_field", "path"), &Box3DGeometry::load_height_field);
	ClassDB::bind_static_method(cls, D_METHOD("query_height_field", "shape", "bounds"), &Box3DGeometry::query_height_field);

	// compounds
	ClassDB::bind_static_method(cls, D_METHOD("create_compound", "def"), &Box3DGeometry::create_compound);
	ClassDB::bind_static_method(cls, D_METHOD("validate_compound", "bytes"), &Box3DGeometry::validate_compound);
	ClassDB::bind_static_method(cls, D_METHOD("get_compound_info", "shape"), &Box3DGeometry::get_compound_info);
	ClassDB::bind_static_method(cls, D_METHOD("get_compound_child", "shape", "child_index"), &Box3DGeometry::get_compound_child);
	ClassDB::bind_static_method(cls, D_METHOD("query_compound", "shape", "bounds"), &Box3DGeometry::query_compound);

	// mass / bounds
	ClassDB::bind_static_method(cls, D_METHOD("compute_mass", "shape", "density"), &Box3DGeometry::compute_mass, DEFVAL(1.0f));
	ClassDB::bind_static_method(cls, D_METHOD("compute_aabb", "shape", "transform"), &Box3DGeometry::compute_aabb, DEFVAL(identity));

	// queries
	ClassDB::bind_static_method(cls, D_METHOD("is_valid_ray", "origin", "translation", "max_fraction"), &Box3DGeometry::is_valid_ray, DEFVAL(1.0f));
	ClassDB::bind_static_method(cls, D_METHOD("overlap", "shape", "shape_transform", "proxy", "proxy_transform"), &Box3DGeometry::overlap);
	ClassDB::bind_static_method(cls, D_METHOD("ray_cast", "shape", "origin", "translation", "max_fraction", "shape_transform"), &Box3DGeometry::ray_cast, DEFVAL(1.0f), DEFVAL(identity));
	ClassDB::bind_static_method(cls, D_METHOD("ray_cast_hollow_sphere", "shape", "origin", "translation", "max_fraction", "shape_transform"), &Box3DGeometry::ray_cast_hollow_sphere, DEFVAL(1.0f), DEFVAL(identity));
	ClassDB::bind_static_method(cls, D_METHOD("shape_cast", "shape", "proxy", "translation", "max_fraction", "can_encroach", "shape_transform", "proxy_transform"), &Box3DGeometry::shape_cast, DEFVAL(1.0f), DEFVAL(false), DEFVAL(identity), DEFVAL(identity));
	ClassDB::bind_static_method(cls, D_METHOD("shape_distance", "proxy_a", "transform_a", "proxy_b", "transform_b", "use_radii", "cache", "simplex_capacity"), &Box3DGeometry::shape_distance, DEFVAL(true), DEFVAL(Dictionary()), DEFVAL(0));
	ClassDB::bind_static_method(cls, D_METHOD("shape_cast_pair", "proxy_a", "transform_a", "proxy_b", "transform_b", "translation_b", "max_fraction", "can_encroach"), &Box3DGeometry::shape_cast_pair, DEFVAL(1.0f), DEFVAL(false));
	ClassDB::bind_static_method(cls, D_METHOD("get_sweep_transform", "sweep", "time"), &Box3DGeometry::get_sweep_transform);
	ClassDB::bind_static_method(cls, D_METHOD("time_of_impact", "proxy_a", "sweep_a", "proxy_b", "sweep_b", "max_fraction"), &Box3DGeometry::time_of_impact, DEFVAL(1.0f));

	// manifolds
	ClassDB::bind_static_method(cls, D_METHOD("collide", "shape_a", "shape_b", "transform_b_to_a", "capacity", "cache", "enable_speculative", "handle_ghosts"), &Box3DGeometry::collide, DEFVAL(identity), DEFVAL(8), DEFVAL(Dictionary()), DEFVAL(true), DEFVAL(true));
	ClassDB::bind_static_method(cls, D_METHOD("hull_2d", "points", "separations", "flags"), &Box3DGeometry::hull_2d, DEFVAL(PackedFloat32Array()), DEFVAL(0));
	ClassDB::bind_static_method(cls, D_METHOD("simplify_hull_2d", "points", "separations", "target"), &Box3DGeometry::simplify_hull_2d);

	// character planes
	ClassDB::bind_static_method(cls, D_METHOD("solve_planes", "target_delta", "planes"), &Box3DGeometry::solve_planes);
	ClassDB::bind_static_method(cls, D_METHOD("clip_vector", "vector", "planes"), &Box3DGeometry::clip_vector);

	// Constants
	ClassDB::bind_integer_constant(cls, "LogMode", "LOG_STDOUT", LOG_STDOUT);
	ClassDB::bind_integer_constant(cls, "LogMode", "LOG_GODOT_WARNING", LOG_GODOT_WARNING);
	ClassDB::bind_integer_constant(cls, "LogMode", "LOG_GODOT_PRINT", LOG_GODOT_PRINT);
	ClassDB::bind_integer_constant(cls, "LogMode", "LOG_SILENT", LOG_SILENT);

	ClassDB::bind_integer_constant(cls, "", "HULL2D_KEEP_COLLINEAR", b3_hull2DKeepCollinear);
	ClassDB::bind_integer_constant(cls, "", "HULL2D_EXACT_MERGE", b3_hull2DExactMerge);
	ClassDB::bind_integer_constant(cls, "", "HULL2D_INDEX_ORDER", b3_hull2DIndexOrder);

	ClassDB::bind_integer_constant(cls, "", "TOI_STATE_UNKNOWN", b3_toiStateUnknown);
	ClassDB::bind_integer_constant(cls, "", "TOI_STATE_FAILED", b3_toiStateFailed);
	ClassDB::bind_integer_constant(cls, "", "TOI_STATE_OVERLAPPED", b3_toiStateOverlapped);
	ClassDB::bind_integer_constant(cls, "", "TOI_STATE_HIT", b3_toiStateHit);
	ClassDB::bind_integer_constant(cls, "", "TOI_STATE_SEPARATED", b3_toiStateSeparated);

	ClassDB::bind_integer_constant(cls, "", "SAT_INVALID_AXIS", b3_invalidAxis);
	ClassDB::bind_integer_constant(cls, "", "SAT_BACKSIDE_AXIS", b3_backsideAxis);
	ClassDB::bind_integer_constant(cls, "", "SAT_FACE_AXIS_A", b3_faceAxisA);
	ClassDB::bind_integer_constant(cls, "", "SAT_FACE_AXIS_B", b3_faceAxisB);
	ClassDB::bind_integer_constant(cls, "", "SAT_EDGE_PAIR_AXIS", b3_edgePairAxis);
	ClassDB::bind_integer_constant(cls, "", "SAT_CLOSEST_POINTS_AXIS", b3_closestPointsAxis);

	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_NONE", b3_featureNone);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_TRIANGLE_FACE", b3_featureTriangleFace);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_HULL_FACE", b3_featureHullFace);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_EDGE1", b3_featureEdge1);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_EDGE2", b3_featureEdge2);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_EDGE3", b3_featureEdge3);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_VERTEX1", b3_featureVertex1);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_VERTEX2", b3_featureVertex2);
	ClassDB::bind_integer_constant(cls, "", "TRIANGLE_FEATURE_VERTEX3", b3_featureVertex3);

	ClassDB::bind_integer_constant(cls, "", "MESH_CONTACT_HULL_FACE", b3_meshContactHullFace);
	ClassDB::bind_integer_constant(cls, "", "MESH_CONTACT_SNAPPED", b3_meshContactSnapped);
	ClassDB::bind_integer_constant(cls, "", "MESH_CONTACT_DEEP", b3_meshContactDeep);

	ClassDB::bind_integer_constant(cls, "", "MESH_CONCAVE_EDGE1", b3_concaveEdge1);
	ClassDB::bind_integer_constant(cls, "", "MESH_CONCAVE_EDGE2", b3_concaveEdge2);
	ClassDB::bind_integer_constant(cls, "", "MESH_CONCAVE_EDGE3", b3_concaveEdge3);
	ClassDB::bind_integer_constant(cls, "", "MESH_INVERSE_CONCAVE_EDGE1", b3_inverseConcaveEdge1);
	ClassDB::bind_integer_constant(cls, "", "MESH_INVERSE_CONCAVE_EDGE2", b3_inverseConcaveEdge2);
	ClassDB::bind_integer_constant(cls, "", "MESH_INVERSE_CONCAVE_EDGE3", b3_inverseConcaveEdge3);
	ClassDB::bind_integer_constant(cls, "", "MESH_FLAT_VERTEX", b3_flatVertex);
	ClassDB::bind_integer_constant(cls, "", "MESH_CONCAVE_VERTEX", b3_concaveVertex);
	ClassDB::bind_integer_constant(cls, "", "MESH_BOUNDARY_EDGE_ANGLE", B3_BOUNDARY_EDGE_ANGLE);

	ClassDB::bind_integer_constant(cls, "", "HEIGHT_FIELD_HOLE", B3_HEIGHT_FIELD_HOLE);
	ClassDB::bind_integer_constant(cls, "", "HASH_INIT", B3_HASH_INIT);
	ClassDB::bind_integer_constant(cls, "", "MAX_HULL_VERTICES", B3_MAX_HULL_VERTICES);
	ClassDB::bind_integer_constant(cls, "", "MAX_SHAPE_CAST_POINTS", B3_MAX_SHAPE_CAST_POINTS);
}

// ===========================================================================
// Box3DDynamicTree
// ===========================================================================

namespace {

struct TreeQueryContext {
	Callable callback;
	bool has_callback = false;
	PackedInt32Array proxies;
};

bool tree_query_fcn(int p_proxy_id, uint64_t p_user_data, void *p_context) {
	TreeQueryContext *ctx = static_cast<TreeQueryContext *>(p_context);
	ctx->proxies.push_back(p_proxy_id);
	if (!ctx->has_callback) {
		return true;
	}
	Variant r = ctx->callback.call(p_proxy_id, u64_to_i64(p_user_data));
	return r.get_type() == Variant::NIL ? true : (bool)r;
}

struct TreeClosestContext {
	Callable callback;
	bool has_callback = false;
	const b3DynamicTree *tree = nullptr;
	b3Vec3 point = {};
	int best_proxy = -1;
	float best_distance_sqr = FLT_MAX;
};

float tree_closest_fcn(float p_distance_sqr_min, int p_proxy_id, uint64_t p_user_data, void *p_context) {
	TreeClosestContext *ctx = static_cast<TreeClosestContext *>(p_context);
	float d = FLT_MAX;
	if (ctx->has_callback) {
		Variant r = ctx->callback.call(p_distance_sqr_min, p_proxy_id, u64_to_i64(p_user_data));
		d = r.get_type() == Variant::NIL ? FLT_MAX : (float)(double)r;
	} else {
		// Default: squared distance from the point to the proxy AABB.
		b3AABB box = b3DynamicTree_GetAABB(ctx->tree, p_proxy_id);
		float dx = MAX(MAX(box.lowerBound.x - ctx->point.x, 0.0f), ctx->point.x - box.upperBound.x);
		float dy = MAX(MAX(box.lowerBound.y - ctx->point.y, 0.0f), ctx->point.y - box.upperBound.y);
		float dz = MAX(MAX(box.lowerBound.z - ctx->point.z, 0.0f), ctx->point.z - box.upperBound.z);
		d = dx * dx + dy * dy + dz * dz;
	}
	if (d < ctx->best_distance_sqr) {
		ctx->best_distance_sqr = d;
		ctx->best_proxy = p_proxy_id;
	}
	return d;
}

float tree_ray_cast_fcn(const b3RayCastInput *p_input, int p_proxy_id, uint64_t p_user_data, void *p_context) {
	TreeQueryContext *ctx = static_cast<TreeQueryContext *>(p_context);
	ctx->proxies.push_back(p_proxy_id);
	if (!ctx->has_callback) {
		return p_input->maxFraction;
	}
	Variant r = ctx->callback.call(p_proxy_id, u64_to_i64(p_user_data), to_gd(p_input->origin), to_gd(p_input->translation), p_input->maxFraction);
	return r.get_type() == Variant::NIL ? p_input->maxFraction : (float)(double)r;
}

float tree_box_cast_fcn(const b3BoxCastInput *p_input, int p_proxy_id, uint64_t p_user_data, void *p_context) {
	TreeQueryContext *ctx = static_cast<TreeQueryContext *>(p_context);
	ctx->proxies.push_back(p_proxy_id);
	if (!ctx->has_callback) {
		return p_input->maxFraction;
	}
	Variant r = ctx->callback.call(p_proxy_id, u64_to_i64(p_user_data), to_gd_aabb(p_input->box), to_gd(p_input->translation), p_input->maxFraction);
	return r.get_type() == Variant::NIL ? p_input->maxFraction : (float)(double)r;
}

Dictionary tree_result(const b3TreeStats &p_stats, const PackedInt32Array &p_proxies) {
	Dictionary d;
	d["proxies"] = p_proxies;
	d["node_visits"] = p_stats.nodeVisits;
	d["leaf_visits"] = p_stats.leafVisits;
	return d;
}

struct QueryGuard {
	bool &flag;
	explicit QueryGuard(bool &p_flag) :
			flag(p_flag) { flag = true; }
	~QueryGuard() { flag = false; }
};

} // namespace

Box3DDynamicTree::Box3DDynamicTree() {
	tree = b3DynamicTree_Create(16);
	valid = true;
}

Box3DDynamicTree::~Box3DDynamicTree() {
	if (valid) {
		b3DynamicTree_Destroy(&tree);
		valid = false;
	}
}

bool Box3DDynamicTree::check_proxy(int p_proxy_id) const {
	ERR_FAIL_COND_V_MSG(!valid, false, "Box3DDynamicTree: tree is not valid.");
	ERR_FAIL_COND_V_MSG(p_proxy_id < 0 || p_proxy_id >= tree.proxyCapacity || tree.proxies[p_proxy_id].node == B3_NULL_INDEX, false,
			"Box3DDynamicTree: invalid proxy id.");
	return true;
}

bool Box3DDynamicTree::check_mutable() const {
	ERR_FAIL_COND_V_MSG(!valid, false, "Box3DDynamicTree: tree is not valid.");
	ERR_FAIL_COND_V_MSG(in_query, false, "Box3DDynamicTree: the tree cannot be modified from inside a query callback.");
	return true;
}

bool Box3DDynamicTree::is_proxy_valid(int p_proxy_id) const {
	return valid && p_proxy_id >= 0 && p_proxy_id < tree.proxyCapacity && tree.proxies[p_proxy_id].node != B3_NULL_INDEX;
}

void Box3DDynamicTree::reset(int p_proxy_capacity) {
	ERR_FAIL_COND_MSG(in_query, "Box3DDynamicTree: cannot reset from inside a query callback.");
	if (valid) {
		b3DynamicTree_Destroy(&tree);
	}
	tree = b3DynamicTree_Create(MAX(1, p_proxy_capacity));
	valid = true;
}

int Box3DDynamicTree::create_proxy(const AABB &p_aabb, int64_t p_category_bits, int64_t p_user_data) {
	ERR_FAIL_COND_V(!check_mutable(), -1);
	b3AABB box = to_b3_aabb(p_aabb);
	ERR_FAIL_COND_V_MSG(!b3IsValidAABB(box), -1, "Box3DDynamicTree: invalid AABB.");
	return b3DynamicTree_CreateProxy(&tree, box, i64_to_u64(p_category_bits), i64_to_u64(p_user_data));
}

void Box3DDynamicTree::destroy_proxy(int p_proxy_id) {
	ERR_FAIL_COND(!check_mutable() || !check_proxy(p_proxy_id));
	b3DynamicTree_DestroyProxy(&tree, p_proxy_id);
}

void Box3DDynamicTree::move_proxy(int p_proxy_id, const AABB &p_aabb) {
	ERR_FAIL_COND(!check_mutable() || !check_proxy(p_proxy_id));
	b3AABB box = to_b3_aabb(p_aabb);
	ERR_FAIL_COND_MSG(!b3IsValidAABB(box), "Box3DDynamicTree: invalid AABB.");
	b3DynamicTree_MoveProxy(&tree, p_proxy_id, box);
}

void Box3DDynamicTree::enlarge_proxy(int p_proxy_id, const AABB &p_aabb) {
	ERR_FAIL_COND(!check_mutable() || !check_proxy(p_proxy_id));
	b3AABB box = to_b3_aabb(p_aabb);
	ERR_FAIL_COND_MSG(!b3IsValidAABB(box), "Box3DDynamicTree: invalid AABB.");
	b3DynamicTree_EnlargeProxy(&tree, p_proxy_id, box);
}

void Box3DDynamicTree::set_category_bits(int p_proxy_id, int64_t p_category_bits) {
	ERR_FAIL_COND(!check_mutable() || !check_proxy(p_proxy_id));
	b3DynamicTree_SetCategoryBits(&tree, p_proxy_id, i64_to_u64(p_category_bits));
}

int64_t Box3DDynamicTree::get_category_bits(int p_proxy_id) const {
	ERR_FAIL_COND_V(!check_proxy(p_proxy_id), 0);
	return u64_to_i64(b3DynamicTree_GetCategoryBits(const_cast<b3DynamicTree *>(&tree), p_proxy_id));
}

int64_t Box3DDynamicTree::get_user_data(int p_proxy_id) const {
	ERR_FAIL_COND_V(!check_proxy(p_proxy_id), 0);
	return u64_to_i64(b3DynamicTree_GetUserData(&tree, p_proxy_id));
}

AABB Box3DDynamicTree::get_proxy_aabb(int p_proxy_id) const {
	ERR_FAIL_COND_V(!check_proxy(p_proxy_id), AABB());
	return to_gd_aabb(b3DynamicTree_GetAABB(&tree, p_proxy_id));
}

Dictionary Box3DDynamicTree::query(const AABB &p_aabb, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback) {
	ERR_FAIL_COND_V(!check_mutable(), Dictionary());
	TreeQueryContext ctx;
	ctx.callback = p_callback;
	ctx.has_callback = p_callback.is_valid();
	QueryGuard guard(in_query);
	b3TreeStats stats = b3DynamicTree_Query(&tree, to_b3_aabb(p_aabb), i64_to_u64(p_mask_bits), p_require_all_bits, &tree_query_fcn, &ctx);
	return tree_result(stats, ctx.proxies);
}

Dictionary Box3DDynamicTree::query_closest(const Vector3 &p_point, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback, float p_min_distance_sqr) {
	ERR_FAIL_COND_V(!check_mutable(), Dictionary());
	TreeClosestContext ctx;
	ctx.callback = p_callback;
	ctx.has_callback = p_callback.is_valid();
	ctx.tree = &tree;
	ctx.point = to_b3(p_point);
	ctx.best_distance_sqr = p_min_distance_sqr;
	float min_distance_sqr = p_min_distance_sqr;
	QueryGuard guard(in_query);
	b3TreeStats stats = b3DynamicTree_QueryClosest(&tree, ctx.point, i64_to_u64(p_mask_bits), p_require_all_bits, &tree_closest_fcn, &ctx, &min_distance_sqr);
	Dictionary d;
	d["proxy_id"] = ctx.best_proxy;
	d["min_distance_sqr"] = min_distance_sqr;
	d["node_visits"] = stats.nodeVisits;
	d["leaf_visits"] = stats.leafVisits;
	return d;
}

Dictionary Box3DDynamicTree::ray_cast(const Vector3 &p_origin, const Vector3 &p_translation, float p_max_fraction, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback) {
	ERR_FAIL_COND_V(!check_mutable(), Dictionary());
	b3RayCastInput input;
	input.origin = to_b3(p_origin);
	input.translation = to_b3(p_translation);
	input.maxFraction = p_max_fraction;
	ERR_FAIL_COND_V_MSG(!b3IsValidRay(&input), Dictionary(), "Box3DDynamicTree: invalid ray.");
	TreeQueryContext ctx;
	ctx.callback = p_callback;
	ctx.has_callback = p_callback.is_valid();
	QueryGuard guard(in_query);
	b3TreeStats stats = b3DynamicTree_RayCast(&tree, &input, i64_to_u64(p_mask_bits), p_require_all_bits, &tree_ray_cast_fcn, &ctx);
	return tree_result(stats, ctx.proxies);
}

Dictionary Box3DDynamicTree::box_cast(const AABB &p_box, const Vector3 &p_translation, float p_max_fraction, int64_t p_mask_bits, bool p_require_all_bits, const Callable &p_callback) {
	ERR_FAIL_COND_V(!check_mutable(), Dictionary());
	b3BoxCastInput input;
	input.box = to_b3_aabb(p_box);
	input.translation = to_b3(p_translation);
	input.maxFraction = p_max_fraction;
	ERR_FAIL_COND_V_MSG(!b3IsValidAABB(input.box) || !b3IsValidVec3(input.translation) || !(p_max_fraction >= 0.0f), Dictionary(),
			"Box3DDynamicTree: invalid box cast input.");
	TreeQueryContext ctx;
	ctx.callback = p_callback;
	ctx.has_callback = p_callback.is_valid();
	QueryGuard guard(in_query);
	b3TreeStats stats = b3DynamicTree_BoxCast(&tree, &input, i64_to_u64(p_mask_bits), p_require_all_bits, &tree_box_cast_fcn, &ctx);
	return tree_result(stats, ctx.proxies);
}

int Box3DDynamicTree::get_height() const {
	ERR_FAIL_COND_V(!valid, 0);
	return b3DynamicTree_GetHeight(&tree);
}

float Box3DDynamicTree::get_area_ratio() const {
	ERR_FAIL_COND_V(!valid, 0.0f);
	return b3DynamicTree_GetAreaRatio(&tree);
}

AABB Box3DDynamicTree::get_root_bounds() const {
	ERR_FAIL_COND_V(!valid, AABB());
	return to_gd_aabb(b3DynamicTree_GetRootBounds(&tree));
}

int Box3DDynamicTree::get_proxy_count() const {
	ERR_FAIL_COND_V(!valid, 0);
	return b3DynamicTree_GetProxyCount(&tree);
}

int Box3DDynamicTree::rebuild(bool p_full_build) {
	ERR_FAIL_COND_V(!check_mutable(), 0);
	return b3DynamicTree_Rebuild(&tree, p_full_build);
}

int Box3DDynamicTree::get_byte_count() const {
	ERR_FAIL_COND_V(!valid, 0);
	return b3DynamicTree_GetByteCount(&tree);
}

void Box3DDynamicTree::validate() const {
	ERR_FAIL_COND(!valid);
	b3DynamicTree_Validate(&tree);
}

void Box3DDynamicTree::validate_no_moved() const {
	ERR_FAIL_COND(!valid);
	b3DynamicTree_ValidateNoMoved(&tree);
}

void Box3DDynamicTree::save(const String &p_path) const {
	ERR_FAIL_COND(!valid);
	CharString path = globalize(p_path).utf8();
	b3DynamicTree_Save(&tree, path.get_data());
}

bool Box3DDynamicTree::load(const String &p_path, float p_scale) {
	ERR_FAIL_COND_V(!check_mutable(), false);
	CharString path = globalize(p_path).utf8();
	b3DynamicTree loaded = b3DynamicTree_Load(path.get_data(), p_scale);
	ERR_FAIL_COND_V_MSG(loaded.nodes == nullptr || loaded.proxies == nullptr, false,
			"Box3DDynamicTree: b3DynamicTree_Load failed for '" + p_path + "'.");
	if (valid) {
		b3DynamicTree_Destroy(&tree);
	}
	tree = loaded;
	valid = true;
	return true;
}

void Box3DDynamicTree::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset", "proxy_capacity"), &Box3DDynamicTree::reset, DEFVAL(16));
	ClassDB::bind_method(D_METHOD("create_proxy", "aabb", "category_bits", "user_data"), &Box3DDynamicTree::create_proxy, DEFVAL(-1), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("destroy_proxy", "proxy_id"), &Box3DDynamicTree::destroy_proxy);
	ClassDB::bind_method(D_METHOD("move_proxy", "proxy_id", "aabb"), &Box3DDynamicTree::move_proxy);
	ClassDB::bind_method(D_METHOD("enlarge_proxy", "proxy_id", "aabb"), &Box3DDynamicTree::enlarge_proxy);
	ClassDB::bind_method(D_METHOD("set_category_bits", "proxy_id", "category_bits"), &Box3DDynamicTree::set_category_bits);
	ClassDB::bind_method(D_METHOD("get_category_bits", "proxy_id"), &Box3DDynamicTree::get_category_bits);
	ClassDB::bind_method(D_METHOD("get_user_data", "proxy_id"), &Box3DDynamicTree::get_user_data);
	ClassDB::bind_method(D_METHOD("get_proxy_aabb", "proxy_id"), &Box3DDynamicTree::get_proxy_aabb);
	ClassDB::bind_method(D_METHOD("is_proxy_valid", "proxy_id"), &Box3DDynamicTree::is_proxy_valid);
	ClassDB::bind_method(D_METHOD("query", "aabb", "mask_bits", "require_all_bits", "callback"), &Box3DDynamicTree::query, DEFVAL(-1), DEFVAL(false), DEFVAL(Callable()));
	ClassDB::bind_method(D_METHOD("query_closest", "point", "mask_bits", "require_all_bits", "callback", "min_distance_sqr"), &Box3DDynamicTree::query_closest, DEFVAL(-1), DEFVAL(false), DEFVAL(Callable()), DEFVAL(FLT_MAX));
	ClassDB::bind_method(D_METHOD("ray_cast", "origin", "translation", "max_fraction", "mask_bits", "require_all_bits", "callback"), &Box3DDynamicTree::ray_cast, DEFVAL(1.0f), DEFVAL(-1), DEFVAL(false), DEFVAL(Callable()));
	ClassDB::bind_method(D_METHOD("box_cast", "box", "translation", "max_fraction", "mask_bits", "require_all_bits", "callback"), &Box3DDynamicTree::box_cast, DEFVAL(1.0f), DEFVAL(-1), DEFVAL(false), DEFVAL(Callable()));
	ClassDB::bind_method(D_METHOD("get_height"), &Box3DDynamicTree::get_height);
	ClassDB::bind_method(D_METHOD("get_area_ratio"), &Box3DDynamicTree::get_area_ratio);
	ClassDB::bind_method(D_METHOD("get_root_bounds"), &Box3DDynamicTree::get_root_bounds);
	ClassDB::bind_method(D_METHOD("get_proxy_count"), &Box3DDynamicTree::get_proxy_count);
	ClassDB::bind_method(D_METHOD("rebuild", "full_build"), &Box3DDynamicTree::rebuild, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_byte_count"), &Box3DDynamicTree::get_byte_count);
	ClassDB::bind_method(D_METHOD("validate"), &Box3DDynamicTree::validate);
	ClassDB::bind_method(D_METHOD("validate_no_moved"), &Box3DDynamicTree::validate_no_moved);
	ClassDB::bind_method(D_METHOD("save", "path"), &Box3DDynamicTree::save);
	ClassDB::bind_method(D_METHOD("load", "path", "scale"), &Box3DDynamicTree::load, DEFVAL(1.0f));
}
