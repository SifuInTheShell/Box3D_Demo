extends Node3D

## Pooled water-entry splash VFX (docs/water-research.md §3): a splash is a
## composite of crown strands, ballistic droplets, a mist puff, an expanding
## foam ring and -- for big slams -- a lingering foam patch, tiered by entry
## speed. Everything is drawn from fixed pools cycled with restart(): no
## nodes are spawned per splash, no process_material is ever swapped (each
## slot owns its material and only its numeric params are retuned). Bursts
## landing in the same ~4 m cell in the same frame are coalesced into one
## bigger splash -- essential when a demolition rains debris.
##
##   var splash := WaterSplash.attach(zone)
##   splash.splash(at, v_down, body_radius)

const _Self = preload("res://lib/water/water_splash.gd")
const RingShader = preload("res://lib/fx/foam_ring.gdshader")
const DropTex = preload("res://lib/fx/textures/flare_01.png")
const MistTex = preload("res://lib/fx/textures/smoke_04.png")

const POOL := 8          # slots per element type
const RING_POOL := 14
const DROP_AMOUNT := 96  # fixed per-slot particle budget; amount_ratio scales it
const CROWN_AMOUNT := 20
const MIST_AMOUNT := 12
const CELL := 4.0        # coalescing grid, metres

var _drops: Array = []   # [{node, pm}]
var _crowns: Array = []
var _mists: Array = []
var _rings: Array = []   # [{node, age, life, active}]
var _drop_i := 0
var _crown_i := 0
var _mist_i := 0
var _pending := {}       # cell key -> {at, v, r}
static var _ring_mat: ShaderMaterial
static var _drop_mat: StandardMaterial3D
static var _mist_mat: StandardMaterial3D


## `origin`/`span` give the water rectangle (world XZ min corner + size) so the
## foam-ring shader can clip splashes to the surface; omit them (span 0) to
## leave the ring unmasked.
static func attach(parent: Node3D, origin := Vector2.ZERO,
		span := Vector2.ZERO) -> Node3D:
	var s := _Self.new()
	parent.add_child(s)  # _ready builds the shared _ring_mat
	if span.x > 0.0 and span.y > 0.0 and _ring_mat != null:
		_ring_mat.set_shader_parameter("water_origin", origin)
		_ring_mat.set_shader_parameter("water_span", span)
	return s


## Queue a splash; same-frame neighbors merge into the strongest one.
func splash(at: Vector3, v_down: float, radius: float) -> void:
	var key := Vector2i(int(at.x / CELL), int(at.z / CELL))
	if _pending.has(key):
		var p: Dictionary = _pending[key]
		p.v = maxf(p.v, v_down) + 0.3  # merged hits read slightly bigger
		p.r = maxf(p.r, radius)
	else:
		_pending[key] = {"at": at, "v": v_down, "r": radius}


func _ready() -> void:
	for i in POOL:
		_drops.append(_make_droplets())
		_crowns.append(_make_crown())
		_mists.append(_make_mist())
	for i in RING_POOL:
		_rings.append(_make_ring())


func _process(delta: float) -> void:
	for r in _rings:
		if not r.active:
			continue
		r.age += delta
		var k: float = r.age / r.life
		if k >= 1.0:
			r.active = false
			r.node.visible = false
			continue
		r.node.set_instance_shader_parameter("progress", k)
	if _pending.is_empty():
		return
	for key in _pending:
		_fire(_pending[key])
	_pending.clear()


func _fire(ev: Dictionary) -> void:
	var v: float = ev.v
	var r: float = maxf(ev.r, 0.15)
	var at: Vector3 = ev.at
	# Foam ring: every tier gets one.
	_ring(at, r * (2.0 + 0.15 * v), 1.7 + r * 0.3, clampf(v * 0.25, 0.5, 1.0), false)
	# Droplets: every tier, count scaled by momentum.
	var slot: Dictionary = _drops[_drop_i]
	_drop_i = (_drop_i + 1) % POOL
	slot.pm.initial_velocity_min = v * 0.3
	slot.pm.initial_velocity_max = v * 0.7
	slot.pm.emission_sphere_radius = r * 0.6
	slot.pm.spread = 30.0 if v < 9.0 else 45.0
	slot.node.amount_ratio = clampf(20.0 * v * r / float(DROP_AMOUNT), 0.12, 1.0)
	slot.node.global_position = at
	slot.node.restart()
	if v < 3.0:
		return  # a plop
	# Crown: ring of rising strands that break into fall.
	slot = _crowns[_crown_i]
	_crown_i = (_crown_i + 1) % POOL
	slot.pm.emission_ring_radius = r * 1.5
	slot.pm.emission_ring_inner_radius = r * 1.2
	slot.pm.initial_velocity_min = clampf(v * 0.45, 1.5, 9.0)
	slot.pm.initial_velocity_max = clampf(v * 0.65, 2.0, 12.0)
	slot.node.amount_ratio = clampf(v / 12.0, 0.4, 1.0)
	slot.node.global_position = at
	slot.node.restart()
	# Mist puff.
	slot = _mists[_mist_i]
	_mist_i = (_mist_i + 1) % POOL
	slot.pm.scale_min = 0.5 + r * 0.4
	slot.pm.scale_max = 1.4 + r * 0.8
	slot.node.global_position = at + Vector3(0, 0.3, 0)
	slot.node.restart()
	if v >= 9.0:
		# Slam: lingering foam patch that erodes over seconds.
		_ring(at, r * 3.0, 5.5, 0.9, true)


func _ring(at: Vector3, final_radius: float, life: float, strength: float,
		patch: bool) -> void:
	var best: Dictionary = {}
	for r in _rings:
		if not r.active:
			best = r
			break
	if best.is_empty():
		return  # all busy: in that chaos one missing ring is invisible
	best.active = true
	best.age = 0.0
	best.life = life
	var mi: MeshInstance3D = best.node
	mi.visible = true
	mi.global_position = at + Vector3(0, 0.04, 0)
	mi.scale = Vector3.ONE * (final_radius * 2.0)
	mi.set_instance_shader_parameter("progress", 0.0)
	mi.set_instance_shader_parameter("strength", strength)
	mi.set_instance_shader_parameter("patch_mode", 1.0 if patch else 0.0)


func _make_droplets() -> Dictionary:
	var particles := GPUParticles3D.new()
	particles.amount = DROP_AMOUNT
	particles.lifetime = 0.9
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = false
	particles.visibility_aabb = AABB(Vector3(-8, -2, -8), Vector3(16, 12, 16))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.4
	pm.direction = Vector3.UP
	pm.spread = 30.0
	pm.gravity = Vector3(0, -12.0, 0)
	pm.damping_min = 0.5
	pm.damping_max = 1.5
	pm.scale_min = 0.4
	pm.scale_max = 1.0
	pm.scale_curve = _shrink_curve()
	pm.color_ramp = _fade_ramp(Color(0.88, 0.95, 1.0, 0.9),
			Color(0.55, 0.7, 0.8, 0.0))
	particles.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)
	if _drop_mat == null:
		_drop_mat = StandardMaterial3D.new()
		_drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_drop_mat.albedo_texture = DropTex
		_drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_drop_mat.vertex_color_use_as_albedo = true
	quad.material = _drop_mat
	particles.draw_pass_1 = quad
	add_child(particles)
	return {"node": particles, "pm": pm}


func _make_crown() -> Dictionary:
	var particles := GPUParticles3D.new()
	particles.amount = CROWN_AMOUNT
	particles.lifetime = 0.7
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = false
	particles.visibility_aabb = AABB(Vector3(-6, -1, -6), Vector3(12, 10, 12))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_height = 0.05
	pm.emission_ring_radius = 0.8
	pm.emission_ring_inner_radius = 0.6
	pm.direction = Vector3.UP
	pm.spread = 9.0
	pm.gravity = Vector3(0, -14.0, 0)
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	pm.color_ramp = _fade_ramp(Color(0.9, 0.96, 1.0, 0.85),
			Color(0.7, 0.85, 0.92, 0.0))
	particles.process_material = pm
	# Vertically stretched strands aligned to velocity: the rising sheet.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.55)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = DropTex
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	quad.material = mat
	particles.draw_pass_1 = quad
	pm.particle_flag_align_y = true
	add_child(particles)
	return {"node": particles, "pm": pm}


func _make_mist() -> Dictionary:
	var particles := GPUParticles3D.new()
	particles.amount = MIST_AMOUNT
	particles.lifetime = 1.3
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = false
	particles.visibility_aabb = AABB(Vector3(-6, -1, -6), Vector3(12, 8, 12))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5
	pm.direction = Vector3.UP
	pm.spread = 70.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 2.6
	pm.gravity = Vector3(0, -0.5, 0)
	pm.damping_min = 2.0
	pm.damping_max = 4.0
	pm.scale_min = 0.8
	pm.scale_max = 2.0
	pm.scale_curve = _grow_curve()
	pm.color_ramp = _fade_ramp(Color(0.9, 0.94, 0.97, 0.22),
			Color(0.85, 0.9, 0.94, 0.0))
	particles.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	if _mist_mat == null:
		_mist_mat = StandardMaterial3D.new()
		_mist_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mist_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mist_mat.albedo_texture = MistTex
		_mist_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_mist_mat.vertex_color_use_as_albedo = true
	quad.material = _mist_mat
	particles.draw_pass_1 = quad
	add_child(particles)
	return {"node": particles, "pm": pm}


func _make_ring() -> Dictionary:
	var mi := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(1.0, 1.0)  # scaled per use
	mi.mesh = mesh
	if _ring_mat == null:
		_ring_mat = ShaderMaterial.new()
		_ring_mat.shader = RingShader
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.frequency = 0.045
		n.seed = 5
		var tex := NoiseTexture2D.new()
		tex.noise = n
		tex.seamless = true
		tex.width = 128
		tex.height = 128
		_ring_mat.set_shader_parameter("noise_tex", tex)
	mi.material_override = _ring_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return {"node": mi, "age": 0.0, "life": 2.0, "active": false}


static func _shrink_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.3))
	var t := CurveTexture.new()
	t.curve = c
	return t


static func _grow_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.35))
	c.add_point(Vector2(1.0, 1.0))
	var t := CurveTexture.new()
	t.curve = c
	return t


static func _fade_ramp(from: Color, to: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.12, 1.0])
	g.colors = PackedColorArray([Color(from.r, from.g, from.b, 0.0), from, to])
	var tex := GradientTexture1D.new()
	tex.gradient = g
	return tex
