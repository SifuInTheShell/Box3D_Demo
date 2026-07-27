extends RefCounted

## Scenery dressing that makes the gyms read as places instead of demos:
## asphalt roads, animated water, desert sand, and a REAL 3D tree model
## (Poly Haven photoscan, CC0) on a Box3D body with compound collision --
## it topples, launches and splinters like everything else (glb_tree.gd).

const Drum := preload("res://lib/bodies/drum.gd")
const GlbTree := preload("res://lib/bodies/glb_tree.gd")
const AsphaltTex = preload("res://lib/fx/textures/facades/asphalt.jpg")
const WaterShader = preload("res://lib/fx/water.gdshader")


## Game-ready realistic tree: a Poly Haven photoscan DECIMATED in Blender to a
## few-thousand-tri budget (workflow in docs/research/asset-pipeline.md §3), keeping its
## photoscanned materials (keep_materials). [scene, canopy tint (debris only),
## height range]. The RAW Poly Haven trees are unusable direct -- pine_tree_01
## alone is a 905 MB mesh -- so they MUST be decimated first.
const REALISTIC_TREES := [
	[preload("res://lib/fx/models/trees/quiver_tree.glb"),
			Color(0.34, 0.46, 0.28), Vector2(3.8, 5.5)],
]


static func _realistic_trees() -> Array:
	return REALISTIC_TREES

static var _road_mat: StandardMaterial3D
static var _water_shader_mat: ShaderMaterial
static var _sand_mat: StandardMaterial3D


## A flat asphalt strip; `size.x` runs along X when `along_x`, else along Z.
static func road(parent: Node3D, center: Vector3, size: Vector2,
		along_x := true) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, 0.06, size.y) if along_x \
			else Vector3(size.y, 0.06, size.x)
	mi.mesh = mesh
	if _road_mat == null:
		_road_mat = StandardMaterial3D.new()
		_road_mat.albedo_texture = AsphaltTex
		_road_mat.albedo_color = Color(0.85, 0.85, 0.85)
		_road_mat.uv1_triplanar = true
		_road_mat.uv1_scale = Vector3(0.12, 0.12, 0.12)
		_road_mat.roughness = 0.95
	mi.material_override = _road_mat
	mi.position = center + Vector3(0, 0.03, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## A real 3D tree on a compound Box3D body, randomly sized and turned.
## Prefers the realistic Poly Haven models when fetched (photoscanned
## materials kept as-is); falls back to the tinted Kenney low-poly set.
## Fully destructible either way (see glb_tree.gd).
static func tree(parent: Node3D, at: Vector3, rng: RandomNumberGenerator) -> void:
	var pool: Array = _realistic_trees()
	var pick: Array = pool[rng.randi() % pool.size()]
	var t := GlbTree.new()
	t.model_scene = pick[0]
	t.canopy_color = pick[1]
	t.keep_materials = true
	var hr: Vector2 = pick[2]
	t.target_height = rng.randf_range(hr.x, hr.y)
	t.position = at + Vector3(0, t.target_height * 0.5 + 0.02, 0)
	t.rotation.y = rng.randf() * TAU
	parent.add_child(t)


## An animated water strip: subdivided plane + depth-aware wave shader
## (sum-of-sines displacement, Beer-Lambert depth tint, refraction, shore
## foam -- see fx/water.gdshader and docs/water-research.md).
static func water(parent: Node3D, center: Vector3, size: Vector2) -> void:
	var mi := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = size
	# ~0.5 m grid so the sine displacement has vertices to move.
	mesh.subdivide_width = mini(int(size.x * 2.0), 400)
	mesh.subdivide_depth = mini(int(size.y * 2.0), 400)
	mi.mesh = mesh
	if _water_shader_mat == null:
		_water_shader_mat = ShaderMaterial.new()
		_water_shader_mat.shader = WaterShader
		_water_shader_mat.set_shader_parameter("normal_tex", _water_normal_tex())
		_water_shader_mat.set_shader_parameter("foam_tex", _water_foam_tex())
	mi.material_override = _water_shader_mat
	# Displacement happens on the GPU; pad the cull box by the wave height.
	mi.custom_aabb = AABB(Vector3(-size.x * 0.5, -0.5, -size.y * 0.5),
			Vector3(size.x, 1.0, size.y))
	mi.position = center + Vector3(0, 0.05, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## The shared water material -- WaterFX hands it to the ripple sim so the
## heightfield can bind its output texture. Null until water() first runs.
static func water_material() -> ShaderMaterial:
	return _water_shader_mat


static var _water_normal: NoiseTexture2D
static var _water_foam: NoiseTexture2D


## Tileable water-detail normal map, generated -- no asset needed.
static func _water_normal_tex() -> NoiseTexture2D:
	if _water_normal == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_octaves = 4
		n.frequency = 0.012
		n.seed = 7
		_water_normal = NoiseTexture2D.new()
		_water_normal.noise = n
		_water_normal.seamless = true
		_water_normal.as_normal_map = true
		_water_normal.bump_strength = 6.0
		_water_normal.width = 256
		_water_normal.height = 256
	return _water_normal


## Tileable luma noise that gates the shore-foam band.
static func _water_foam_tex() -> NoiseTexture2D:
	if _water_foam == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.fractal_octaves = 3
		n.frequency = 0.03
		n.seed = 11
		_water_foam = NoiseTexture2D.new()
		_water_foam.noise = n
		_water_foam.seamless = true
		_water_foam.width = 256
		_water_foam.height = 256
	return _water_foam


## A desert sand apron under the pyramid.
static func sand(parent: Node3D, center: Vector3, radius: float) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.05
	mesh.radial_segments = 26
	mi.mesh = mesh
	if _sand_mat == null:
		_sand_mat = StandardMaterial3D.new()
		_sand_mat.albedo_color = Color(0.87, 0.78, 0.58)
		_sand_mat.roughness = 1.0
	mi.material_override = _sand_mat
	mi.position = center + Vector3(0, 0.045, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
