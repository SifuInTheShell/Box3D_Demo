extends RefCounted

## Shared visual builders for gym bodies. Meshes and materials are cached in
## static dictionaries (sizes and colors quantized), so thousands of debris
## bodies share a handful of GPU resources instead of one material each.
##
## Facade texturing uses fx/facade.gdshader: triplanar in object space plus a
## per-instance spawn anchor. Standing panels line up into one continuous
## world-space texture (seamless buildings); moving pieces keep the texture
## glued to their surface (no world-triplanar "rolling"). Materials stay
## shared because the anchor is a per-instance shader parameter.

const FacadeShader = preload("res://lib/fx/facade.gdshader")

## Per-texture triplanar density override (default uv_scale is 0.35, one
## repeat per ~2.9 m -- right for masonry, too sparse for sheet metal).
const TEX_UV_SCALE := {
	"corrugated.jpg": 0.9,
	"metal.jpg": 0.7,
}

static var _box_meshes := {}
static var _sphere_meshes := {}
static var _materials := {}


static func box(body: Node3D, size: Vector3, color: Color, shadows := true,
		tex: Texture2D = null) -> void:
	_attach(body, _box_mesh(size), color, shadows, tex)


## Attach an arbitrary mesh (e.g. a fracture shard) with a cached material.
static func custom(body: Node3D, mesh: Mesh, color: Color, shadows := true,
		tex: Texture2D = null) -> void:
	_attach(body, mesh, color, shadows, tex)


static func sphere(body: Node3D, radius: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _sphere_mesh(radius)
	mi.material_override = _plain_material(color, 0.4, 0.6)
	body.add_child(mi)


## Swap an already-attached visual's material (charring, scorching). Cached
## materials make repeated re-tints cheap; the mesh stays shared.
static func recolor(body: Node3D, color: Color, tex: Texture2D = null) -> void:
	for child in body.get_children():
		if child is MeshInstance3D:
			if tex != null:
				child.material_override = _facade_material(color, tex)
			else:
				child.material_override = _plain_material(color, 0.9, 0.0)
			return


static func _attach(body: Node3D, mesh: Mesh, color: Color, shadows: bool,
		tex: Texture2D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if tex != null:
		mi.material_override = _facade_material(color, tex)
	else:
		mi.material_override = _plain_material(color, 0.9, 0.0)
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	if tex != null:
		# Anchor = spawn position: standing panels sample world-continuous
		# texture; once the body moves, sampling stays glued to the object.
		mi.set_instance_shader_parameter("anchor", body.global_position)


static func _box_mesh(size: Vector3) -> BoxMesh:
	var key := size.snapped(Vector3(0.005, 0.005, 0.005))
	if not _box_meshes.has(key):
		var mesh := BoxMesh.new()
		mesh.size = size
		_box_meshes[key] = mesh
	return _box_meshes[key]


static func _sphere_mesh(radius: float) -> SphereMesh:
	var key := snappedf(radius, 0.005)
	if not _sphere_meshes.has(key):
		var mesh := SphereMesh.new()
		mesh.radius = radius
		mesh.height = radius * 2.0
		_sphere_meshes[key] = mesh
	return _sphere_meshes[key]


static func _plain_material(color: Color, rough: float, metal: float) -> StandardMaterial3D:
	var q := Color(snappedf(color.r, 0.02), snappedf(color.g, 0.02), snappedf(color.b, 0.02))
	var key := "%s|%.1f|%.1f" % [q.to_html(false), rough, metal]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = q
		mat.roughness = rough
		mat.metallic = metal
		_materials[key] = mat
	return _materials[key]


static func _facade_material(color: Color, tex: Texture2D) -> ShaderMaterial:
	var q := Color(snappedf(color.r, 0.02), snappedf(color.g, 0.02), snappedf(color.b, 0.02))
	var key := "%s|%s" % [q.to_html(false), tex.resource_path]
	if not _materials.has(key):
		var mat := ShaderMaterial.new()
		mat.shader = FacadeShader
		mat.set_shader_parameter("albedo_tex", tex)
		mat.set_shader_parameter("tint", q)
		var file := tex.resource_path.get_file()
		if TEX_UV_SCALE.has(file):
			mat.set_shader_parameter("uv_scale", TEX_UV_SCALE[file])
		_materials[key] = mat
	return _materials[key]
