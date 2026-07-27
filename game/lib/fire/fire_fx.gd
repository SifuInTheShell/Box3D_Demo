extends Node3D

## A lingering fire left behind by an explosion: additive flame billboards,
## ember sparks, a continuous smoke column, a flickering orange light and a
## scorch mark on the ground. Burns for `burn_time` seconds, then dies down
## and frees itself (the scorch fades last). Concurrent fires are capped so
## a carpet-bombed city cannot drown the GPU.
##
##   FireFX.ignite(world, blast_pos, blast_radius)

const _Self = preload("res://lib/fire/fire_fx.gd")
const DustShader = preload("res://lib/fx/dust_puff.gdshader")
const FlipbookTex = preload("res://lib/fx/textures/fire_flipbook.png")
const HeatHazeShader = preload("res://lib/fire/heat_haze.gdshader")
const SparkTex = preload("res://lib/fx/textures/spark_04.png")
const SmokeTex = preload("res://lib/fx/textures/smoke_07.png")
const PuffTex = preload("res://lib/fx/textures/smoke_04.png")

# The CC0 Unity "Flame02" flipbook is a 16x4 grid (64 frames).
const FLAME_HFRAMES := 16
const FLAME_VFRAMES := 4
# Wind push: how hard the horizontal wind drags the flame cloud, smoke and
# embers. Lighter things blow further downwind (smoke > embers > flame).
const DRIFT_FLAME := 1.1
const DRIFT_SMOKE := 1.3
const DRIFT_EMBER := 1.1

const MAX_ACTIVE := 28

static var _active := 0

var radius := 1.0
var burn_time := 14.0

var _t := 0.0
var _light: OmniLight3D
var _flames: GPUParticles3D
var _wind: Node   # cached wind_system, or null on calm sites
var _smoke: GPUParticles3D
var _embers: GPUParticles3D
var _scorch: MeshInstance3D
var _haze: MeshInstance3D
var _fs_min := 0.0   # base flame scale, before the flare-up ramp
var _fs_max := 0.0
var _dying := false


## Spawn fires across the blast's damage zone: the biggest at the epicentre,
## satellites seeded from bodies the pressure wave actually engulfed -- fire
## burns on what got hit, not on random empty ground. Count and size scale
## with the blast, and each fire flares up with a short stagger so flames
## emerge as the fireball fades instead of fighting the flash. Silently
## skips when the concurrent cap is reached.
static func ignite(world: Box3DWorld, at: Vector3, blast_radius: float) -> void:
	if world == null or not world.is_inside_tree():
		return
	var rng := RandomNumberGenerator.new()
	# Seeded from the blast site: identical demolition runs relight the same
	# fires (determinism action item, docs/box3d-techniques.md).
	rng.seed = hash([roundi(at.x * 8.0), roundi(at.y * 8.0),
			roundi(at.z * 8.0), roundi(blast_radius * 8.0)])
	var count := clampi(1 + int(blast_radius / 2.5), 1, 8)
	var spots: Array[Vector3] = [at]
	var candidates: Array[Vector3] = []
	for body in world.overlap_sphere(at, blast_radius * 0.75):
		if body == null or not is_instance_valid(body) or body.is_in_group("projectile"):
			continue
		var p: Vector3 = body.global_position
		# Big slabs overlap the sphere with a centre well outside the blast;
		# a fire there would burn on an untouched part of the building.
		if Vector2(p.x - at.x, p.z - at.z).length() > blast_radius * 0.8:
			continue
		candidates.append(p)
	# Seeded Fisher-Yates: the global-RNG shuffle() broke run determinism
	# (fire spots feed glass thermal heat -> physics).
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Vector3 = candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp
	# Keep chosen fires apart so they spread across the rubble field
	# instead of clumping into one mega-pyre at the epicentre.
	var min_gap := maxf(blast_radius * 0.3, 1.6)
	for cand in candidates:
		if spots.size() >= count:
			break
		var clear := true
		for s in spots:
			if Vector2(cand.x - s.x, cand.z - s.z).length() < min_gap:
				clear = false
				break
		if clear:
			spots.append(cand)
	# Not enough debris around (air burst, platform edge): fall back to a
	# loose ring inside the blast radius.
	while spots.size() < count:
		var ang := rng.randf() * TAU
		spots.append(at + Vector3(cos(ang), 0.0, sin(ang))
				* blast_radius * rng.randf_range(0.25, 0.55))
	for i in spots.size():
		var spot: Vector3 = spots[i]
		var size_scale := 1.0 if i == 0 else rng.randf_range(0.55, 0.8)
		var fire_radius := clampf(blast_radius * 0.22, 1.0, 2.8) \
				* size_scale * rng.randf_range(0.85, 1.2)
		var fire_burn := rng.randf_range(9.0, 17.0)
		# Wait for the blast debris to LAND before probing for a surface: a
		# short delay drops fires onto still-airborne chunks, and the fire then
		# hangs in the air when the chunk falls away.
		var delay := 1.4 + rng.randf() * 1.4
		world.get_tree().create_timer(delay).timeout.connect(func() -> void:
			if not is_instance_valid(world) or not world.is_inside_tree():
				return
			if _active >= MAX_ACTIVE:
				return
			# Land on a RESTING surface, skipping still-airborne debris and
			# small fragments, so the fire never perches on a chunk that
			# then falls away and leaves it hanging in the air.
			var at_pos: Vector3 = _ground_under(world, spot)
			var fire := _Self.new()
			fire.radius = fire_radius
			fire.burn_time = fire_burn
			world.add_child(fire)
			fire.global_position = at_pos + Vector3(0, 0.05, 0))


## Pyres are GROUND fires: probe downward for a resting surface, skipping any
## blast debris still moving through the ray (and small fragments), so a fire
## never lands on an airborne chunk and hangs when the chunk falls away. Falls
## back to the flat ground plane if nothing solid is below.
static func _ground_under(world: Box3DWorld, p: Vector3) -> Vector3:
	var to := p + Vector3(0, -40.0, 0)
	var from := p + Vector3(0, 3.0, 0)
	for _i in 5:
		var hit: Dictionary = world.raycast(from, to)
		if not hit.get("hit", false):
			return Vector3(p.x, 0.0, p.z)
		var body: Node = hit.get("collider")
		var skip: bool = body != null and (body.is_in_group("fragment")
				or (body.has_method("get_linear_velocity")
					and (body.get_linear_velocity() as Vector3).length() > 1.5))
		if not skip:
			return hit["position"]
		from = (hit["position"] as Vector3) + Vector3(0, -0.2, 0)
	return Vector3(p.x, 0.0, p.z)


## Shared flame material: the CC0 Unity "Flame02" flipbook on a camera-facing
## billboard. Alpha-blended (not additive) so flames stay bold against a bright
## sky and never show a flat card edge; HDR emission so the glow blooms the
## core; proximity_fade softens where a flame meets a wall or the ground
## (Godot's built-in soft particles). Shared with burn_fx.gd.
static func flame_flipbook_material(energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.albedo_texture = FlipbookTex
	mat.emission_enabled = true
	mat.emission_texture = FlipbookTex
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = energy
	mat.particles_anim_h_frames = FLAME_HFRAMES
	mat.particles_anim_v_frames = FLAME_VFRAMES
	mat.particles_anim_loop = false
	mat.proximity_fade_enabled = true
	mat.proximity_fade_distance = 0.4
	return mat


## Wire flipbook animation into a flame ParticleProcessMaterial: each particle
## plays the 64-frame sheet once over its life, from a random start frame so
## neighbouring flames never animate in unison.
static func flame_anim(pm: ParticleProcessMaterial) -> void:
	pm.anim_speed_min = 1.0
	pm.anim_speed_max = 1.0
	pm.anim_offset_min = 0.0
	pm.anim_offset_max = 1.0


func _enter_tree() -> void:
	_active += 1


func _exit_tree() -> void:
	_active -= 1


func _ready() -> void:
	# Pyres are heat sources for the propagation sim (fire_system.gd polls
	# this group): the fires an explosion leaves can light nearby timber.
	add_to_group("ground_fire")
	# The readable fire: flipbook flame billboards over the ember/smoke bed.
	_flames = _make_flames()
	add_child(_flames)
	_smoke = _make_smoke()
	add_child(_smoke)
	_embers = _make_embers()
	add_child(_embers)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.6, 0.25)
	_light.omni_range = radius * 5.5
	_light.shadow_enabled = false
	_light.position = Vector3(0, radius * 0.7, 0)
	add_child(_light)

	_scorch = MeshInstance3D.new()
	var quad := PlaneMesh.new()
	quad.size = Vector2(radius * 3.2, radius * 3.2)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = PuffTex
	mat.albedo_color = Color(0.05, 0.04, 0.035, 0.8)
	quad.material = mat
	_scorch.mesh = quad
	_scorch.position = Vector3(0, 0.02, 0)
	_scorch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_scorch)

	# Air shimmer above the pyre — screen-space refraction. Only the capped
	# pyres carry one; per-body burning (up to 64) never does, so the screen
	# reads stay bounded.
	_haze = MeshInstance3D.new()
	var hquad := QuadMesh.new()
	hquad.size = Vector2(radius * 3.4, radius * 3.6)
	_haze.mesh = hquad
	var hmat := ShaderMaterial.new()
	hmat.shader = HeatHazeShader
	hmat.set_shader_parameter("strength", 0.022)
	_haze.material_override = hmat
	_haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_haze.position = Vector3(0, radius * 1.3, 0)
	add_child(_haze)


## Radiant output for the fire system while alive (zero once dying down).
func heat_output() -> Dictionary:
	return {
		"pos": global_position,
		"radius": radius * 2.6,
		"output": 0.0 if _dying else 2600.0 * radius,
	}


func _process(delta: float) -> void:
	_t += delta
	var life := 1.0 - clampf((_t - burn_time) / 2.0, 0.0, 1.0)
	# Two-sine flicker reads as firelight without any RNG per frame.
	_light.light_energy = maxf(0.0,
			(4.2 + sin(_t * 11.0) * 1.2 + sin(_t * 23.7) * 0.8) * life)
	# Flare up over the first ~0.9 s: flames grow from small to full, so a new
	# pyre looks like it catches instead of popping into existence.
	var grow := clampf(_t / 0.9, 0.0, 1.0)
	var vis := clampf(life, 0.0, 1.0) * grow
	_flames.amount_ratio = maxf(vis, 0.05)
	var fpm := _flames.process_material as ParticleProcessMaterial
	var sf := 0.4 + 0.6 * grow
	fpm.scale_min = _fs_min * sf
	fpm.scale_max = _fs_max * sf
	_haze.set_instance_shader_parameter("intensity", vis)
	_lean_with_wind()
	if _t >= burn_time and not _dying:
		_dying = true
		_flames.emitting = false
		_smoke.emitting = false
		_embers.emitting = false
	if _t >= burn_time + 3.5:
		queue_free()


## Blow the flame cloud, smoke column and embers downwind — the same weather the
## fire sim spreads by and the windsock reads. Cosmetic and RNG-free; wind is a
## pure function of the tick, so the lean replays identically.
func _lean_with_wind() -> void:
	if _wind == null or not is_instance_valid(_wind):
		_wind = get_tree().get_first_node_in_group("wind_system")
		if _wind == null:
			return
	var wh: Vector3 = _wind.current()
	wh = Vector3(wh.x, 0.0, wh.z)
	var fpm := _flames.process_material as ParticleProcessMaterial
	fpm.gravity = Vector3(0, 1.5, 0) + wh * DRIFT_FLAME
	fpm.turbulence_noise_strength = 0.4 + wh.length() * 0.14   # whip in gusts
	(_smoke.process_material as ParticleProcessMaterial).gravity = \
			Vector3(0, 1.8, 0) + wh * DRIFT_SMOKE
	(_embers.process_material as ParticleProcessMaterial).gravity = \
			Vector3(0, -3.0, 0) + wh * DRIFT_EMBER


func _make_flames() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(radius * 16.0), 14, 34)
	particles.lifetime = 1.0
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-radius * 3, -1, -radius * 3),
			Vector3(radius * 6, radius * 9, radius * 6))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(radius * 0.75, 0.05, radius * 0.75)
	pm.direction = Vector3.UP
	pm.spread = 6.0
	pm.initial_velocity_min = radius * 0.5
	pm.initial_velocity_max = radius * 1.1
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = radius * 1.1
	pm.scale_max = radius * 1.9
	_fs_min = radius * 1.1
	_fs_max = radius * 1.9
	pm.angle_min = -10.0
	pm.angle_max = 10.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.4
	pm.turbulence_noise_scale = 1.3
	flame_anim(pm)
	particles.process_material = pm

	# A tall quad rooted at its BASE (center_offset lifts it), so each flame
	# grows up from the fuel instead of floating centred on the particle.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 1.2)
	quad.center_offset = Vector3(0, 0.6, 0)
	quad.material = flame_flipbook_material(2.2)
	particles.draw_pass_1 = quad
	return particles


func _make_smoke() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(radius * 10.0), 8, 24)
	particles.lifetime = 3.4
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-radius * 4, -1, -radius * 4),
			Vector3(radius * 8, radius * 18, radius * 8))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.45
	pm.direction = Vector3.UP
	pm.spread = 10.0
	pm.initial_velocity_min = radius * 1.2
	pm.initial_velocity_max = radius * 2.4
	pm.gravity = Vector3(0, 1.8, 0)
	pm.angular_velocity_min = -60.0
	pm.angular_velocity_max = 60.0
	pm.scale_min = radius * 0.6
	pm.scale_max = radius * 1.1
	pm.scale_curve = _grow_curve()
	pm.color_ramp = _smoke_ramp()
	particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = DustShader
	mat.set_shader_parameter("puff_tex", SmokeTex)
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


func _make_embers() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(radius * 7.0), 6, 16)
	particles.lifetime = 1.5
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-radius * 3, -1, -radius * 3),
			Vector3(radius * 6, radius * 10, radius * 6))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.45
	pm.direction = Vector3.UP
	pm.spread = 35.0
	pm.initial_velocity_min = radius * 1.6
	pm.initial_velocity_max = radius * 3.6
	pm.gravity = Vector3(0, -2.5, 0)
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.scale_min = 0.5
	pm.scale_max = 1.1
	pm.scale_curve = _fade_curve()
	pm.color_ramp = _flame_ramp()
	particles.process_material = pm

	# Soft round sparks (billboard), not velocity-stretched slivers -- the old
	# thin FACE_Z quads read as hard straight lines, worst of all streaked out
	# by the wind. A small spark sprite reads as embers from any angle.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = SparkTex
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.2)
	mat.emission_energy_multiplier = 5.0
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles


static var _flame_ramp_tex: GradientTexture1D
static var _smoke_ramp_tex: GradientTexture1D
static var _fade_tex: CurveTexture
static var _grow_tex: CurveTexture


static func _flame_ramp() -> GradientTexture1D:
	if _flame_ramp_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
		g.colors = PackedColorArray([
			Color(1.0, 0.95, 0.7, 0.0), Color(1.0, 0.75, 0.3, 1.0),
			Color(1.0, 0.35, 0.1, 0.8), Color(0.6, 0.1, 0.03, 0.0)])
		_flame_ramp_tex = GradientTexture1D.new()
		_flame_ramp_tex.gradient = g
	return _flame_ramp_tex


static func _smoke_ramp() -> GradientTexture1D:
	if _smoke_ramp_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.2, 0.6, 1.0])
		g.colors = PackedColorArray([
			Color(0.25, 0.22, 0.2, 0.0), Color(0.22, 0.2, 0.19, 0.55),
			Color(0.18, 0.17, 0.17, 0.4), Color(0.15, 0.15, 0.15, 0.0)])
		_smoke_ramp_tex = GradientTexture1D.new()
		_smoke_ramp_tex.gradient = g
	return _smoke_ramp_tex


static func _fade_curve() -> CurveTexture:
	if _fade_tex == null:
		var c := Curve.new()
		c.add_point(Vector2(0.0, 0.9))
		c.add_point(Vector2(1.0, 0.25))
		_fade_tex = CurveTexture.new()
		_fade_tex.curve = c
	return _fade_tex


static func _grow_curve() -> CurveTexture:
	if _grow_tex == null:
		var c := Curve.new()
		c.add_point(Vector2(0.0, 0.5))
		c.add_point(Vector2(1.0, 1.6))
		_grow_tex = CurveTexture.new()
		_grow_tex.curve = c
	return _grow_tex
