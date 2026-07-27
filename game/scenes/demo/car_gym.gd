extends "res://gyms/destruction/destruction_gym.gd"

## Car gym — suspension proving ground and demolition derby, ONE scene:
## the old Destruction Derby bowl with the test furniture inside it.
##
## Six cars spawn around the rim of a walled circular arena facing the
## centre — yours plus five AI who hunt their nearest living rival, ram,
## and back out when stuck. Every car is the same all-physics CarRig
## (lib/bodies/car_rig.gd): wheel-joint spring/damper suspension you can
## retune live, rear-drive motors with traction control, spring steering,
## and jointed bodywork — bumpers, doors, hood, trunk, roof — that fatigues
## and tears off, wheels that rip out, damage accumulated from the solver's
## real body_hit approach speeds. Wrecks die where they burn; last car
## standing wins.
##
## The bowl doubles as the suspension playground: a washboard rumble strip
## sets the ride frequency buzzing, a crossover ramp jump crosses the
## centre of the arena (straight out of the old game), tire stacks shove
## around, and a crate stack begs to be driven through. The HUD telemetry
## line reads the springs live — watch the load walk to the nose under
## braking and to the outside pair mid-corner.
##
##   ARROWS      drive: Up/Down throttle+brake, Left/Right steer
##               (W A S D drives too while the chase cam is on)
##   X           handbrake (locks the rears — skids)
##   V           chase camera on/off        Y   a fresh car (old one stays)
##   U / J       suspension stiffer / softer   (spring hertz)
##   I / K       damper firmer / softer        (damping ratio)
##
## All the destruction toys still work — cannonball the pack (LMB), torch a
## wreck early (F), or drop a nuke on the whole derby (N).

const CarRig := preload("res://lib/bodies/car_rig.gd")

const CHASE_DIST := 8.5
const CHASE_LIFT := 1.4

const ARENA_RADIUS := 38.0
const SPAWN_RADIUS := 28.0
const WALL_SEGMENTS := 40
const OPPONENTS := 5
const AI_STUCK_TIME := 1.2         # s of no movement before reversing out
const AI_REVERSE_TIME := 1.1       # s of backing up
const BOT_PAINTS := [
	Color(0.15, 0.35, 0.8),   # blue
	Color(0.9, 0.75, 0.1),    # yellow
	Color(0.15, 0.6, 0.25),   # green
	Color(0.55, 0.2, 0.65),   # purple
	Color(0.9, 0.45, 0.1),    # orange
]

## Where the player's car spawns (and Y-resets to): rim slot 0, nose at
## the centre of the bowl like everyone else. Tests override this.
var spawn_transform := Transform3D(Basis(Vector3.UP, PI),
		Vector3(SPAWN_RADIUS, 0.12, 0.0))
## How many AI rivals join. The proving-ground test sets 0 for clean runs.
var opponents := OPPONENTS
## Headless test hook: drive the player car with the same AI as the bots.
var player_ai := false

var _car: Node3D
var _bots: Array[Dictionary] = []  # {rig, stuck_t, rev_t}
# Detailed body shells, when fetched (tools/fetch_car_assets.py): every car
# in the pack gets a different model. Empty = the procedural box cars.
var _models: PackedStringArray = CarRig.available_models()
var _chase := true
var _car_label: Label
var _derby_label: Label
var _telemetry_cooldown := 0.0
var _pack_size := 0                # cars that entered the derby


func _ready() -> void:
	super()
	# Open on the chase camera, already behind the player looking into
	# the bowl (the car noses -X, so the camera sits out at +X).
	_yaw = PI / 2.0
	_pitch = -0.18
	_update_camera()
	if player_ai:  # headless test: the player car fights on autopilot
		_car.input_enabled = false
		_bots.append({rig = _car, stuck_t = 0.0, rev_t = 0.0})


func _ground_size() -> float:
	return 110.0


func _target_extent() -> float:
	return 30.0


## The pyramid corner windsock would stand inside the bowl; plant it out
## past the wall instead, visible over the barriers.
func _windsock_pos() -> Vector3:
	return Vector3(46.0, 0.0, 46.0)


func _build_structures() -> void:
	_car = _spawn_car()
	_wire_wreck_fx(_car)
	_build_arena()
	_build_furniture()
	var bot_models := _bot_models()
	for i in opponents:
		var a := TAU * (i + 1) / (OPPONENTS + 1)
		var rig: Node3D = CarRig.spawn(_world, Transform3D(
				Basis(Vector3.UP, PI - a),
				Vector3(cos(a) * SPAWN_RADIUS, 0.12, sin(a) * SPAWN_RADIUS)), {
					color = BOT_PAINTS[i % BOT_PAINTS.size()],
					model = "" if bot_models.is_empty() \
							else bot_models[i % bot_models.size()],
				})
		_bots.append({rig = rig, stuck_t = 0.0, rev_t = 0.0})
		_wire_wreck_fx(rig)
	_pack_size = 1 + opponents


## The car drives ITSELF (CarRig is atomic — input lives on the rig, so the
## same spawn call drops a drivable car into any other gym). This scene only
## adds the arena, rivals, telemetry and the chase camera around it.
func _spawn_car() -> Node3D:
	return CarRig.spawn(_world, spawn_transform, {
		input = true,
		wasd = _chase,  # chase cam frees W A S D from camera flight
		model = _player_model(),
	})


## The player drives the detailed car (car_concept) when it's fetched; otherwise
## the first model alphabetically. Empty (no models) → the procedural box car.
const PLAYER_MODEL := "car_concept"


func _player_model() -> String:
	if _models.is_empty():
		return ""
	return PLAYER_MODEL if _models.has(PLAYER_MODEL) else _models[0]


## The bots share out the remaining models (the player's excluded), so two
## detailed cars don't both spawn and the pack still reads as varied.
func _bot_models() -> PackedStringArray:
	var out := PackedStringArray()
	var pm := _player_model()
	for m in _models:
		if m != pm:
			out.append(m)
	return out


func _build_arena() -> void:
	# The Bowl: a ring of red/white concrete barriers, tall enough that a
	# car ramping off a rival's hood stays in the show.
	for i in WALL_SEGMENTS:
		var a := TAU * i / WALL_SEGMENTS
		var wall := Box3DBody.new()
		wall.body_type = Box3DBody.STATIC
		wall.box_size = Vector3(6.4, 4.2, 0.5)
		wall.friction = 0.6
		wall.position = Vector3(cos(a) * ARENA_RADIUS, 2.1, sin(a) * ARENA_RADIUS)
		wall.rotation = Vector3(0.0, -(a + PI / 2.0), 0.0)
		_world.add_child(wall)
		BoxVis.box(wall, wall.box_size,
				Color(0.85, 0.2, 0.2) if i % 2 == 0 else Color(0.92, 0.9, 0.86))


## The proving-ground furniture, arranged inside the bowl. Keeps a clear
## lane along z = -22 (the headless straight-line test drives it).
func _build_furniture() -> void:
	# Washboard rumble strip: pings the suspension at ride frequency.
	for i in 8:
		_static_box(Vector3(-24.0 + i * 1.4, 0.06, -10.0),
				Vector3(0.5, 0.12, 6.0), Color(0.85, 0.8, 0.7))

	# Crossover ramp jump straight across the centre of the bowl — the
	# Destruction Derby special. Full droop in the air, bottoming landing,
	# and mid-air rams for the brave.
	_ramp(Vector3(-14.0, 0.0, 0.0), 8.0, 1.4, 7.0, false)
	_ramp(Vector3(6.0, 0.0, 0.0), 8.0, 1.4, 7.0, true)

	# Tire stacks: heavy soft obstacles that shove around.
	for i in 4:
		var a := TAU * (i + 0.5) / 4.0
		for level in 2:
			var tire := Box3DBody.new()
			tire.shape_type = Box3DBody.CYLINDER
			tire.capsule_radius = 0.55   # cylinders reuse the capsule fields
			tire.capsule_height = 0.45
			tire.density = 300.0
			tire.friction = 0.9
			tire.position = Vector3(cos(a) * 17.0, 0.25 + level * 0.47,
					sin(a) * 17.0)
			tire.add_to_group("fragment")
			_world.add_child(tire)
			var mi := MeshInstance3D.new()
			mi.mesh = _tire_mesh()
			mi.material_override = _tire_material()
			tire.add_child(mi)

	# A crate wall to drive through — the blocks fracture on impact.
	for row in 3:
		for col in 5:
			var block := BreakableBlock.new()
			block.box_size = Vector3(1.1, 0.55, 0.5)
			block.friction = 0.7
			block.position = Vector3(
					-2.2 + col * 1.1 + (0.55 if row % 2 == 0 else 0.0),
					(row + 0.5) * 0.55, 17.5)
			var shade := 1.0 + _rng.randf_range(-0.1, 0.06)
			block.block_color = Color(0.72 * shade, 0.5 * shade, 0.4 * shade)
			_world.add_child(block)


static var _tire_mat: StandardMaterial3D
static var _tire_msh: CylinderMesh


static func _tire_material() -> StandardMaterial3D:
	if _tire_mat == null:
		_tire_mat = StandardMaterial3D.new()
		_tire_mat.albedo_color = Color(0.11, 0.11, 0.12)
		_tire_mat.roughness = 0.95
	return _tire_mat


static func _tire_mesh() -> CylinderMesh:
	if _tire_msh == null:
		_tire_msh = CylinderMesh.new()
		_tire_msh.top_radius = 0.55
		_tire_msh.bottom_radius = 0.55
		_tire_msh.height = 0.45
	return _tire_msh


func _static_box(at: Vector3, size: Vector3, tint: Color) -> void:
	var box := Box3DBody.new()
	box.body_type = Box3DBody.STATIC
	box.box_size = size
	box.friction = 0.9
	box.position = at
	_world.add_child(box)
	BoxVis.box(box, size, tint)


## A wedge ramp approximated by a rotated slab sunk into the ground:
## `down` false = takeoff (rises toward +X), true = landing (falls back).
func _ramp(at: Vector3, length: float, height: float, width: float,
		down: bool) -> void:
	var angle := atan2(height, length)
	var slab := Vector3(sqrt(length * length + height * height), 0.3, width)
	var box := Box3DBody.new()
	box.body_type = Box3DBody.STATIC
	box.box_size = slab
	box.friction = 0.95
	box.position = at + Vector3(length / 2.0, height / 2.0 - 0.12, 0.0)
	box.rotation = Vector3(0.0, 0.0, (angle if not down else -angle))
	_world.add_child(box)
	BoxVis.box(box, slab, Color(0.6, 0.62, 0.66))


## Wreck ceremony, straight from the sim's car_wrecked signal: a small
## blast pops the loosened panels off, and the shell catches fire (the
## fire system's ground pyre keeps it burning where it died).
func _wire_wreck_fx(rig: Node3D) -> void:
	rig.car_wrecked.connect(func() -> void:
		if not is_instance_valid(rig) or not is_instance_valid(rig.chassis):
			return
		var at: Vector3 = rig.chassis.global_position
		ExplosionFX.blast(_world, at, 3.0, 2.5)
		_fire.torch(at, 0.9))


# --- Bot drivers ------------------------------------------------------------

func _physics_process(delta: float) -> void:
	for bot in _bots:
		_drive_bot(bot, delta)


## One derby brain: aim at the nearest living rival, floor it, and if the
## car stops making progress back out for a second and swing in again.
func _drive_bot(bot: Dictionary, delta: float) -> void:
	var rig: Node3D = bot.rig
	if not is_instance_valid(rig) or rig.wrecked \
			or not is_instance_valid(rig.chassis):
		return
	var target: Node3D = _nearest_rival(rig)
	if target == null:
		rig.drive(0.0, 0.0, true)  # champion: park and hold
		return
	var local: Vector3 = rig.chassis.global_transform.affine_inverse() \
			* target.chassis.global_position
	var steer := clampf(atan2(-local.z, local.x) * 1.2, -1.0, 1.0)
	var throttle := 1.0
	# Rival square behind? Reverse-ram — shorter than turning the bowl.
	if local.x < -2.0 and absf(local.z) < 4.0:
		throttle = -1.0
		steer = -steer
	if bot.rev_t > 0.0:
		bot.rev_t -= delta
		rig.drive(-1.0, -steer, false)
		return
	if absf(rig.speed()) < 0.7:
		bot.stuck_t += delta
		if bot.stuck_t > AI_STUCK_TIME:
			bot.stuck_t = 0.0
			bot.rev_t = AI_REVERSE_TIME
	else:
		bot.stuck_t = 0.0
	rig.drive(throttle, steer, false)


func _nearest_rival(rig: Node3D) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for other in _all_cars():
		if other == rig or not is_instance_valid(other) or other.wrecked \
				or not is_instance_valid(other.chassis):
			continue
		var d: float = rig.chassis.global_position.distance_squared_to(
				other.chassis.global_position)
		if d < best_d:
			best_d = d
			best = other
	return best


func _all_cars() -> Array[Node3D]:
	var out: Array[Node3D] = []
	if _car != null and is_instance_valid(_car):
		out.append(_car)
	for bot in _bots:
		# In player_ai mode the player rig is ALSO a bot — don't list twice.
		if is_instance_valid(bot.rig) and bot.rig != _car:
			out.append(bot.rig)
	return out


func _alive_count() -> int:
	var n := 0
	for car in _all_cars():
		if not car.wrecked:
			n += 1
	return n


# --- Camera, keys & HUD ------------------------------------------------------

func _process(delta: float) -> void:
	super(delta)
	if _car == null or not is_instance_valid(_car):
		return
	# Chase camera: the free-fly pivot orbits the chassis (mouse still aims;
	# wheel still sets fly speed for when you toggle back).
	if _chase:
		var target: Vector3 = _car.chassis.global_position + Vector3.UP * CHASE_LIFT
		var rot := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
		_pivot.position = target + rot.z * CHASE_DIST

	_telemetry_cooldown -= delta
	if _telemetry_cooldown > 0.0:
		return
	_telemetry_cooldown = 0.1
	var loads: Array[float] = _car.wheel_loads()
	var kmh: float = absf(_car.speed()) * 3.6
	_car_label.text = "%3.0f km/h | spring %.1f Hz (U/J) | damper ζ %.2f (I/K) | load kN  FL %.1f  FR %.1f  RL %.1f  RR %.1f%s" % [
		kmh, _car.suspension_hertz, _car.suspension_damping,
		loads[0] / 1000.0, loads[1] / 1000.0, loads[2] / 1000.0, loads[3] / 1000.0,
		"" if _car.is_upright() else "  —  FLIPPED: Y resets",
	]
	if _derby_label == null:
		return
	var alive := _alive_count()
	var status := "DERBY  %d/%d cars alive | damage %d%%" % [
		alive, _pack_size,
		int(clampf(_car.damage / _car.WRECK_DAMAGE, 0.0, 1.0) * 100.0)]
	if _car.wrecked:
		status += "  —  WRECKED. R restarts, Y begs a fresh car"
	elif alive == 1 and _pack_size > 1:
		status += "  —  LAST CAR STANDING. CHAMPION!"
	_derby_label.text = status


func _extra_key(code: int) -> void:
	match code:
		KEY_V:
			_chase = not _chase
			_car.input_wasd = _chase
		KEY_Y:
			_respawn_car()
		KEY_U:
			_car.set_suspension(_car.suspension_hertz + 0.2, _car.suspension_damping)
		KEY_J:
			_car.set_suspension(_car.suspension_hertz - 0.2, _car.suspension_damping)
		KEY_I:
			_car.set_suspension(_car.suspension_hertz, _car.suspension_damping + 0.05)
		KEY_K:
			_car.set_suspension(_car.suspension_hertz, _car.suspension_damping - 0.05)


## Y hands the player a fresh car; the old one stays in the bowl as scrap
## (and as a target — the pack grows by one).
func _respawn_car() -> void:
	if _car != null and is_instance_valid(_car):
		_car.queue_free()
	_car = _spawn_car()
	_wire_wreck_fx(_car)
	_pack_size += 1


func _build_hud() -> void:
	super()
	var layer := _car_hud_layer()
	_car_label = Label.new()
	_car_label.position = Vector2(12, 104)
	_car_label.add_theme_color_override("font_color", Color(0.65, 0.95, 1.0))
	_style_label(_car_label)
	layer.add_child(_car_label)
	var controls := Label.new()
	controls.text = "ARROWS drive (WASD too in chase cam) | X handbrake | V chase cam | Y fresh car | U/J spring | I/K damper"
	controls.position = Vector2(12, 128)
	_style_label(controls)
	layer.add_child(controls)
	_derby_label = Label.new()
	_derby_label.position = Vector2(12, 152)
	_derby_label.add_theme_font_size_override("font_size", 18)
	_derby_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	_style_label(_derby_label)
	layer.add_child(_derby_label)


## The CanvasLayer super()._build_hud() created (its labels' parent).
func _car_hud_layer() -> CanvasLayer:
	return _stats.get_parent() as CanvasLayer
