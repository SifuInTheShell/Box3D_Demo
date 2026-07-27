extends Node3D

## Destruction gym: prototype proving Box3D physics + destruction. This scene
## is the tower variant (a round tower of ~100 breakable blocks); city_gym.gd
## extends this script and swaps the structure for a block of buildings.
##
##   LMB        shoot a cannonball at the cursor
##   RMB        explosion at whatever the cursor points at
##   B          cannonball barrage from random directions
##   N          big blast at the screen centre (stress test)
##   C          clear rubble fragments
##   MMB drag   orbit    wheel   zoom
##   R          reset    1 / 2   tower gym / city gym

const BoxVis := preload("res://lib/fx/box_visuals.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")
const ExplosionFX := preload("res://lib/fx/explosion_fx.gd")
const DemoCharge := preload("res://lib/bodies/demo_charge.gd")
const FireSystem := preload("res://lib/fire/fire_system.gd")
const GlassSystem := preload("res://lib/glass/glass_system.gd")
const BurnFX := preload("res://lib/fire/burn_fx.gd")
const WindSystem := preload("res://lib/wind/wind_system.gd")
const Windsock := preload("res://lib/wind/windsock.gd")

# Demolition charges: sizes selectable with 1/2/3 while in placement mode.
const CHARGE_SPECS := [
	{"label": "small", "radius": 3.5, "impulse": 5.0, "scale": 0.8},
	{"label": "medium", "radius": 6.5, "impulse": 7.0, "scale": 1.15},
	{"label": "large", "radius": 10.0, "impulse": 9.0, "scale": 1.6},
]

const TOWER_RINGS := 8
const BLOCKS_PER_RING := 12
const TOWER_RADIUS := 2.6
const BLOCK_SIZE := Vector3(1.25, 0.62, 0.6)  # tangential x height x radial
const BALL_SPEED := 32.0
const BALL_RADIUS := 0.4
const BLAST_RADIUS := 4.5
const BLAST_IMPULSE := 6.0
const NUKE_RADIUS := 13.0
const NUKE_IMPULSE := 9.0
const BARRAGE_COUNT := 8
# Wind is on by DEFAULT in every gym so the cross-system chemistry (fire/smoke/
# ember lean, flames agreeing with the windsock, light "wind_blown" props
# tipping) is always live. A moderate gusty breeze; scenes retune via the group.
const DEFAULT_WIND := Vector3(4.0, 0.0, 0.0)
const DEFAULT_GUST := 0.4

var _world: Box3DWorld
var _fire: Node3D   # fire propagation bridge (fire_system.gd)
var _glass: Node3D  # glass breakage bridge (glass_system.gd)
var _wind: Node     # global wind — on by default (fire lean, drift, prop tipping)
var _camera: Camera3D
var _pivot: Node3D
var _stats: Label
var _yaw := 0.0
var _pitch := -0.25
var _distance := 22.0  # legacy; unused by the free-fly camera
var _orbiting := false
var _fly_speed := 14.0  # free-fly metres/sec (wheel adjusts, Shift x3)
var _mouse_captured := false
var _crosshair: Label
var _rng := RandomNumberGenerator.new()
var _stats_cooldown := 0.0
var _trauma := 0.0  # camera shake energy, fed by nearby explosions
# Cinematic slow motion for big detonations: real-clock end time, -1 = off.
var _slowmo_until_ms := -1
# Demolition charge placement.
var _charge_mode := false
var _charge_size := 1
var _charge_label: Label
var _ghost: Node3D
var _placed: Array = []


func _ready() -> void:
	# A reload can arrive mid-slow-mo; never inherit a stuck time scale.
	Engine.time_scale = 1.0
	# When a demolition tick overruns the frame budget, run at most 2 catch-up
	# physics steps instead of the default 8: the sim briefly slows down
	# instead of spiralling into 200+ ms frames.
	Engine.max_physics_steps_per_frame = 2
	add_to_group("camera_shake")
	_rng.seed = 0xB0C5
	_build_environment()
	_build_world()
	_build_structures()
	_build_camera()
	_build_hud()


## Overridden by derived gyms (city_gym.gd) to build something else.
func _build_structures() -> void:
	_build_tower()


## Hook for derived gyms to claim extra keys (city gym: re-press 3 resizes).
func _extra_key(_code: int) -> void:
	pass


## Physical first (layout-independent), logical as fallback (also catches
## synthetic events injected by the MCP input service).
func _key_down(code: Key) -> bool:
	return Input.is_physical_key_pressed(code) or Input.is_key_pressed(code)


const SLOWMO_SCALE := 0.18
const SLOWMO_HOLD_MS := 2200  # real milliseconds at SLOWMO_SCALE
const SLOWMO_RAMP_MS := 450  # real milliseconds ramping back to 1.0


func _process(delta: float) -> void:
	# Free-fly (FPS floating): the mouse looks, WASD flies where you're aiming,
	# E/Q rise and dive, Shift sprints.
	var move := Vector3.ZERO
	var basis := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	if _key_down(KEY_W):
		move -= basis.z
	if _key_down(KEY_S):
		move += basis.z
	if _key_down(KEY_D):
		move += basis.x
	if _key_down(KEY_A):
		move -= basis.x
	if _key_down(KEY_E):
		move += Vector3.UP
	if _key_down(KEY_Q):
		move -= Vector3.UP
	if move != Vector3.ZERO:
		var speed := _fly_speed * (3.0 if _key_down(KEY_SHIFT) else 1.0)
		var limit := _ground_size() * 0.5 + 40.0
		_pivot.position += move.normalized() * speed * delta
		_pivot.position.x = clampf(_pivot.position.x, -limit, limit)
		_pivot.position.z = clampf(_pivot.position.z, -limit, limit)
		_pivot.position.y = clampf(_pivot.position.y, 0.15, 200.0)


	# Cinematic slow motion: hold, then ramp back on the real clock (the
	# scaled delta is useless for timing our own exit).
	if _slowmo_until_ms > 0:
		var now := Time.get_ticks_msec()
		if now < _slowmo_until_ms:
			Engine.time_scale = SLOWMO_SCALE
		else:
			var ramp := (now - _slowmo_until_ms) / float(SLOWMO_RAMP_MS)
			Engine.time_scale = minf(SLOWMO_SCALE + (1.0 - SLOWMO_SCALE) * ramp, 1.0)
			if ramp >= 1.0:
				_slowmo_until_ms = -1

	# Camera shake: decaying trauma, squared so small hits stay subtle.
	if _trauma > 0.0:
		_trauma = maxf(_trauma - delta * 1.3, 0.0)
		var t := _trauma * _trauma
		_camera.rotation = Vector3(
			(randf() - 0.5) * 0.07 * t,
			(randf() - 0.5) * 0.07 * t,
			(randf() - 0.5) * 0.045 * t)
	elif _camera.rotation != Vector3.ZERO:
		_camera.rotation = Vector3.ZERO

	# Adaptive quality: when the solver overruns, halve the substeps until the
	# crunch passes. Rubble settling barely notices; frame time halves.
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	if phys_ms > 24.0 and _world.substep_count > 2:
		_world.substep_count = 2
	elif phys_ms < 9.0 and _world.substep_count < 4:
		_world.substep_count = 4

	# Placement ghost follows the cursor along the surface under it.
	if _charge_mode and _ghost != null:
		var mp := _aim_point()
		var origin := _camera.project_ray_origin(mp)
		var dir := _camera.project_ray_normal(mp)
		var hit: Dictionary = _world.raycast(origin, origin + dir * 200.0)
		if hit.get("hit", false):
			_ghost.visible = true
			var n: Vector3 = hit["normal"]
			_ghost.global_transform = Transform3D(
					_basis_from_normal(n), hit["position"] + n * 0.01)
			_ghost.scale = Vector3.ONE * CHARGE_SPECS[_charge_size].scale
		else:
			_ghost.visible = false

	# Group counts allocate arrays; refreshing 4x a second is plenty.
	_stats_cooldown -= delta
	if _stats_cooldown > 0.0:
		return
	_stats_cooldown = 0.25
	var tree := get_tree()
	var panels := tree.get_nodes_in_group("panel").size()
	var blocks := tree.get_nodes_in_group("block").size()
	var frags := tree.get_nodes_in_group("fragment").size()
	var balls := tree.get_nodes_in_group("projectile").size()
	_stats.text = "fps %d | bodies %d (panels %d, blocks %d, fragments %d, balls %d)" % [
		Engine.get_frames_per_second(), panels + blocks + frags + balls,
		panels, blocks, frags, balls,
	]
	if _fire != null and _fire.burning_count() > 0:
		# flames = visible BurnFX billboards, burning = bodies the sim is
		# actually burning; a gap means the visual cap is the bottleneck.
		_stats.text += " | fire %d/%d" % [BurnFX.active_count(), _fire.burning_count()]
	if _glass != null and _glass.report()["total"] > 0:
		_stats.text += " | glass broken %d" % _glass.report()["total"]
	_update_charge_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if not _mouse_captured:
						_set_mouse_captured(true)  # click the view to grab the mouse
					elif _charge_mode:
						_place_charge(_aim_point())
					else:
						_shoot(_aim_point())
			MOUSE_BUTTON_RIGHT:
				if mb.pressed and _mouse_captured:
					if _charge_mode:
						_remove_last_charge()
					else:
						_blast(_aim_point())
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_fly_speed = clampf(_fly_speed * 1.15, 2.0, 120.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_fly_speed = clampf(_fly_speed / 1.15, 2.0, 120.0)
	elif event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event
		_yaw -= mm.relative.x * 0.0025
		_pitch -= mm.relative.y * 0.0025
		_update_camera()
	elif event is InputEventKey:
		var key: InputEventKey = event
		if not key.pressed or key.echo:
			return
		# In placement mode the number keys pick the charge size instead of
		# switching gyms / resizing the city.
		if _charge_mode and key.keycode >= KEY_1 and key.keycode <= KEY_3:
			_charge_size = key.keycode - KEY_1
			_update_charge_hud()
			return
		match key.keycode:
			KEY_ESCAPE:
				_set_mouse_captured(not _mouse_captured)  # free / re-grab the cursor
			KEY_T:
				_toggle_charge_mode()
			KEY_SPACE:
				_detonate_all()
			KEY_R:
				get_tree().reload_current_scene()
			KEY_B:
				_barrage()
			KEY_N:
				_blast(get_viewport().get_visible_rect().size * 0.5, NUKE_RADIUS, NUKE_IMPULSE)
			KEY_C:
				_clear_rubble()
			KEY_F:
				# Manual ignition: a small local spark on the wood under the
				# cursor. The tight radius lights only that spot so the fire has
				# to SPREAD on its own, instead of lighting a whole wall at once.
				var at := _cursor_point()
				if at != Vector3.INF:
					_fire.torch(at, 0.4)
			# Demo scenarios sit on the number keys.
			KEY_1:
				get_tree().change_scene_to_file("res://scenes/demo/destruction_gym.tscn")
			KEY_2:
				load("res://scenes/demo/city_gym.gd").landmark_mode = true
				get_tree().change_scene_to_file("res://scenes/demo/city_gym.tscn")
			KEY_3:
				# City on ONE key (re-press toggles medium <-> large).
				var CityGym := load("res://scenes/demo/city_gym.gd")
				var grid := 4  # default: medium city
				if get_script() == CityGym and not CityGym.landmark_mode:
					grid = 6 if CityGym.grid_size == 4 else 4
				CityGym.grid_size = grid
				CityGym.landmark_mode = false
				get_tree().change_scene_to_file("res://scenes/demo/city_gym.tscn")
			KEY_4:
				get_tree().change_scene_to_file("res://scenes/demo/fire_gym.tscn")
			KEY_5:
				get_tree().change_scene_to_file("res://scenes/demo/car_gym.tscn")
			KEY_F11:
				var mode := DisplayServer.window_get_mode()
				DisplayServer.window_set_mode(
					DisplayServer.WINDOW_MODE_WINDOWED
					if mode == DisplayServer.WINDOW_MODE_FULLSCREEN
					else DisplayServer.WINDOW_MODE_FULLSCREEN)
			_:
				_extra_key(key.keycode)


## Surface point under the mouse cursor, Vector3.INF when the ray misses.
## Shared by the manual torch (F) and the fire gym's douse/torch tools.
func _cursor_point() -> Vector3:
	var mp := get_viewport().get_mouse_position()
	var origin := _camera.project_ray_origin(mp)
	var dir := _camera.project_ray_normal(mp)
	var hit: Dictionary = _world.raycast(origin, origin + dir * 250.0)
	if hit.get("hit", false):
		return hit["position"]
	return Vector3.INF


func _build_environment() -> void:
	# Quality tier off the GPU (perf pass docs/perf-igpu-vs-rtx.md): a discrete
	# card gets 4x MSAA and 4-split shadows; an integrated GPU -- or headless /
	# unknown -- drops MSAA and uses the cheap single-split shadow at a shorter
	# range. Rendering-only, so physics (and the determinism hash) is untouched.
	var high := RenderingServer.get_video_adapter_type() \
			== RenderingDevice.DEVICE_TYPE_DISCRETE_GPU

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -32, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.45
	sun.light_color = Color(1.0, 0.97, 0.9)  # late-afternoon warmth
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if high \
			else DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 150.0 if high else 70.0
	add_child(sun)

	# Real sky + image-based lighting from a Poly Haven HDRI (CC0). Pure-sky
	# panorama, so our own ground fills the lower hemisphere. Falls back to the
	# procedural gradient if the .hdr isn't present.
	var sky_mat: Material
	var hdri := "res://lib/fx/sky/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
	if ResourceLoader.exists(hdri):
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = load(hdri)
		sky_mat = pano
	else:
		var proc := ProceduralSkyMaterial.new()
		proc.sky_top_color = Color(0.2, 0.4, 0.7)
		proc.sky_horizon_color = Color(0.78, 0.8, 0.82)
		proc.ground_bottom_color = Color(0.28, 0.3, 0.24)
		proc.ground_horizon_color = Color(0.68, 0.7, 0.62)
		sky_mat = proc
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	# Glow makes the explosion shaders bloom -- most of the WOW lives here.
	env.glow_enabled = true
	env.glow_intensity = 1.0
	env.glow_bloom = 0.4
	env.glow_hdr_threshold = 1.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# Multisampling is the biggest iGPU cost here; only the discrete tier pays it.
	var vp := get_viewport()
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_4X if high else Viewport.MSAA_DISABLED


func _build_world() -> void:
	_world = Box3DWorld.new()
	_world.name = "World"
	_world.continuous_collision = true
	if "hit_event_threshold" in _world:
		# body_hit fires for contacts approaching >= this. Below every fracture
		# threshold (glass 2.2, panels 7.0), so the panes/panels filter their own.
		_world.hit_event_threshold = 1.0
	_world.worker_count = 4  # multithreaded solver: rubble piles get big here
	if "async_step" in _world:
		# Newer DLL builds can overlap the solver with rendering; the committed
		# binary predates the property, so guard until it gets rebuilt.
		_world.async_step = true
	add_child(_world)
	# Fire propagation and glass breakage ride every gym: both idle at zero
	# cost until something flammable / glazed registers.
	_fire = FireSystem.attach(_world)
	_glass = GlassSystem.attach(_world)
	# Weather on by default. Wind is a pure function of the tick and applies NO
	# force to structures (only the opt-in "wind_blown" group), so it never
	# perturbs the demolition/settle determinism -- it just drives the visuals.
	_wind = WindSystem.attach(_world, DEFAULT_WIND, DEFAULT_GUST, 0x5117)
	Windsock.attach(_world, _windsock_pos(), _wind)

	_build_ground()


## The terrain. Default: one grass slab. Derived gyms override for special
## terrain (the landmark park carves a river channel through it).
func _build_ground() -> void:
	_ground_slab(Vector3(0, -0.5, 0), Vector3(_ground_size(), 1, _ground_size()),
			Color(0.75, 0.85, 0.65), true)


## One static terrain box; `grassy` picks the grass texture, else bare earth.
func _ground_slab(at: Vector3, size: Vector3, tint: Color, grassy: bool) -> void:
	var slab := Box3DBody.new()
	slab.body_type = Box3DBody.STATIC
	slab.box_size = size
	slab.position = at
	slab.friction = 0.8
	_world.add_child(slab)
	BoxVis.box(slab, size, tint,
			true, preload("res://lib/fx/textures/facades/grass.jpg") \
			if grassy else null)


## Side length of the square ground slab. Derived gyms override to fit
## whatever they build (the city scales it with grid size).
func _ground_size() -> float:
	return 80.0


## Half-extent of the area barrage cannonballs aim at.
func _target_extent() -> float:
	return 12.0


## Where the diegetic windsock stands. Default: an open corner scaled to the
## ground so it reads against the sky. Scenes with a small cluster on a big
## ground (the fire range) override this to plant it beside the action.
func _windsock_pos() -> Vector3:
	var e := clampf(_ground_size() * 0.32, 7.0, 26.0)
	return Vector3(e, 0.0, e)


func _build_tower() -> void:
	# Rings of tangent blocks, every other ring rotated half a block: a
	# running-bond round tower, like brickwork.
	for ring in TOWER_RINGS:
		var y := (ring + 0.5) * BLOCK_SIZE.y
		var phase := 0.0 if ring % 2 == 0 else PI / BLOCKS_PER_RING
		for i in BLOCKS_PER_RING:
			var angle := phase + TAU * i / BLOCKS_PER_RING
			var block := BreakableBlock.new()
			block.box_size = BLOCK_SIZE
			block.friction = 0.75
			block.position = Vector3(cos(angle) * TOWER_RADIUS, y, sin(angle) * TOWER_RADIUS)
			block.rotation = Vector3(0.0, -(angle + PI / 2.0), 0.0)
			var shade := 1.0 + _rng.randf_range(-0.12, 0.08)
			block.block_color = Color(0.78 * shade, 0.68 * shade, 0.52 * shade)
			_world.add_child(block)

	# A cap slab so toppling reads clearly from any angle.
	var cap := BreakableBlock.new()
	cap.box_size = Vector3(6.2, 0.4, 6.2)
	cap.density = 0.8
	cap.position = Vector3(0, TOWER_RINGS * BLOCK_SIZE.y + 0.2, 0)
	cap.block_color = Color(0.5, 0.48, 0.45)
	_world.add_child(cap)


func _build_camera() -> void:
	# Free-fly: the pivot IS the camera position; the camera sits at its origin.
	_pivot = Node3D.new()
	_pivot.position = Vector3(0, 6.0, 24.0)
	add_child(_pivot)
	_camera = Camera3D.new()
	_camera.fov = 70.0
	_pivot.add_child(_camera)
	_update_camera()
	_set_mouse_captured(true)


func _update_camera() -> void:
	_pitch = clampf(_pitch, -1.4, 1.4)  # ~+-80deg, near straight up/down
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3.ZERO


## Screen point the shots/charges aim at: the crosshair (centre) while the mouse
## is captured, or the real cursor when it's been freed.
func _aim_point() -> Vector2:
	if _mouse_captured:
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_mouse_position()


func _set_mouse_captured(cap: bool) -> void:
	_mouse_captured = cap
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if cap else Input.MOUSE_MODE_VISIBLE
	if _crosshair != null:
		_crosshair.visible = cap


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var help := Label.new()
	help.text = "LMB shoot | RMB blast | B barrage | N nuke | C clear rubble | F ignite | R reset | 1 tower | 2 landmarks | 3 city (re-press: size) | 4 fire | 5 derby\n" \
			+ "Mouse look | WASD fly | E/Q up/down | Shift fast | wheel speed | Esc free cursor | F11 fullscreen | T charges | SPACE detonate | crane: G/H slew, J/K trolley, PgUp/Dn hoist"
	help.position = Vector2(12, 8)
	_style_label(help)
	layer.add_child(help)
	_stats = Label.new()
	_stats.position = Vector2(12, 56)
	_style_label(_stats)
	layer.add_child(_stats)
	_charge_label = Label.new()
	_charge_label.position = Vector2(12, 80)
	_charge_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_style_label(_charge_label)
	layer.add_child(_charge_label)
	_update_charge_hud()
	# Aiming crosshair, centred on screen while the mouse is captured.
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 22)
	_style_label(_crosshair)
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.visible = _mouse_captured
	layer.add_child(_crosshair)


func _style_label(label: Label) -> void:
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)


func _shoot(screen_pos: Vector2) -> void:
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	_spawn_ball(origin + dir * 2.0, dir * BALL_SPEED)


func _spawn_ball(from: Vector3, velocity: Vector3) -> void:
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = BALL_RADIUS
	ball.density = 12.0
	ball.friction = 0.5
	ball.continuous = true  # fast balls vs 0.35 m thin panels: needs CCD
	ball.position = from
	ball.add_to_group("projectile")
	_world.add_child(ball)
	ball.set_linear_velocity(velocity)
	BoxVis.sphere(ball, BALL_RADIUS, Color(0.16, 0.16, 0.18))

	# Lifetime rides on the ball itself: freed with it, no dangling timers.
	var timer := Timer.new()
	timer.wait_time = 12.0
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(ball.queue_free)
	ball.add_child(timer)


func _barrage() -> void:
	var extent := _target_extent()
	for i in BARRAGE_COUNT:
		var a := _rng.randf_range(0.0, TAU)
		var from := Vector3(cos(a), 0.0, sin(a)) * (extent + _rng.randf_range(14.0, 22.0))
		from.y = _rng.randf_range(6.0, 18.0)
		var target := Vector3(
			_rng.randf_range(-extent, extent), _rng.randf_range(1.0, 5.0),
			_rng.randf_range(-extent, extent))
		_spawn_ball(from, (target - from).normalized() * (BALL_SPEED * 1.15))


func _blast(screen_pos: Vector2, radius := BLAST_RADIUS, impulse := BLAST_IMPULSE) -> void:
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var hit: Dictionary = _world.raycast(origin, origin + dir * 200.0)
	var at: Vector3
	if hit.get("hit", false):
		at = hit["position"] - dir * 0.5
	else:
		at = origin + dir * 30.0
	ExplosionFX.blast(_world, at, radius, impulse)


func _clear_rubble() -> void:
	for frag in get_tree().get_nodes_in_group("fragment"):
		frag.queue_free()


func _toggle_charge_mode() -> void:
	_charge_mode = not _charge_mode
	if _charge_mode:
		_ghost = DemoCharge.new()
		_ghost.is_ghost = true
		add_child(_ghost)
		_ghost.visible = false
	elif _ghost != null:
		_ghost.queue_free()
		_ghost = null
	_update_charge_hud()


func _place_charge(screen_pos: Vector2) -> void:
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var hit: Dictionary = _world.raycast(origin, origin + dir * 200.0)
	if not hit.get("hit", false):
		return
	var collider: Box3DBody = hit["collider"]
	if collider == null or not is_instance_valid(collider):
		return
	var spec: Dictionary = CHARGE_SPECS[_charge_size]
	var charge := DemoCharge.new()
	charge.blast_radius = spec.radius
	charge.blast_impulse = spec.impulse
	# Parent to the wall itself: the charge rides the panel if it moves, and
	# dies with it if something else demolishes the wall first.
	collider.add_child(charge)
	var n: Vector3 = hit["normal"]
	charge.global_transform = Transform3D(_basis_from_normal(n), hit["position"] + n * 0.01)
	charge.scale = Vector3.ONE * spec.scale
	_placed.append(charge)
	_update_charge_hud()


func _remove_last_charge() -> void:
	while not _placed.is_empty():
		var charge = _placed.pop_back()
		if is_instance_valid(charge):
			charge.queue_free()
			_update_charge_hud()
			return


## The plunger: every placed charge fires, rippling outward in placement
## order with short random offsets -- one keypress, whole demolition.
func _detonate_all() -> void:
	var charges := get_tree().get_nodes_in_group("charge")
	if charges.is_empty():
		return
	var i := 0
	for charge in charges:
		charge.armed = true
		var delay := 0.14 * i + _rng.randf_range(0.0, 0.06)
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(charge):
				charge.detonate())
		i += 1
	_placed.clear()
	_update_charge_hud()


func _basis_from_normal(n: Vector3) -> Basis:
	var up := Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT
	var x := up.cross(n).normalized()
	return Basis(x, n.cross(x), n)


func _update_charge_hud() -> void:
	if _charge_label == null:
		return
	var count := get_tree().get_nodes_in_group("charge").size()
	if _charge_mode:
		_charge_label.text = "CHARGE MODE [%s] | LMB place | RMB undo | 1/2/3 size | SPACE detonate (%d) | T exit" % [
			CHARGE_SPECS[_charge_size].label, count]
	elif count > 0:
		_charge_label.text = "charges armed: %d | SPACE detonate | T place more" % count
	else:
		_charge_label.text = "T: demolition charges"


## Called (via the camera_shake group) by ExplosionFX for every blast.
func shake_from(pos: Vector3, strength: float) -> void:
	var dist := _camera.global_position.distance_to(pos)
	_trauma = clampf(_trauma + strength / maxf(1.0, dist * 0.055), 0.0, 1.0)
	# Really big detonations (strength = blast_radius * 0.16, so radius ~9+)
	# earn a cinematic slow-mo. Overlapping blasts extend it, never restart it.
	if strength >= 1.4:
		_slowmo_until_ms = maxi(_slowmo_until_ms, Time.get_ticks_msec() + SLOWMO_HOLD_MS)
