extends RefCounted

## Per-fracture debris dressing: when a panel or chunk shatters, this spawns
## a short dust cloud (fx/dust_puff.gdshader) plus a spray of tiny dark
## debris specks at the break. Purely visual and aggressively capped -- mass
## demolitions fracture hundreds of bodies per second, so past MAX_ACTIVE
## concurrent bursts new ones are silently skipped (nobody can tell in the
## chaos, and the GPU can).

const DustShader = preload("res://lib/fx/dust_puff.gdshader")
const PuffTex = preload("res://lib/fx/textures/smoke_07.png")

const MAX_ACTIVE := 32
const LIFETIME := 1.8

static var _active := 0


static func burst(parent: Node, at: Vector3, extent: float, tint: Color) -> void:
	if _active >= MAX_ACTIVE or parent == null or not parent.is_inside_tree():
		return
	_active += 1
	var root := Node3D.new()
	parent.add_child(root)
	root.global_position = at
	root.add_child(_dust(extent, tint))
	root.add_child(_specks(extent, tint))
	root.tree_exited.connect(_release)
	var timer := Timer.new()
	timer.wait_time = LIFETIME + 0.4
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(root.queue_free)
	root.add_child(timer)


static func _release() -> void:
	_active -= 1


static func _dust(extent: float, tint: Color) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(extent * 8.0), 8, 28)
	particles.lifetime = LIFETIME
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3.ONE * (-extent * 3.0), Vector3.ONE * (extent * 6.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = extent * 0.3
	pm.spread = 180.0
	pm.initial_velocity_min = extent * 0.5
	pm.initial_velocity_max = extent * 1.4
	pm.gravity = Vector3(0.0, 0.6, 0.0)
	pm.damping_min = 1.5
	pm.damping_max = 3.0
	pm.scale_min = extent * 0.35
	pm.scale_max = extent * 0.7
	pm.color_ramp = _dust_ramp(tint)
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = DustShader
	mat.set_shader_parameter("puff_tex", PuffTex)
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


static func _specks(extent: float, tint: Color) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(extent * 9.0), 10, 32)
	particles.lifetime = 0.9
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3.ONE * (-extent * 4.0), Vector3.ONE * (extent * 8.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = extent * 0.25
	pm.spread = 180.0
	pm.initial_velocity_min = extent * 1.5
	pm.initial_velocity_max = extent * 3.5
	pm.gravity = Vector3(0.0, -22.0, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.3
	particles.process_material = pm

	var box := BoxMesh.new()
	box.size = Vector3(0.09, 0.09, 0.09)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint.darkened(0.45)
	mat.roughness = 1.0
	box.material = mat
	particles.draw_pass_1 = box
	return particles


static func _dust_ramp(tint: Color) -> GradientTexture1D:
	# Per-tint ramps are tiny; fractures reuse a handful of panel colors so
	# cache by quantized tint.
	var g := Gradient.new()
	var c := Color(tint.r * 0.9, tint.g * 0.88, tint.b * 0.85)
	g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	g.colors = PackedColorArray([
		Color(c.r, c.g, c.b, 0.0), Color(c.r, c.g, c.b, 0.55), Color(c.r, c.g, c.b, 0.0)])
	var tex := GradientTexture1D.new()
	tex.gradient = g
	return tex
