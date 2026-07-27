extends RefCounted

## Glass-shatter dressing: a one-shot burst of glinting sparkle quads plus a
## brief cool light pop at the break point. The survey's lesson is that the
## first-frame glitter (and audio, later) sells a shatter far more than
## shard accuracy -- so this is cheap, additive and aggressively capped like
## fracture_fx.gd: past MAX_ACTIVE concurrent bursts new ones are skipped.

const SparkTex = preload("res://lib/fx/textures/spark_04.png")

const MAX_ACTIVE := 24
const LIFETIME := 0.9

static var _active := 0
static var _glint_ramp_tex: GradientTexture1D


static func burst(parent: Node, at: Vector3, extent: float) -> void:
	if _active >= MAX_ACTIVE or parent == null or not parent.is_inside_tree():
		return
	_active += 1
	var root := Node3D.new()
	parent.add_child(root)
	root.global_position = at
	root.add_child(_glints(extent))
	var light := OmniLight3D.new()
	light.light_color = Color(0.8, 0.92, 1.0)
	light.light_energy = 1.6
	light.omni_range = extent * 3.0
	light.shadow_enabled = false
	root.add_child(light)
	var tween := root.create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.25)
	root.tree_exited.connect(_release)
	var timer := Timer.new()
	timer.wait_time = LIFETIME + 0.3
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(root.queue_free)
	root.add_child(timer)


static func _release() -> void:
	_active -= 1


static func _glints(extent: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(extent * 26.0), 14, 40)
	particles.lifetime = LIFETIME
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3.ONE * (-extent * 3.0),
			Vector3.ONE * (extent * 6.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = extent * 0.45
	pm.spread = 180.0
	pm.initial_velocity_min = extent * 1.2
	pm.initial_velocity_max = extent * 3.2
	pm.gravity = Vector3(0.0, -14.0, 0.0)
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.scale_min = 0.25
	pm.scale_max = 0.6
	pm.color_ramp = _glint_ramp()
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = SparkTex
	mat.emission_enabled = true
	mat.emission = Color(0.75, 0.9, 1.0)
	mat.emission_energy_multiplier = 3.2
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


static func _glint_ramp() -> GradientTexture1D:
	if _glint_ramp_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.15, 0.7, 1.0])
		g.colors = PackedColorArray([
			Color(1.0, 1.0, 1.0, 0.0), Color(0.9, 0.97, 1.0, 1.0),
			Color(0.7, 0.85, 1.0, 0.5), Color(0.5, 0.7, 0.95, 0.0)])
		_glint_ramp_tex = GradientTexture1D.new()
		_glint_ramp_tex.gradient = g
	return _glint_ramp_tex
