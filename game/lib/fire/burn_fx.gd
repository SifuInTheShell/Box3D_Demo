extends Node3D

## Per-body burning visual: flame billboards, a smoke wisp and a flickering
## glow riding a burning body (attached as a child, so it moves and falls
## with it). Much lighter than fire_fx.gd's ground pyres -- dozens of these
## can burn at once -- and still hard-capped: past MAX_ACTIVE the simulation
## keeps burning bodies invisibly and the fire system re-tries the attach
## when a slot frees up (Teardown's budget lesson).
##
##   var fx := BurnFX.attach(body, half_extent)   # null when the cap is hit
##   fx.set_intensity(sim_intensity)              # 0..1 flame size
##   fx.smolder()                                 # coals: no flames, thin smoke
##   fx.die()                                     # stop emitting, free after tail

const _Self = preload("res://lib/fire/burn_fx.gd")
const FireFX = preload("res://lib/fire/fire_fx.gd")
const DustShader = preload("res://lib/fx/dust_puff.gdshader")
const SmokeTex = preload("res://lib/fx/textures/smoke_07.png")

const MAX_ACTIVE := 64

static var _active := 0


## Live flame billboards (for HUD readout vs the sim's burning count).
static func active_count() -> int:
	return _active

var body_half := Vector3.ONE * 0.4

var _flames: GPUParticles3D
var _smoke: GPUParticles3D
var _light: OmniLight3D
var _wind: Node   # cached wind_system, or null on calm sites
var _t := 0.0
var _k := 0.7             # last sim intensity, restored on rekindle
var _fs_min := 0.0        # base flame scale, before the intensity ramp
var _fs_max := 0.0
var _dying := false
var _smoldering := false


static func attach(body: Node3D, half: Vector3) -> Node3D:
	if _active >= MAX_ACTIVE:
		return null
	var fx := _Self.new()
	fx.body_half = half
	body.add_child(fx)
	# Flames sit on the body's upper surface, not at its centre.
	fx.position = Vector3(0.0, half.y * 0.5, 0.0)
	return fx


func _enter_tree() -> void:
	_active += 1


func _exit_tree() -> void:
	_active -= 1


func _ready() -> void:
	var r := clampf(maxf(body_half.x, body_half.z), 0.15, 1.6)
	# The readable fire: flipbook flame billboards, sized to the fuel.
	_flames = _make_flames(r)
	add_child(_flames)
	_smoke = _make_smoke(r)
	add_child(_smoke)
	set_intensity(_k)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.22)
	_light.omni_range = r * 5.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, r * 0.6, 0)
	add_child(_light)



func _process(delta: float) -> void:
	_t += delta
	var base := 0.35 if _smoldering else 2.2
	_light.light_energy = maxf(0.0,
			(base + sin(_t * 12.3) * 0.5 + sin(_t * 27.1) * 0.3)
			* (0.0 if _dying else 1.0))
	_lean_with_wind()
	if _dying and _t > 2.2:
		queue_free()


## Smoke and flame billboards stream downwind — the same weather the fire sim
## spreads by and the windsock reads. Cosmetic and RNG-free; wind is a pure
## function of the tick, so the lean replays identically.
func _lean_with_wind() -> void:
	if _wind == null or not is_instance_valid(_wind):
		_wind = get_tree().get_first_node_in_group("wind_system")
		if _wind == null:
			return
	var wh: Vector3 = _wind.current()
	wh = Vector3(wh.x, 0.0, wh.z)
	var fpm := _flames.process_material as ParticleProcessMaterial
	fpm.gravity = Vector3(0, 1.3, 0) + wh * FireFX.DRIFT_FLAME
	fpm.turbulence_noise_strength = 0.3 + wh.length() * 0.13   # whip in gusts
	(_smoke.process_material as ParticleProcessMaterial).gravity = \
			Vector3(0, 1.5, 0) + wh * FireFX.DRIFT_SMOKE


## Scale the flame budget with the sim's 0..1 intensity.
func set_intensity(k: float) -> void:
	if _dying:
		return
	_k = clampf(k, 0.0, 1.0)
	if _flames != null:
		# Flames grow with the sim's ramping intensity, so a freshly-lit body
		# starts small and builds up as it catches (fire looks like it ignites).
		_flames.amount_ratio = clampf(0.2 + k * 0.8, 0.2, 1.0)
		var fpm := _flames.process_material as ParticleProcessMaterial
		var sf := 0.35 + 0.65 * _k
		fpm.scale_min = _fs_min * sf
		fpm.scale_max = _fs_max * sf
		_smoke.amount_ratio = clampf(0.4 + k * 0.6, 0.4, 1.0)


## Coals: flames stop, a thin smoke thread keeps marking the hazard (the sim
## may rekindle -- flame() undoes this).
func smolder() -> void:
	_smoldering = true
	_flames.emitting = false
	_smoke.amount_ratio = 0.3


func flame() -> void:
	_smoldering = false
	_flames.emitting = true
	set_intensity(_k)


func die() -> void:
	if _dying:
		return
	_dying = true
	_t = 0.0
	_flames.emitting = false
	_smoke.emitting = false


func _make_flames(r: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	# Dense enough to read as one continuous fire (not a few floating cards).
	particles.amount = clampi(int(r * 18.0), 10, 26)
	particles.lifetime = 0.9
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-r * 2.5, -1, -r * 2.5),
			Vector3(r * 5, r * 7 + 2, r * 5))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(body_half.x * 0.7, 0.05, body_half.z * 0.7)
	pm.direction = Vector3.UP
	pm.spread = 5.0
	pm.initial_velocity_min = r * 0.4
	pm.initial_velocity_max = r * 1.0
	pm.gravity = Vector3(0, 1.3, 0)
	pm.scale_min = r * 1.1
	pm.scale_max = r * 1.9
	_fs_min = r * 1.1
	_fs_max = r * 1.9
	pm.angle_min = -10.0
	pm.angle_max = 10.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.3
	pm.turbulence_noise_scale = 1.4
	FireFX.flame_anim(pm)
	particles.process_material = pm
	# A tall quad rooted at its BASE (center_offset lifts it), so each flame
	# grows up from the fuel instead of floating centred on the particle.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 1.1)
	quad.center_offset = Vector3(0, 0.55, 0)
	quad.material = FireFX.flame_flipbook_material(2.2)
	particles.draw_pass_1 = quad
	return particles


func _make_smoke(r: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = clampi(int(r * 6.0), 4, 12)
	particles.lifetime = 2.6
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-r * 3, -1, -r * 3),
			Vector3(r * 6, r * 12 + 3, r * 6))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(body_half.x * 0.6, 0.05, body_half.z * 0.6)
	pm.direction = Vector3.UP
	pm.spread = 8.0
	pm.initial_velocity_min = r * 1.0
	pm.initial_velocity_max = r * 1.8
	pm.gravity = Vector3(0, 1.5, 0)
	pm.angular_velocity_min = -40.0
	pm.angular_velocity_max = 40.0
	pm.scale_min = r * 0.5
	pm.scale_max = r * 0.85
	pm.scale_curve = FireFX._grow_curve()
	pm.color_ramp = FireFX._smoke_ramp()
	particles.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = DustShader
	mat.set_shader_parameter("puff_tex", SmokeTex)
	quad.material = mat
	particles.draw_pass_1 = quad
	return particles
