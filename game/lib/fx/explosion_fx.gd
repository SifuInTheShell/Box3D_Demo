extends Node3D

## Explosion effect, the cinematic version. One `blast()` gives you:
##   - a blinding billboard flash at detonation
##   - a noise-boiling fireball shell (fx/fireball.gdshader, blooms via glow)
##   - a ground shockwave ring racing outward (fx/shockwave.gdshader)
##   - a heat-haze sphere refracting the scene behind it (fx/heat_haze.gdshader)
##   - velocity-stretched spark streaks, a rising smoke column and a ground
##     dust wave (GPU particles, all procedural textures)
##   - an omni light flash, camera shake, and delayed secondary bursts on
##     big detonations
## The node drives every shader's `progress` from _process and frees itself
## when the smoke thins out. Nothing survives between blasts.
##
##   ExplosionFX.burst(world, position)                       # just the visual
##   ExplosionFX.blast(world, position, radius, impulse)      # visual + Box3D push

const _Self = preload("res://lib/fx/explosion_fx.gd")
const FireballShader = preload("res://lib/fx/fireball.gdshader")
const ShockwaveShader = preload("res://lib/fx/shockwave.gdshader")
const HeatHazeShader = preload("res://lib/fx/heat_haze.gdshader")
const DustShader = preload("res://lib/fx/dust_puff.gdshader")
const FireFX = preload("res://lib/fire/fire_fx.gd")
const SmokeTex = preload("res://lib/fx/textures/smoke_04.png")
const DirtTex = preload("res://lib/fx/textures/dirt_01.png")
const FlareTex = preload("res://lib/fx/textures/flare_01.png")
const SparkTex = preload("res://lib/fx/textures/spark_04.png")

const FLASH_TIME := 0.18
const FIRE_TIME := 0.85
const RING_TIME := 0.7
const HAZE_TIME := 0.55
const LIGHT_TIME := 0.45
const TOTAL_TIME := 3.2  # smoke needs the tail

@export var visual_radius := 3.0
@export var color := Color(1.0, 0.55, 0.15)

static var _puff_tex: GradientTexture2D
static var _spark_ramp: GradientTexture1D
static var _smoke_ramp: GradientTexture1D
static var _dust_ramp: GradientTexture1D
static var _smoke_scale: CurveTexture
static var _active_fx := 0  # live FX nodes; caps secondary-burst fan-out

var _elapsed := 0.0
var _ring_grounded := false
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D
var _fire: MeshInstance3D
var _fire_mat: ShaderMaterial
var _ring: MeshInstance3D
var _ring_mat: ShaderMaterial
var _haze: MeshInstance3D
var _haze_mat: ShaderMaterial
var _light: OmniLight3D


## Spawn just the visual at a world position.
static func burst(parent: Node, at: Vector3, radius := 3.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	var fx := _Self.new()
	fx.visual_radius = radius
	fx.color = tint
	parent.add_child(fx)
	fx.global_position = at


## Physics blast (Box3DWorld.explode) plus the full visual, camera shake and,
## for big detonations, a cluster of delayed secondary bursts.
static func blast(world: Box3DWorld, at: Vector3, blast_radius := 8.0,
		impulse := 8.0, tint := Color(1.0, 0.55, 0.15)) -> void:
	if world == null:
		return
	world.explode(at, blast_radius, impulse, 1.0)
	# The pressure wave shatters what's inside it, force scaled by distance:
	# without this, blasts merely disassemble buildings into their intact
	# rectangular panels and nothing visibly fractures.
	for body in world.overlap_sphere(at, blast_radius * 0.8):
		if body == null or not is_instance_valid(body):
			continue
		var falloff := clampf(
				1.0 - body.global_position.distance_to(at) / (blast_radius * 0.85), 0.0, 1.0)
		if body.has_method("blast_fracture"):
			body.blast_fracture(at, 8.0 + impulse * 2.6 * falloff)
		elif body.is_in_group("projectile"):
			# Dense little spheres barely feel explode()'s per-area impulse
			# (small cross-section, big mass), so blasts looked like they
			# ignored the player's cannonballs. Kick them by velocity instead.
			var away: Vector3 = body.global_position - at
			var dir: Vector3 = away / maxf(away.length(), 0.3)
			dir.y += 0.35  # blasts loft things
			body.apply_central_impulse(
					dir.normalized() * body.get_mass() * (5.0 + impulse * 2.0 * falloff))
	burst(world, at, blast_radius * 0.7, tint)
	# Explosives leave fire: lingering flame/smoke/scorch patches at the site.
	FireFX.ignite(world, at, blast_radius)
	# And pour real heat into the propagation sim: timber near the blast
	# catches (fire_system.gd; no-op in gyms without one).
	world.get_tree().call_group("fire_system", "blast_heat", at, blast_radius, impulse)
	# Overpressure rings out much further than the fracture radius: windows
	# break across the neighbourhood (glass_system.gd -- the collateral tell).
	world.get_tree().call_group("glass_system", "blast_wave", at, blast_radius, impulse)
	world.get_tree().call_group("camera_shake", "shake_from", at, blast_radius * 0.16)
	# The neighbourhood notices: birds scatter, the ambience bed cuts to a
	# ringing quiet (ambient_life.gd -- cosmetic only, no-op without one).
	world.get_tree().call_group("ambient_life", "disturb", at, blast_radius, impulse)
	# Wake any ragdolls in reach -- they go limp and get flung with the debris.
	world.get_tree().call_group("ragdoll_ctrl", "blast", at, blast_radius, impulse)
	if blast_radius >= 6.0 and _active_fx < 40:
		# Deliberate cosmetic exception to the seeded-RNG rule: these are
		# secondary VISUAL bursts only (burst() spawns FX, no physics), so
		# unseeded variety here can never touch the sim or the hash.
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for i in 3:
			var delay := 0.1 + 0.12 * i + rng.randf() * 0.06
			var off := Vector3(
				rng.randf_range(-1.0, 1.0), rng.randf_range(0.1, 0.7),
				rng.randf_range(-1.0, 1.0)) * (blast_radius * 0.45)
			world.get_tree().create_timer(delay).timeout.connect(func() -> void:
				if is_instance_valid(world) and world.is_inside_tree():
					burst(world, at + off, blast_radius * 0.32, tint))


func _enter_tree() -> void:
	_active_fx += 1


func _exit_tree() -> void:
	_active_fx -= 1


func _ready() -> void:
	var r := visual_radius

	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash_mat.albedo_texture = FlareTex
	_flash_mat.albedo_color = Color(1.0, 0.92, 0.72)
	_flash_mat.emission_enabled = true
	_flash_mat.emission = Color(1.0, 0.92, 0.72)
	_flash_mat.emission_energy_multiplier = 10.0
	_flash = MeshInstance3D.new()
	var flash_quad := QuadMesh.new()
	flash_quad.size = Vector2(2.0, 2.0)
	flash_quad.material = _flash_mat
	_flash.mesh = flash_quad
	_flash.scale = Vector3.ONE * (r * 1.6)
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flash)

	_fire_mat = ShaderMaterial.new()
	_fire_mat.shader = FireballShader
	_fire_mat.set_shader_parameter("mid_color", color)
	_fire_mat.set_shader_parameter("emission_strength", 7.0)
	_fire = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	_fire.mesh = sphere
	_fire.material_override = _fire_mat
	_fire.scale = Vector3.ONE * (r * 0.25)
	_fire.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_fire)

	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = ShockwaveShader
	_ring_mat.render_priority = 1
	_ring = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0, 2.0)
	_ring.mesh = plane
	_ring.material_override = _ring_mat
	_ring.scale = Vector3.ONE * (r * 3.2)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)

	_haze_mat = ShaderMaterial.new()
	_haze_mat.shader = HeatHazeShader
	_haze_mat.render_priority = -1  # refract the scene before fire draws on top
	_haze_mat.set_shader_parameter("strength", 0.06)
	_haze = MeshInstance3D.new()
	_haze.mesh = sphere
	_haze.material_override = _haze_mat
	_haze.scale = Vector3.ONE * (r * 0.4)
	_haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_haze)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.72, 0.4)
	_light.light_energy = 22.0
	_light.omni_range = r * 4.5
	_light.shadow_enabled = false
	add_child(_light)

	add_child(_make_sparks(r))
	add_child(_make_smoke(r))
	add_child(_make_dust(r))


func _process(delta: float) -> void:
	_elapsed += delta
	var t := _elapsed

	if _flash != null:
		if t < FLASH_TIME:
			var p := t / FLASH_TIME
			var a := (1.0 - p) * (1.0 - p)
			_flash_mat.albedo_color.a = a
			_flash_mat.emission_energy_multiplier = 10.0 * a
			_flash.scale = Vector3.ONE * (visual_radius * (1.6 + 1.2 * p))
		else:
			_flash.queue_free()
			_flash = null

	if _fire != null:
		if t < FIRE_TIME:
			var p := t / FIRE_TIME
			_fire_mat.set_shader_parameter("progress", p)
			_fire.scale = Vector3.ONE * (visual_radius * (0.3 + 0.9 * ease(p, 0.35)))
		else:
			_fire.queue_free()
			_fire = null

	if _ring != null:
		if not _ring_grounded:
			# The FX node gets its global position after _ready; drop the ring
			# to just above the ground on the first live frame.
			_ring_grounded = true
			var gp := _ring.global_position
			_ring.global_position = Vector3(gp.x, 0.3, gp.z)
		if t < RING_TIME:
			_ring_mat.set_shader_parameter("progress", t / RING_TIME)
		else:
			_ring.queue_free()
			_ring = null

	if _haze != null:
		if t < HAZE_TIME:
			var p := t / HAZE_TIME
			_haze_mat.set_shader_parameter("progress", p)
			_haze.scale = Vector3.ONE * (visual_radius * (0.4 + 3.0 * ease(p, 0.3)))
		else:
			_haze.queue_free()
			_haze = null

	if _light != null:
		if t < LIGHT_TIME:
			var k := 1.0 - t / LIGHT_TIME
			_light.light_energy = 22.0 * k * k
		else:
			_light.queue_free()
			_light = null

	if t >= TOTAL_TIME:
		queue_free()


func _make_sparks(r: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(r * 40.0), 48, 260)
	particles.lifetime = 1.1
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = true
	particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	particles.visibility_aabb = AABB(Vector3.ONE * (-r * 4.0), Vector3.ONE * (r * 8.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = r * 0.15
	pm.spread = 180.0
	pm.initial_velocity_min = r * 2.6
	pm.initial_velocity_max = r * 8.0
	pm.gravity = Vector3(0.0, -16.0, 0.0)
	pm.damping_min = 1.0
	pm.damping_max = 4.0
	pm.scale_min = 0.7
	pm.scale_max = 1.6
	pm.color_ramp = _get_spark_ramp()
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.08, 0.9)
	quad.orientation = PlaneMesh.FACE_Z
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.2)
	mat.emission_energy_multiplier = 6.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = SparkTex
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


func _make_smoke(r: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(r * 16.0), 24, 140)
	particles.lifetime = 2.7
	particles.one_shot = true
	particles.explosiveness = 0.85
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3.ONE * (-r * 4.0), Vector3.ONE * (r * 8.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = r * 0.35
	pm.spread = 180.0
	pm.initial_velocity_min = r * 0.9
	pm.initial_velocity_max = r * 2.4
	pm.gravity = Vector3(0.0, 1.8, 0.0)  # buoyant: smoke rises
	pm.damping_min = 0.8
	pm.damping_max = 2.0
	pm.angular_velocity_min = -90.0
	pm.angular_velocity_max = 90.0
	pm.scale_min = r * 0.55
	pm.scale_max = r * 1.05
	pm.scale_curve = _get_smoke_scale()
	pm.color_ramp = _get_smoke_ramp()
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = DustShader  # noise-torn puffs instead of smooth blobs
	mat.set_shader_parameter("puff_tex", SmokeTex)
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


## Ground dust wave: heavy brown puffs accelerating radially outward, hugging
## the floor. Sells the pressure wave even when the fireball is inside a wall.
func _make_dust(r: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(r * 14.0), 24, 110)
	particles.lifetime = 1.9
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3.ONE * (-r * 5.0), Vector3.ONE * (r * 10.0))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0.0, 1.0, 0.0)
	pm.emission_ring_radius = r * 0.55
	pm.emission_ring_inner_radius = r * 0.3
	pm.emission_ring_height = 0.3
	pm.spread = 25.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 2.0
	pm.radial_accel_min = r * 4.0
	pm.radial_accel_max = r * 8.0
	pm.gravity = Vector3(0.0, -0.6, 0.0)
	pm.damping_min = 3.0
	pm.damping_max = 6.0
	pm.scale_min = r * 0.3
	pm.scale_max = r * 0.55
	pm.scale_curve = _get_smoke_scale()
	pm.color_ramp = _get_dust_ramp()
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = DustShader
	mat.set_shader_parameter("puff_tex", DirtTex)
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


static func _get_puff_tex() -> GradientTexture2D:
	if _puff_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
		g.colors = PackedColorArray([
			Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
		_puff_tex = GradientTexture2D.new()
		_puff_tex.gradient = g
		_puff_tex.fill = GradientTexture2D.FILL_RADIAL
		_puff_tex.fill_from = Vector2(0.5, 0.5)
		_puff_tex.fill_to = Vector2(0.5, 0.0)
		_puff_tex.width = 128
		_puff_tex.height = 128
	return _puff_tex


static func _get_spark_ramp() -> GradientTexture1D:
	if _spark_ramp == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.3, 0.75, 1.0])
		g.colors = PackedColorArray([
			Color(1.0, 1.0, 0.9, 1.0), Color(1.0, 0.8, 0.35, 1.0),
			Color(1.0, 0.35, 0.08, 0.9), Color(0.5, 0.08, 0.02, 0.0)])
		_spark_ramp = GradientTexture1D.new()
		_spark_ramp.gradient = g
	return _spark_ramp


static func _get_smoke_ramp() -> GradientTexture1D:
	if _smoke_ramp == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.12, 0.55, 1.0])
		g.colors = PackedColorArray([
			Color(1.0, 0.62, 0.3, 0.0), Color(0.5, 0.4, 0.33, 0.78),
			Color(0.3, 0.29, 0.28, 0.62), Color(0.22, 0.22, 0.22, 0.0)])
		_smoke_ramp = GradientTexture1D.new()
		_smoke_ramp.gradient = g
	return _smoke_ramp


static func _get_dust_ramp() -> GradientTexture1D:
	if _dust_ramp == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.15, 0.6, 1.0])
		g.colors = PackedColorArray([
			Color(0.75, 0.62, 0.45, 0.0), Color(0.62, 0.52, 0.4, 0.6),
			Color(0.5, 0.44, 0.36, 0.4), Color(0.4, 0.36, 0.3, 0.0)])
		_dust_ramp = GradientTexture1D.new()
		_dust_ramp.gradient = g
	return _dust_ramp


static func _get_smoke_scale() -> CurveTexture:
	if _smoke_scale == null:
		var c := Curve.new()
		c.add_point(Vector2(0.0, 0.35))
		c.add_point(Vector2(0.3, 1.0))
		c.add_point(Vector2(1.0, 1.8))
		_smoke_scale = CurveTexture.new()
		_smoke_scale.curve = c
	return _smoke_scale
