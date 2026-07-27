extends Node3D

## A drivable car built entirely from Box3D joints — nothing ever pushes the
## chassis directly. Four sphere wheels hang on Box3DWheelJoints whose
## soft-constraint suspension springs (stiffness in hertz, damper as a ratio,
## travel clamped in metres) carry the body; the rear pair drives through the
## joints' spin motors and the front pair steers by spring toward a target
## angle. Same construction as box3d's own Driving sample, scaled up to real
## car numbers: a ~1.3 t chassis, ~45 kg wheels, a 2.7 m wheelbase and a
## centre of mass dropped below the body's centroid (set_mass_data), so weight
## transfer, brake dive, squat under throttle and body roll all fall out of
## the simulation instead of being animated.
##
## The bodywork is physical too: hood, trunk lid, both doors, roof and both
## bumpers are separate rigid bodies welded on with Box3DFixedJoints that
## TEAR OFF when the weld's live constraint force passes a threshold — and
## the thresholds sink as the car accumulates damage from real body_hit
## contact events, until it wrecks (engine dies, anti-roll bar cut). Wheels
## rip off under crash loads the same way. Derby-grade wear, all of it read
## out of the solver rather than scripted.
##
## The rig is ATOMIC: one node, no scene dependencies, drivable on its own.
## Drop it into ANY gym two ways —
##   code:    var car := CarRig.spawn(world, Transform3D(Basis(), pos),
##                    {input = true})        # arrows drive it, X handbrake
##   editor:  instance lib/bodies/car.tscn under a Box3DWorld and press play
## or leave input off and feed it yourself:
##   car.drive(throttle, steer, handbrake)   # each physics tick, all -1..1
##   car.set_suspension(hertz, damping)      # live retune, all four corners
##   car.speed()                             # signed m/s along the nose (+X)
##   car.wheel_loads()                       # per-corner spring force (N)
##
## Tuning lessons that cost time, kept here so they aren't relearned:
##   - Suspension frequency is mass-independent (Box3D's spring is specified
##     in hertz), but MOTOR TORQUE is not — real masses need real torques
##     (~1400 N·m per driven wheel to move 1.4 t briskly, not the sample's 5).
##   - Keep the chassis:wheel mass ratio civil (~30:1). Featherweight wheels
##     under a heavy body defeat the iterative solver the same way the cable
##     links do (see cable.gd) — the corners buzz and the car "boils".
##   - Sphere wheels, not cylinders: one smooth contact point that survives
##     rolling across box seams; friction is a tire model stand-in, so it
##     runs higher (2.0-2.4) than a real μ — and split front>rear for the
##     understeer bias, or the rear breaks away first and the car spins.

const _Self = preload("res://lib/bodies/car_rig.gd")
const BoxVis := preload("res://lib/fx/box_visuals.gd")

# Geometry (metres): compact-sedan footprint.
const WHEELBASE := 2.7
const TRACK := 1.56
const WHEEL_RADIUS := 0.36
const BODY_SIZE := Vector3(4.2, 0.55, 1.8)
const CABIN_SIZE := Vector3(1.9, 0.52, 1.62)
const BODY_CENTER_Y := 0.66      # body slab centre above ground at rest
const CABIN_LIFT := 0.53         # cabin centre above the body slab centre
const COM_DROP := 0.28           # centre of mass below the body centroid
# The chassis settles this far below BODY_CENTER_Y once the suspension takes the
# weight (measured: rests at ~0.455). The model shell is a child of the chassis,
# so it sinks with it; the shell grounding lifts by this so the car sits on its
# wheels at rest. A fixed physics property (springs/mass), so it's the same for
# every car and independent of the per-model wheel radius. Procedural (box) cars
# don't use it — their box body is centred on the chassis, not ground-referenced.
const BODY_SETTLE_SAG := 0.205

# Masses via density: body slab ~1200 kg, wheels ~44 kg each (ratio ~28:1).
const BODY_DENSITY := 260.0
const WHEEL_DENSITY := 225.0
# Grip split front > rear: the understeer bias every road car is set up
# with. Symmetric grip + rear drive fishtailed into a spin at ~70 km/h.
const TIRE_FRICTION_FRONT := 2.4
const TIRE_FRICTION_REAR := 2.0

# Drivetrain: rear-wheel drive. 88 rad/s * 0.36 m ≈ 114 km/h flat out.
# Torque is capped low-speed, POWER caps it beyond ~13 m/s — a constant
# 1400 N·m all the way to top speed shoved the saturated rear tires into
# a spin; a real engine runs out of force exactly the same way this does.
const TOP_WHEEL_SPEED := 88.0    # rad/s spin target at full throttle
const DRIVE_TORQUE := 1000.0     # N·m per driven wheel, launch cap
const ENGINE_POWER := 100000.0   # W, both driven wheels together
const ENGINE_DRAG_TORQUE := 90.0 # throttle released: gentle rolling drag
const HANDBRAKE_TORQUE := 2600.0 # rear wheels locked hard
# Traction control: never command wheel speed more than this far beyond the
# current rolling speed. Without it the velocity-servo motor lights the rear
# tires into a permanent burnout (commanded 88 rad/s at 3 m/s of ground
# speed), the saturated contacts have no lateral grip left, and the car
# spins at ~60 km/h. With it, slip stays in the tire's working range —
# which is also why it doubles as a progressive ABS when throttle reverses.
const SLIP_MARGIN := 6.0         # rad/s of allowed slip
const SLIP_FRACTION := 0.1       # plus this fraction of rolling speed

# Steering: spring-servo toward the target angle, lock shrinking with speed
# (35° when parked, ~9° flat out) so highway speeds can't snap-roll the car.
const STEER_LOCK_LOW := 0.61     # rad, below WALK_SPEED
const STEER_LOCK_HIGH := 0.12    # rad, at TOP speed
const WALK_SPEED := 4.0          # m/s
# Stiff, hard-damped servo: a soft steering spring shimmies at speed (the
# joint has no caster to self-centre with, so the spring must be firm).
const STEER_HERTZ := 10.0
const STEER_DAMPING := 1.0
const STEER_TORQUE := 900.0

# Suspension defaults: 2.2 Hz / ζ 0.7 is a firm road car. (Real saloons ride
# ~1.2-1.5 Hz, sports cars 2-2.5; softer shows more float, harder more skip.)
const SUSPENSION_HERTZ := 2.2
const SUSPENSION_DAMPING := 0.7
const SUSPENSION_TRAVEL := 0.22  # m, each way from the rest anchor

# Anti-roll assist: a torque-capped Box3DParallelJoint leaning the body
# upright — the ESC/anti-roll-bar stand-in. Weak on purpose: it trims body
# roll but a bad enough jump still flips the car.
const ASSIST_HERTZ := 0.35
const ASSIST_MAX_TORQUE := 1400.0

# Bodywork: every panel is its OWN Box3D body welded to the chassis by a
# Box3DFixedJoint, torn off when the weld's live constraint force passes
# its threshold (the engine reports joint force but doesn't auto-break, so
# the rig frees overloaded joints itself — same pattern as cable.gd).
# name: [local pos, size, density, break force N]
const PANEL_SPECS := {
	"BumperF": [Vector3(2.19, -0.05, 0), Vector3(0.18, 0.3, 1.95), 200.0, 8000.0],
	"BumperR": [Vector3(-2.19, -0.05, 0), Vector3(0.18, 0.3, 1.95), 200.0, 8000.0],
	"Hood": [Vector3(1.32, 0.315, 0), Vector3(1.5, 0.08, 1.65), 160.0, 5000.0],
	"Trunk": [Vector3(-1.7, 0.315, 0), Vector3(0.75, 0.08, 1.65), 160.0, 5000.0],
	"DoorL": [Vector3(-0.35, 0.15, 0.94), Vector3(1.55, 0.5, 0.08), 400.0, 6000.0],
	"DoorR": [Vector3(-0.35, 0.15, -0.94), Vector3(1.55, 0.5, 0.08), 400.0, 6000.0],
	"Roof": [Vector3(-0.35, 0.84, 0), Vector3(2.0, 0.07, 1.7), 80.0, 6000.0],
	# ^ roof skin kept light: it's the panel with the biggest roll lever,
	# and a heavy one tips the corner balance from slide into rollover
}
# Panel welds are COMPLIANT (a stiff spring, not a rigid lock): a rigid
# joint between a ~15 kg panel and a 1.3 t chassis is exactly the extreme
# mass-ratio pairing that defeats the iterative solver (cable.gd learned
# this first) — under a pileup it went non-finite. Soft welds keep the
# solver sane, bound the readable force to the spring's own scale (so the
# thresholds above mean something), and let panels visibly flex on hits.
const WELD_HERTZ := 25.0
const WHEEL_BREAK_FORCE := 300000.0 # N on the wheel joint's rigid part —
	# losing a wheel should be a late-derby catastrophe, not an opener
const BREAK_CHECK_INTERVAL := 0.1   # s between weld-overload sweeps
# Welds fail by FATIGUE, not by one reading: crash spikes on a rigid joint
# reach the meganewton range for a frame, so a naive force>threshold check
# stripped every panel in the opening pileup. Each over-threshold sample
# adds (force/threshold - 1) fatigue — capped, so even a monster spike
# can't shear a healthy weld alone — and the weld lets go when the budget
# is spent. Repeated abuse rips panels off; one clean hit doesn't.
const WELD_FATIGUE_BREAK := 6.0
const WELD_FATIGUE_SAMPLE_CAP := 3.0
const BUMPER_DAMAGE_FACTOR := 0.6   # bumpers are built for this

# Damage: accumulated from the chassis' body_hit events (real solver
# approach speeds). A wrecked car's engine dies, its anti-roll joint is
# cut and every remaining weld loosens — derby rules.
const DAMAGE_PER_HIT_SPEED := 2.0   # damage per m/s of approach beyond the floor
const HIT_SPEED_FLOOR := 2.5        # slower contacts are body lean, not hits
const WRECK_DAMAGE := 260.0         # a derby lasts minutes, not one pileup
const SPAWN_GRACE_TICKS := 45       # ignore the spawn-settle thump
const HIT_COOLDOWN_TICKS := 18      # one crash = one damage event, not the
	# dozens of body_hit manifold updates a single pileup emits

## Body paint. Set before the rig enters the tree (it builds on _ready).
@export var paint := Color(0.75, 0.16, 0.13)
## Anti-roll / upright assist joint on.
@export var assist := true
## Drive itself from the keyboard: ARROWS throttle/steer, X handbrake.
@export var input_enabled := false
## Also accept W A S D (only sane when no fly-camera owns those keys).
@export var input_wasd := false
## Jointed bodywork (hood, trunk, doors, roof, bumpers) that tears off.
@export var body_panels := true
## Optional detailed body shell: the basename of a .glb under
## lib/fx/models/vehicles/ (see tools/fetch_car_assets.py — Quaternius'
## CC0 Cars Bundle). The model is scaled onto the physics chassis and its
## baked-in wheel nodes are hidden (the rig's own wheels do the rolling).
## "" — or a missing file — keeps the procedural box body.
@export var model := ""

## A solid contact registered on the chassis (approach speed in m/s).
signal hit_taken(speed: float)
## A weld gave way: a panel (or a whole wheel) just left the car.
signal part_lost(part: Box3DBody)
## Damage passed WRECK_DAMAGE: engine dead, welds loosened.
signal car_wrecked

var chassis: Box3DBody
var wheels: Array[Box3DBody] = []          # FL, FR, RL, RR
var joints: Array[Box3DWheelJoint] = []    # FL, FR, RL, RR
var suspension_hertz := SUSPENSION_HERTZ
var suspension_damping := SUSPENSION_DAMPING
## Physics wheel radius. A model car overrides this to its own wheels' radius
## (set in _build_model_split) so the rim fits its arch and meets the ground;
## procedural cars keep WHEEL_RADIUS.
var _wheel_radius := WHEEL_RADIUS
var damage := 0.0
var wrecked := false
## Highest weld constraint force seen (N) — tuning/diagnostics readout.
var peak_weld_force := 0.0
var _assist: Box3DParallelJoint
var _rest_local: Array[Vector3] = []  # wheel rest positions in chassis space
# Breakable welds: {joint: Node, part: Box3DBody, threshold: float}.
var _welds: Array[Dictionary] = []
var _break_timer := 0.0
var _grace := SPAWN_GRACE_TICKS
var _hit_cooldown := 0


## Build a car under `world` at `at` (nose along the transform's +X).
## opts: color (body paint), assist (anti-roll, default true), input
## (self-driving keyboard control, default false), wasd (see input_wasd).
static func spawn(world: Box3DWorld, at: Transform3D,
		opts: Dictionary = {}) -> Node3D:
	var rig := _Self.new()
	rig.name = "CarRig"
	rig.transform = at
	rig.paint = opts.get("color", rig.paint)
	rig.assist = opts.get("assist", true)
	rig.input_enabled = opts.get("input", false)
	rig.input_wasd = opts.get("wasd", false)
	rig.body_panels = opts.get("panels", true)
	rig.model = opts.get("model", "")
	world.add_child(rig)  # _ready builds the car
	return rig


## Builds on entering the tree, so an instanced car.tscn placed under any
## Box3DWorld in the editor is a complete drivable car with zero code.
func _ready() -> void:
	if chassis == null:
		_build()


func _build() -> void:
	var at := Transform3D()  # rig-local; the rig node carries the placement
	chassis = Box3DBody.new()
	chassis.name = "Chassis"
	chassis.box_size = BODY_SIZE
	chassis.density = BODY_DENSITY
	chassis.friction = 0.4
	chassis.angular_damping = 0.1
	chassis.continuous = true  # a car at 30 m/s vs 0.35 m panels needs CCD
	chassis.contact_monitor = true  # body_hit drives the damage model
	chassis.transform = at.translated_local(Vector3(0, BODY_CENTER_Y, 0))
	# Cabin as a second collision shape: rollovers land on the greenhouse
	# instead of an invisible slab, and its mass sits where a cabin's does.
	var cabin := Box3DCollisionShape.new()
	cabin.box_size = CABIN_SIZE
	cabin.density = BODY_DENSITY * 0.28  # mostly glass and air
	cabin.friction = 0.4
	cabin.position = Vector3(-0.35, CABIN_LIFT, 0)
	chassis.add_child(cabin)
	add_child(chassis)
	_dress_chassis(paint)
	# Engine block and floorpan live low in a real car: drop the centre of
	# mass below the box centroid. Deferred — the solver body exists only
	# once the node has entered the running tree.
	_lower_com.call_deferred()

	# Wheels + wheel joints. Joint frame: local Y = suspension axis (chassis
	# up), local Z = axle — the identity basis of a +X-nosed car, rotated by
	# the spawn transform. Corners in FL, FR, RL, RR order — drive() indexes the
	# front pair [0,1] to steer and the rear pair [2,3] to drive.
	for corner in _wheel_corners():
		var front: bool = corner.x > 0.0
		var wheel := Box3DBody.new()
		wheel.name = ("F" if front else "R") + ("L" if corner.z > 0.0 else "R")
		wheel.shape_type = Box3DBody.SPHERE
		wheel.sphere_radius = _wheel_radius
		wheel.density = WHEEL_DENSITY
		wheel.friction = TIRE_FRICTION_FRONT if front else TIRE_FRICTION_REAR
		wheel.angular_damping = 0.0
		wheel.allow_fast_rotation = true
		wheel.transform = at.translated_local(corner)
		add_child(wheel)
		_dress_wheel(wheel)
		wheels.append(wheel)
		_rest_local.append(corner - Vector3(0, BODY_CENTER_Y, 0))

		var joint := Box3DWheelJoint.new()
		joint.name = wheel.name + "Joint"
		joint.suspension_hertz = suspension_hertz
		joint.suspension_damping = suspension_damping
		joint.suspension_limit_enabled = true
		joint.lower_suspension_limit = -SUSPENSION_TRAVEL
		joint.upper_suspension_limit = SUSPENSION_TRAVEL
		if front:
			joint.steering_enabled = true
			joint.steering_hertz = STEER_HERTZ
			joint.steering_damping = STEER_DAMPING
			joint.max_steering_torque = STEER_TORQUE
			joint.steering_limit_enabled = true
			joint.lower_steering_limit = -STEER_LOCK_LOW
			joint.upper_steering_limit = STEER_LOCK_LOW
		else:
			joint.spin_motor_enabled = true
			joint.max_spin_torque = ENGINE_DRAG_TORQUE
		# Body paths BEFORE add_child: the joint builds itself on READY.
		joint.body_a = NodePath("../Chassis")
		joint.body_b = NodePath("../" + wheel.name)
		joint.transform = at.translated_local(corner)
		add_child(joint)
		joints.append(joint)
		# Wheels can be ripped clean off — but only by crash-grade loads,
		# far beyond anything the suspension sees on jumps.
		_welds.append({joint = joint, part = wheel,
				threshold = WHEEL_BREAK_FORCE, fatigue = 0.0})

	if body_panels:
		_build_panels(at)

	# Damage bookkeeping rides the chassis' real contact events.
	chassis.body_hit.connect(_on_chassis_hit)

	if assist:
		_assist = Box3DParallelJoint.new()
		_assist.spring_hertz = ASSIST_HERTZ
		_assist.max_torque = ASSIST_MAX_TORQUE
		_assist.body_a = NodePath("../Chassis")
		# Parallel joint aligns joint-frame Z axes: point Z up, anchor to the
		# world (empty body_b) — an upright lean the car can still overpower.
		_assist.transform = chassis.transform \
				* Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
		add_child(_assist)


## The four wheel positions (rig-local), in FL, FR, RL, RR order so drive()'s
## front/rear indexing holds. A model car uses its own wheels' positions (set in
## _build_model_split) so the physics wheels sit in the model's arches; a
## procedural car uses the fixed sedan wheelbase/track.
func _wheel_corners() -> Array:
	if _wheel_pos.has("FL") and _wheel_pos.has("FR") \
			and _wheel_pos.has("RL") and _wheel_pos.has("RR"):
		return [_wheel_pos["FL"], _wheel_pos["FR"], _wheel_pos["RL"], _wheel_pos["RR"]]
	var r := _wheel_radius
	return [
		Vector3(WHEELBASE / 2.0, r, TRACK / 2.0),
		Vector3(WHEELBASE / 2.0, r, -TRACK / 2.0),
		Vector3(-WHEELBASE / 2.0, r, TRACK / 2.0),
		Vector3(-WHEELBASE / 2.0, r, -TRACK / 2.0),
	]


## The bodywork: each panel is a real rigid body welded on with a rigid
## Box3DFixedJoint. Bumpers soak hits before the chassis feels them (they
## are separate bodies, so bumper contacts never reach the damage model),
## doors shear off sideways, the hood flies in head-ons.
func _build_panels(at: Transform3D) -> void:
	for panel_name in PANEL_SPECS:
		var spec: Array = PANEL_SPECS[panel_name]
		var pos := Vector3(0, BODY_CENTER_Y, 0) + (spec[0] as Vector3)
		var panel := Box3DBody.new()
		panel.name = panel_name
		panel.box_size = spec[1]
		panel.density = spec[2]
		panel.friction = 0.5
		# Panels ARE the car's skin: almost every ram lands on one, so they
		# feed the damage model too (bumpers at a discount — that's their job).
		panel.contact_monitor = true
		var factor: float = BUMPER_DAMAGE_FACTOR \
				if panel_name.begins_with("Bumper") else 1.0
		panel.body_hit.connect(_on_panel_hit.bind(factor))
		panel.transform = at.translated_local(pos)
		add_child(panel)
		if _region_meshes.has(panel_name):
			# Model car: this panel wears its own slice of the car body.
			var mi := MeshInstance3D.new()
			mi.mesh = _region_meshes[panel_name]
			panel.add_child(mi)
		elif _region_meshes.is_empty():
			# Procedural car: the tinted box panel, as before.
			var shade: float = 0.85 if panel_name in ["Hood", "Trunk", "Roof"] else 1.0
			BoxVis.box(panel, spec[1],
					Color(paint.r * shade, paint.g * shade, paint.b * shade))
		# else: a model car whose region had no geometry — leave it undrawn
		# rather than reintroduce a clashing box.
		var weld := Box3DFixedJoint.new()
		weld.name = panel_name + "Weld"
		weld.linear_hertz = WELD_HERTZ
		weld.angular_hertz = WELD_HERTZ
		weld.body_a = NodePath("../Chassis")
		weld.body_b = NodePath("../" + panel_name)
		weld.transform = at.translated_local(pos)
		add_child(weld)
		_welds.append({joint = weld, part = panel,
				threshold = spec[3], fatigue = 0.0})


func _on_chassis_hit(other: Box3DBody, _point: Vector3, _normal: Vector3,
		approach_speed: float) -> void:
	_register_hit(other, approach_speed, 1.0)


func _on_panel_hit(other: Box3DBody, _point: Vector3, _normal: Vector3,
		approach_speed: float, factor: float) -> void:
	_register_hit(other, approach_speed, factor)


func _register_hit(other: Box3DBody, approach_speed: float, factor: float) -> void:
	if _grace > 0 or wrecked or _hit_cooldown > 0:
		return
	# A rattling own part (or torn-off debris still tagged to this rig)
	# banging around is wear and tear, not a hit.
	if other != null and is_instance_valid(other) and other.get_parent() == self:
		return
	var bite := maxf(0.0, approach_speed - HIT_SPEED_FLOOR)
	if bite <= 0.0:
		return
	_hit_cooldown = HIT_COOLDOWN_TICKS
	damage += bite * DAMAGE_PER_HIT_SPEED * factor
	hit_taken.emit(approach_speed)
	if damage >= WRECK_DAMAGE:
		_wreck()


func _wreck() -> void:
	wrecked = true
	# Engine dead: stop feeding the motors right now (a driver keeps calling
	# drive(), which no-ops the throttle from here on).
	for i in [2, 3]:
		if is_instance_valid(joints[i]):
			joints[i].spin_motor_speed = 0.0
			joints[i].max_spin_torque = ENGINE_DRAG_TORQUE
	# The anti-roll bar shears with everything else — wrecks flop.
	if _assist != null and is_instance_valid(_assist):
		_assist.queue_free()
		_assist = null
	BoxVis.recolor(chassis, Color(0.16, 0.14, 0.13))  # burnt-out shell
	car_wrecked.emit()


## Welds loosen as the car takes damage — late-derby cars shed panels at
## half the force a fresh car shrugs off. Never below 35%.
func _weld_scale() -> float:
	return clampf(1.0 - 0.6 * damage / WRECK_DAMAGE, 0.35, 1.0)


## Overload sweep, a few times a second: any weld pushed past its (damage-
## scaled) threshold lets go. The freed part keeps its visual and becomes
## ordinary debris; contacts with the chassis resume once the joint is gone.
func _check_welds() -> void:
	var loosen := _weld_scale()
	for i in range(_welds.size() - 1, -1, -1):
		var weld: Dictionary = _welds[i]
		var joint: Node = weld.joint
		if not is_instance_valid(joint):
			_welds.remove_at(i)
			continue
		var force: float = joint.get_constraint_force().length()
		peak_weld_force = maxf(peak_weld_force, force)
		var ratio: float = force / (weld.threshold * loosen)
		if ratio > 1.0:
			weld.fatigue += minf(ratio - 1.0, WELD_FATIGUE_SAMPLE_CAP)
			if weld.fatigue >= WELD_FATIGUE_BREAK:
				joint.queue_free()
				_welds.remove_at(i)
				part_lost.emit(weld.part)


func _lower_com() -> void:
	if chassis == null or not is_instance_valid(chassis):
		return
	chassis.set_mass_data(chassis.get_mass(), Vector3(0, -COM_DROP, 0))


## Per-tick upkeep (grace countdown, weld-overload sweep) plus optional
## self-driving: with input_enabled the rig polls the keyboard itself, so a
## dropped-in car needs no host code at all. Physical keys first so layouts
## don't matter; logical as fallback (matches the gyms' _key_down).
func _physics_process(delta: float) -> void:
	if chassis == null or not is_instance_valid(chassis):
		return
	if _grace > 0:
		_grace -= 1
	if _hit_cooldown > 0:
		_hit_cooldown -= 1
	if not _welds.is_empty():
		_break_timer += delta
		if _break_timer >= BREAK_CHECK_INTERVAL:
			_break_timer = 0.0
			_check_welds()
	if not input_enabled:
		return
	var throttle := 0.0
	if _key(KEY_UP) or (input_wasd and _key(KEY_W)):
		throttle += 1.0
	if _key(KEY_DOWN) or (input_wasd and _key(KEY_S)):
		throttle -= 1.0
	var steer := 0.0
	if _key(KEY_LEFT) or (input_wasd and _key(KEY_A)):
		steer += 1.0
	if _key(KEY_RIGHT) or (input_wasd and _key(KEY_D)):
		steer -= 1.0
	drive(throttle, steer, _key(KEY_X))


static func _key(code: Key) -> bool:
	return Input.is_physical_key_pressed(code) or Input.is_key_pressed(code)


## Feed once per physics tick. throttle -1..1 (negative = reverse / brake),
## steer -1..1 (positive = left), handbrake locks the rear wheels.
## A wrecked car is deaf to all of it; a torn-off wheel's joint is skipped.
func drive(throttle: float, steer: float, handbrake := false) -> void:
	if wrecked:
		throttle = 0.0
		steer = 0.0
		handbrake = false
	var v := speed()
	# Normalise the drivetrain to the wheel radius, so a car drives the same
	# whatever wheels its model wears: hold the LAUNCH FORCE (τ/r) and the TOP
	# GROUND SPEED (ω·r) at the WHEEL_RADIUS baseline. (Without this a big-wheeled
	# model launches sluggishly — less force per N·m — and tops out too fast.) The
	# power cap below is already force = P/v_ground, so it needs no adjustment.
	var drive_torque := DRIVE_TORQUE * _wheel_radius / WHEEL_RADIUS
	var top_spin := TOP_WHEEL_SPEED * WHEEL_RADIUS / _wheel_radius
	# Speed-sensitive lock, exactly like a driver easing off at speed.
	var t := clampf((absf(v) - WALK_SPEED) / (TOP_WHEEL_SPEED * WHEEL_RADIUS - WALK_SPEED), 0.0, 1.0)
	var lock := lerpf(STEER_LOCK_LOW, STEER_LOCK_HIGH, t)
	for i in [0, 1]:
		if is_instance_valid(joints[i]):
			joints[i].target_steering_angle = lock * clampf(steer, -1.0, 1.0)
	# Negative spin about the +Z axle rolls the car toward its +X nose.
	var rolling := -v / _wheel_radius  # spin that matches ground speed
	var margin := SLIP_MARGIN + SLIP_FRACTION * absf(rolling)
	for i in [2, 3]:
		if not is_instance_valid(joints[i]):
			continue
		if handbrake:
			joints[i].spin_motor_speed = 0.0
			joints[i].max_spin_torque = HANDBRAKE_TORQUE
		elif absf(throttle) > 0.01:
			# Traction control: chase the pedal, but never command more
			# than `margin` of slip past the current rolling speed. The
			# same clamp brakes progressively when the pedal opposes the
			# motion (target approaches rolling from the pedal's side).
			var want := -top_spin * clampf(throttle, -1.0, 1.0)
			if throttle > 0.0:
				want = maxf(want, rolling - margin)  # both spin negative
			else:
				want = minf(want, rolling + margin)
			joints[i].spin_motor_speed = want
			# Engine model: full torque off the line, power-limited once
			# rolling (τ = P/ω), so thrust tapers exactly like a real motor.
			var spin: float = maxf(absf(joints[i].get_spin_speed()), 8.0)
			joints[i].max_spin_torque = minf(drive_torque,
					ENGINE_POWER / 2.0 / spin)
		else:
			joints[i].spin_motor_speed = 0.0
			joints[i].max_spin_torque = ENGINE_DRAG_TORQUE


## Live retune of all four corners — springs and dampers take effect
## immediately (drive targets and tuning are hot-settable on wheel joints).
func set_suspension(hertz: float, damping: float) -> void:
	suspension_hertz = clampf(hertz, 0.5, 8.0)
	suspension_damping = clampf(damping, 0.05, 2.0)
	for joint in joints:
		if is_instance_valid(joint):
			joint.suspension_hertz = suspension_hertz
			joint.suspension_damping = suspension_damping


## Signed speed along the nose, m/s (forward positive).
func speed() -> float:
	if chassis == null or not is_instance_valid(chassis):
		return 0.0
	return chassis.get_linear_velocity().dot(chassis.global_transform.basis.x)


## Per-corner tire load in newtons (FL, FR, RL, RR), from the tires' live
## contact manifolds: the solver's normal impulse × tick rate, projected
## onto world up. This is the force the suspension spring is reacting, so
## it breathes over bumps and walks to the nose under braking. (The joint's
## get_constraint_force() is only the rigid part — it excludes the soft
## suspension spring, so it reads near zero at rest.)
func wheel_loads() -> Array[float]:
	var out: Array[float] = []
	var hz := float(Engine.physics_ticks_per_second)
	for wheel in wheels:
		var load := 0.0
		for contact in wheel.get_contact_data():
			var n: Vector3 = contact["normal"]  # points away from the tire
			load += contact["impulse"] * maxf(0.0, -n.y) * hz
		out.append(load)
	return out


## Suspension compression per corner in metres (positive = compressed):
## how far the wheel has risen in the chassis' frame from its as-built rest
## height. Bottoms out at +SUSPENSION_TRAVEL, tops out at -SUSPENSION_TRAVEL.
func wheel_travel() -> Array[float]:
	var out: Array[float] = []
	var inv := chassis.global_transform.affine_inverse()
	for i in wheels.size():
		var local := inv * wheels[i].global_position
		out.append(local.y - _rest_local[i].y)
	return out


func is_upright() -> bool:
	return chassis != null and is_instance_valid(chassis) \
			and chassis.global_transform.basis.y.dot(Vector3.UP) > 0.5


# --- Visuals: shared cached meshes via BoxVis where possible; the few car-
# specific pieces (tinted glass, tires) are cheap one-offs per car. ---

const VEHICLE_MODEL_DIR := "res://lib/fx/models/vehicles/"


## Basenames of every fetched vehicle .glb (empty until someone runs
## tools/fetch_car_assets.py and commits the models).
static func available_models() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(VEHICLE_MODEL_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		# In exported builds imported resources appear as "<name>.glb.remap".
		if f.ends_with(".glb") or f.ends_with(".glb.remap"):
			var base := f.trim_suffix(".remap").get_basename()
			if not out.has(base):
				out.append(base)
	out.sort()
	return out


## Per-model yaw fix-ups (radians), applied after the automatic length
## alignment, for any model whose nose ends up pointing backwards.
const MODEL_YAW := {}

## Above this body-triangle count a model is treated as SOLID: its whole body
## rides rigidly on the chassis instead of being sliced across the sedan tear-off
## panels. A detailed, non-sedan shell (e.g. a low sports car) scattered onto the
## sedan panels drifts on the soft welds — the panels sit at sedan heights, foul
## the low body and the ground, and the shell distorts. Low-poly sedans stay
## under this and keep their sliced, visibly-shedding bodywork; a solid model
## still carries the box panels as invisible damage colliders (derby unaffected).
const SOLID_BODY_TRIS := 6000

## Ratio (spread along the fitted axle ÷ the smaller spread across it) above
## which a corner's geometry isn't disc-like enough to trust an axle fit — a
## mis-split mesh, a stray body part. Real wheels in this pack measure
## 0.18-0.25; anything shapeless tends toward 1.0.
const WHEEL_DISC_RATIO := 0.55
## A fitted axle further off the rig's axle than this is a bad read rather than
## a crooked model, so that corner's rim is left exactly as authored.
const WHEEL_AXLE_MAX_TILT := 0.9  # rad, ~52°


# Built by _build_model_split(): region name ("Core" + each PANEL_SPECS key) →
# an ArrayMesh cut from the model, baked in that body's local space. Empty for
# a procedural (box) car. _dress_chassis fills it, _build_panels reads it.
var _region_meshes := {}
# Built alongside: physics corner (FL/FR/RL/RR) → an ArrayMesh of the model's
# OWN wheel, centred on that wheel body and scaled to WHEEL_RADIUS. _dress_wheel
# reads it; empty → the fallback sphere+spoke.
var _wheel_meshes := {}
# Physics corner → rig-local wheel position, taken from the model's own wheels so
# they land in the model's arches. Empty (procedural car) → the fixed sedan track.
var _wheel_pos := {}


## Slice the model's OWN body geometry into the rig's panel regions (plus the
## chassis "Core") so each tear-off body carries a real chunk of the car — the
## hood that flies off IS the model's hood, not a coloured box. Every collider,
## weld, mass and the whole damage model are the box rig underneath and are
## untouched: this only changes what is DRAWN, so the physics (and its tests)
## are byte-identical to the procedural car. Returns false (→ box fallback) if
## the model is missing or empty.
func _build_model_split() -> bool:
	_region_meshes.clear()
	_wheel_meshes.clear()
	var path := VEHICLE_MODEL_DIR + model + ".glb"
	if not ResourceLoader.exists(path):
		return false
	var scene: PackedScene = load(path)
	if scene == null:
		return false
	var root: Node3D = scene.instantiate()
	# Full extent (wheels included) for the vertical grounding; body-only (wheels
	# hidden) for the length scale and the horizontal centring.
	var full := _visible_aabb(root, Transform3D.IDENTITY)
	_hide_wheel_nodes(root)  # the model body is split; the wheels ride separately
	var aabb := _visible_aabb(root, Transform3D.IDENTITY)
	if aabb.size.length() < 0.01:
		root.free()
		return false
	# Same fit a whole shell would get: turn the length onto the rig's +X nose,
	# uniformly scale to the body footprint. (See MODEL_YAW / the +90° note — the
	# Quaternius pack models every car nose-toward +Z.)
	var yaw: float = MODEL_YAW.get(model, 0.0)
	if aabb.size.z > aabb.size.x:
		yaw += PI / 2.0
	var rot := Basis(Vector3.UP, yaw)
	var turned: AABB = Transform3D(rot, Vector3.ZERO) * aabb
	var s := BODY_SIZE.x * 1.05 / maxf(turned.size.x, 0.01)
	var center := turned.get_center()
	# Ground by the WHEELS, not the body: these models are authored wheels-on-
	# ground with the body riding ~0.17 m above. Grounding the body dropped its
	# belly to the floor and shoved the wheels up through the lower panels. The
	# +BODY_SETTLE_SAG lifts the shell to where the chassis actually rests once
	# the suspension loads (else the whole body sinks through the ground).
	var full_min_y: float = (Transform3D(rot, Vector3.ZERO) * full).position.y
	var off := Vector3(-center.x * s,
			-BODY_CENTER_Y + BODY_SETTLE_SAG - full_min_y * s, -center.z * s)
	# The fitted body's AABB in chassis-local space, for fractional carving
	# (adapts to each car's own proportions — a tall SUV vs a low sports car).
	var fmin := turned.position * s + off
	var fsize := turned.size * s

	var bodies := []
	_collect_body_meshes(root, Transform3D.IDENTITY, bodies)
	# Solid (detailed) bodies ride whole on the chassis; sedans get sliced.
	var body_tris := 0
	for entry in bodies:
		var m: Mesh = entry.mi.mesh
		for si in m.get_surface_count():
			var idx0: PackedInt32Array = m.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
			body_tris += idx0.size() / 3
	var solid := body_tris > SOLID_BODY_TRIS
	# region → source-surface-key → {v:Array[Vector3], n:Array[Vector3]}
	var acc := {}
	var mats := {}
	for entry in bodies:
		var mi: MeshInstance3D = entry.mi
		var mi_xf: Transform3D = entry.xf
		var mesh: Mesh = mi.mesh
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var key := str(mi.get_instance_id()) + ":" + str(si)
			mats[key] = mesh.surface_get_material(si)
			var has_n := norms.size() == verts.size()
			var i := 0
			while i + 2 < idx.size():
				var ia := idx[i]
				var ib := idx[i + 1]
				var ic := idx[i + 2]
				i += 3
				var pa := rot * (mi_xf * verts[ia]) * s + off
				var pb := rot * (mi_xf * verts[ib]) * s + off
				var pc := rot * (mi_xf * verts[ic]) * s + off
				var region: String = "Core" if solid \
						else _classify((pa + pb + pc) / 3.0, fmin, fsize)
				var na: Vector3
				var nb: Vector3
				var nc: Vector3
				if has_n:
					na = (rot * (mi_xf.basis * norms[ia])).normalized()
					nb = (rot * (mi_xf.basis * norms[ib])).normalized()
					nc = (rot * (mi_xf.basis * norms[ic])).normalized()
				else:
					na = (pb - pa).cross(pc - pa).normalized()
					nb = na
					nc = na
				if not acc.has(region):
					acc[region] = {}
				if not acc[region].has(key):
					acc[region][key] = {v = [], n = []}
				var bucket: Dictionary = acc[region][key]
				bucket.v.append(pa); bucket.v.append(pb); bucket.v.append(pc)
				bucket.n.append(na); bucket.n.append(nb); bucket.n.append(nc)

	for region in acc:
		# Bake each region relative to the body it will hang on: panels around
		# their own origin (PANEL_SPECS position), the Core around the chassis.
		var roff: Vector3 = Vector3.ZERO if region == "Core" \
				else PANEL_SPECS[region][0]
		var am := ArrayMesh.new()
		for key in acc[region]:
			var bucket: Dictionary = acc[region][key]
			var vv := PackedVector3Array()
			var nn := PackedVector3Array()
			vv.resize(bucket.v.size())
			nn.resize(bucket.n.size())
			for j in bucket.v.size():
				vv[j] = bucket.v[j] - roff
				nn[j] = bucket.n[j]
			var sarr := []
			sarr.resize(Mesh.ARRAY_MAX)
			sarr[Mesh.ARRAY_VERTEX] = vv
			sarr[Mesh.ARRAY_NORMAL] = nn
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarr)
			am.surface_set_material(am.get_surface_count() - 1, mats[key])
		_region_meshes[region] = am

	# --- Wheels: the model's own rims on the physics wheel bodies. They sit in
	# the arches the grounding just aligned; the sphere+spoke is only a fallback.
	var corners := {
		FL = Vector3(WHEELBASE / 2.0, WHEEL_RADIUS - BODY_CENTER_Y, TRACK / 2.0),
		FR = Vector3(WHEELBASE / 2.0, WHEEL_RADIUS - BODY_CENTER_Y, -TRACK / 2.0),
		RL = Vector3(-WHEELBASE / 2.0, WHEEL_RADIUS - BODY_CENTER_Y, TRACK / 2.0),
		RR = Vector3(-WHEELBASE / 2.0, WHEEL_RADIUS - BODY_CENTER_Y, -TRACK / 2.0),
	}
	var wnodes := []
	_collect_wheel_meshes(root, Transform3D.IDENTITY, wnodes)
	var wacc := {}  # corner → source-surface-key → {v:Array[Vector3], n:Array[Vector3]}
	var wmats := {}
	for entry in wnodes:
		var mi: MeshInstance3D = entry.mi
		var mi_xf: Transform3D = entry.xf
		var mesh: Mesh = mi.mesh
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var key := str(mi.get_instance_id()) + ":" + str(si)
			wmats[key] = mesh.surface_get_material(si)
			var has_n := norms.size() == verts.size()
			var i := 0
			while i + 2 < idx.size():
				var ia := idx[i]
				var ib := idx[i + 1]
				var ic := idx[i + 2]
				i += 3
				var pa := rot * (mi_xf * verts[ia]) * s + off
				var pb := rot * (mi_xf * verts[ib]) * s + off
				var pc := rot * (mi_xf * verts[ic]) * s + off
				# Assign by nearest corner — splits a combined rear-wheel mesh and
				# ignores the model's own L/R node naming.
				var corner := _nearest_corner((pa + pb + pc) / 3.0, corners)
				var na: Vector3
				var nb: Vector3
				var nc: Vector3
				if has_n:
					na = (rot * (mi_xf.basis * norms[ia])).normalized()
					nb = (rot * (mi_xf.basis * norms[ib])).normalized()
					nc = (rot * (mi_xf.basis * norms[ic])).normalized()
				else:
					na = (pb - pa).cross(pc - pa).normalized()
					nb = na
					nc = na
				if not wacc.has(corner):
					wacc[corner] = {}
				if not wacc[corner].has(key):
					wacc[corner][key] = {v = [], n = []}
				var wb: Dictionary = wacc[corner][key]
				wb.v.append(pa); wb.v.append(pb); wb.v.append(pc)
				wb.n.append(na); wb.n.append(nb); wb.n.append(nc)

	# Per-corner axis frame (true axle, hub, native radius), then one uniform
	# physics radius for all four.
	var winfo := {}
	var rsum := 0.0
	for corner in wacc:
		var frame := _fit_wheel_frame(wacc[corner])
		winfo[corner] = frame
		rsum += frame.r
	if not winfo.is_empty():
		# The grounding put the arches here; the physics wheels follow so they line
		# up. Bounded so a mis-measured model can't produce an absurd radius.
		_wheel_radius = clampf(rsum / winfo.size(), 0.22, 0.44)
	for corner in winfo:
		# Centre each rim on its hub, TURN IT ONTO THE RIG'S AXLE, and scale to the
		# shared physics radius. Record the hub's x/z so the physics wheel gets placed
		# at the model's own wheel — inside its arch — not the fixed sedan track
		# (_build).
		var hub: Vector3 = winfo[corner].hub
		var fix: Basis = winfo[corner].fix
		_wheel_pos[corner] = Vector3(hub.x, _wheel_radius, hub.z)
		var scl: float = _wheel_radius / maxf(winfo[corner].r, 0.01)
		var am := ArrayMesh.new()
		for key in wacc[corner]:
			var wb: Dictionary = wacc[corner][key]
			var vv := PackedVector3Array()
			var nn := PackedVector3Array()
			vv.resize(wb.v.size())
			nn.resize(wb.n.size())
			for j in wb.v.size():
				vv[j] = fix * (wb.v[j] - hub) * scl
				nn[j] = fix * wb.n[j]
			var sarr := []
			sarr.resize(Mesh.ARRAY_MAX)
			sarr[Mesh.ARRAY_VERTEX] = vv
			sarr[Mesh.ARRAY_NORMAL] = nn
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarr)
			am.surface_set_material(am.get_surface_count() - 1, wmats[key])
		_wheel_meshes[corner] = am

	# Mirror the wheels left-right (level each axle's track). A model's wheels are
	# never perfectly symmetric, and the ~1 cm crab that leaves drifts the car at
	# speed. Fore-aft (wheelbase) asymmetry is the model's real geometry — kept.
	if _wheel_pos.has("FL") and _wheel_pos.has("FR") \
			and _wheel_pos.has("RL") and _wheel_pos.has("RR"):
		var fl: Vector3 = _wheel_pos["FL"]
		var fr: Vector3 = _wheel_pos["FR"]
		var rl: Vector3 = _wheel_pos["RL"]
		var rr: Vector3 = _wheel_pos["RR"]
		var fx := (fl.x + fr.x) / 2.0
		var fz := (absf(fl.z) + absf(fr.z)) / 2.0
		var rx := (rl.x + rr.x) / 2.0
		var rz := (absf(rl.z) + absf(rr.z)) / 2.0
		_wheel_pos["FL"] = Vector3(fx, _wheel_radius, fz)
		_wheel_pos["FR"] = Vector3(fx, _wheel_radius, -fz)
		_wheel_pos["RL"] = Vector3(rx, _wheel_radius, rz)
		_wheel_pos["RR"] = Vector3(rx, _wheel_radius, -rz)

	root.free()
	return not _region_meshes.is_empty()


## A wheel corner's own axis frame, fitted from its accumulated triangles:
## {hub, r, fix}. `fix` is the rotation that turns the model's rim onto the rig's
## axle — identity when the model already authored it straight.
##
## Models don't always author their wheels pointing forward: the Khronos
## CarConcept ships with ~30° of STEERING LOCK baked into its front pair. Bolted
## on unchanged, such a rim rides a physics wheel that spins about the rig's Z
## while its own axis points 30° away — so rolling sweeps it around a cone and
## the tread edge swings ±0.2 m fore-and-aft every revolution. That is the front
## wheels "wiggling" as you drive, and no amount of re-centring fixes it: the
## hub was never the problem, the AXIS was. The physics wheel is a sphere, so
## straightening the geometry changes only what is DRAWN.
##
## The axle is the least-spread direction of the wheel's surface — a disc's
## thin way. It is measured from the AREA-weighted second moment of the
## triangles, not from the vertices: a rim's spokes carry most of the vertices
## and almost none of the surface, and plain vertex PCA swings several degrees
## with the tessellation (measured: 27° and 32° on a pair that are both 30°).
func _fit_wheel_frame(buckets: Dictionary) -> Dictionary:
	var sw := 0.0
	var sc := Vector3.ZERO                      # Σ area · centroid
	var sxx := 0.0
	var sxy := 0.0
	var sxz := 0.0
	var syy := 0.0
	var syz := 0.0
	var szz := 0.0
	for key in buckets:
		var v: Array = buckets[key].v           # a triangle soup, three at a time
		var j := 0
		while j + 2 < v.size():
			var a: Vector3 = v[j]
			var b: Vector3 = v[j + 1]
			var c: Vector3 = v[j + 2]
			j += 3
			var w := (b - a).cross(c - a).length() * 0.5
			if w <= 0.0:
				continue
			var p := (a + b + c) / 3.0
			sw += w
			sc += p * w
			sxx += w * p.x * p.x
			sxy += w * p.x * p.y
			sxz += w * p.x * p.z
			syy += w * p.y * p.y
			syz += w * p.y * p.z
			szz += w * p.z * p.z
	# The rig's own axle, and the frame a wheel that needs no correction gets.
	var axle := Vector3(0.0, 0.0, 1.0)
	var e1 := Vector3(1.0, 0.0, 0.0)
	var e2 := Vector3(0.0, 1.0, 0.0)
	if sw > 0.0:
		var m := sc / sw
		var m0 := Vector3(sxx - sw * m.x * m.x, sxy - sw * m.x * m.y,
				sxz - sw * m.x * m.z)
		var m1 := Vector3(m0.y, syy - sw * m.y * m.y, syz - sw * m.y * m.z)
		var m2 := Vector3(m0.z, m1.z, szz - sw * m.z * m.z)
		var fitted := _least_axis(m0, m1, m2)
		if fitted.z < 0.0:
			fitted = -fitted      # PCA gives a line, not a direction: take the
				# representative nearest the rig's axle, so the correction stays
				# a short turn and the rim's outboard face stays outboard
		var across := fitted.cross(Vector3.UP)
		if across.length() < 1e-3:
			across = fitted.cross(Vector3.RIGHT)
		across = across.normalized()
		var up := fitted.cross(across)
		# Trust the fit only if this really is a disc, and only if the correction
		# is a plausible one. Otherwise measure in the rig's frame, exactly as
		# before — a bad read must not be allowed to tip a good wheel over.
		var along := _spread(m0, m1, m2, fitted)
		var flat := minf(_spread(m0, m1, m2, across), _spread(m0, m1, m2, up))
		if along < WHEEL_DISC_RATIO * flat \
				and acos(clampf(fitted.z, -1.0, 1.0)) < WHEEL_AXLE_MAX_TILT:
			axle = fitted
			e1 = across
			e2 = up

	# Hub and radius from the TREAD (the outer ring) measured in that frame: the
	# tread is symmetric about the true rotation centre, while a brake caliper
	# skews the raw AABB on every axis.
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for key in buckets:
		for p in buckets[key].v:
			var l := Vector3(p.dot(e1), p.dot(e2), p.dot(axle))
			lo = lo.min(l)
			hi = hi.max(l)
	var cx := (lo.x + hi.x) / 2.0
	var cy := (lo.y + hi.y) / 2.0
	var r0: float = maxf(hi.x - lo.x, hi.y - lo.y) / 2.0
	var tlo := Vector3(INF, INF, INF)
	var thi := -tlo
	var found := false
	for key in buckets:
		for p in buckets[key].v:
			var l := Vector3(p.dot(e1), p.dot(e2), p.dot(axle))
			if Vector2(l.x - cx, l.y - cy).length() > 0.82 * r0:
				tlo = tlo.min(l)
				thi = thi.max(l)
				found = true
	var h: Vector3 = (tlo + thi) / 2.0 if found else (lo + hi) / 2.0
	var r: float = (maxf(thi.x - tlo.x, thi.y - tlo.y) / 2.0) if found else r0
	# Back out of the frame, then the minimal turn onto the rig's axle — minimal
	# so a rim that is already true comes back byte-for-byte as authored.
	var hub := e1 * h.x + e2 * h.y + axle * h.z
	var fix := Basis()
	var swing := axle.cross(Vector3(0.0, 0.0, 1.0))
	if swing.length() > 1e-6:
		fix = Basis(swing.normalized(), axle.angle_to(Vector3(0.0, 0.0, 1.0)))
	return {hub = hub, r = r, fix = fix}


## The least-spread direction of a symmetric 3×3 second-moment matrix (passed as
## its three rows), by power iteration on trace·I − M — whose DOMINANT
## eigenvector is M's smallest. Godot ships no eigensolver and this needs none;
## the sweeps below are an order of magnitude more than a disc requires.
static func _least_axis(m0: Vector3, m1: Vector3, m2: Vector3) -> Vector3:
	var trace := m0.x + m1.y + m2.z
	# Seeded on the rig's axle: a straight model is already the answer, and a
	# crooked one is a short walk from it.
	var v := Vector3(0.0, 0.0, 1.0)
	for _i in 40:
		var mv := Vector3(m0.dot(v), m1.dot(v), m2.dot(v))
		var next := v * trace - mv
		if next.length() < 1e-12:
			return v
		v = next.normalized()
	return v


## vᵀMv — how far the surface spreads along `v`, for the matrix given as rows.
static func _spread(m0: Vector3, m1: Vector3, m2: Vector3, v: Vector3) -> float:
	return v.dot(Vector3(m0.dot(v), m1.dot(v), m2.dot(v)))


## Gather every visible (non-wheel) body MeshInstance and its transform in the
## model root's space — hidden wheel nodes are skipped by the visibility test.
func _collect_body_meshes(node: Node, xf: Transform3D, out: Array) -> void:
	var t := xf
	if node is Node3D:
		if not (node as Node3D).visible:
			return
		t = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append({mi = node, xf = t})
	for child in node.get_children():
		_collect_body_meshes(child, t, out)


## Gather the model's wheel MeshInstances (by name) regardless of visibility —
## they are hidden for the body split, but we still want their geometry.
func _collect_wheel_meshes(node: Node, xf: Transform3D, out: Array) -> void:
	var t := xf
	if node is Node3D:
		t = xf * (node as Node3D).transform
	var n := node.name.to_lower()
	if (n.contains("wheel") or n.contains("tire") or n.contains("tyre")) \
			and node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append({mi = node, xf = t})
	for child in node.get_children():
		_collect_wheel_meshes(child, t, out)


## Nearest physics wheel corner to a point, by ground-plane (x, z) distance.
func _nearest_corner(c: Vector3, corners: Dictionary) -> String:
	var best := ""
	var bd := INF
	for k in corners:
		var t: Vector3 = corners[k]
		var d := (c.x - t.x) * (c.x - t.x) + (c.z - t.z) * (c.z - t.z)
		if d < bd:
			bd = d
			best = k
	return best


## Which tear-off region a triangle centroid (chassis-local) belongs to, as a
## fraction of the fitted body's own bounds so it adapts per car. +X is the
## nose, +Z is the left side. Order = precedence: the nose/tail caps first,
## then the roofline, then the front/rear decks, then the side doors, and the
## lower centre (rockers, floor, fenders) falls through to the chassis Core.
func _classify(c: Vector3, fmin: Vector3, fsize: Vector3) -> String:
	var fx := (c.x - fmin.x) / maxf(fsize.x, 0.001)
	var fy := (c.y - fmin.y) / maxf(fsize.y, 0.001)
	var fz := (c.z - fmin.z) / maxf(fsize.z, 0.001)
	if fx >= 0.88:
		return "BumperF"
	if fx <= 0.12:
		return "BumperR"
	if fy >= 0.60:
		return "Roof"
	if fx >= 0.58:
		return "Hood"
	if fx <= 0.40:
		return "Trunk"
	if fz >= 0.68:
		return "DoorL"
	if fz <= 0.32:
		return "DoorR"
	return "Core"


func _hide_wheel_nodes(node: Node) -> void:
	var n := node.name.to_lower()
	if node is Node3D and (n.contains("wheel") or n.contains("tire") or n.contains("tyre")):
		(node as Node3D).visible = false
		return
	for child in node.get_children():
		_hide_wheel_nodes(child)


func _visible_aabb(node: Node, xf: Transform3D) -> AABB:
	var t := xf
	if node is Node3D:
		if not (node as Node3D).visible:
			return AABB()
		t = xf * (node as Node3D).transform
	var box := AABB()
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		box = t * (node as MeshInstance3D).mesh.get_aabb()
	for child in node.get_children():
		var sub := _visible_aabb(child, t)
		if sub.size.length() > 0.0:
			box = box.merge(sub) if box.size.length() > 0.0 else sub
	return box


func _dress_chassis(body_color: Color) -> void:
	# A model car: draw the chassis with the model's "Core" slice (floor,
	# rockers, pillars, fenders — everything not a tear-off panel). The panels
	# get their own slices in _build_panels. Physics is the box rig regardless.
	if model != "" and _build_model_split():
		var core: ArrayMesh = _region_meshes.get("Core")
		if core != null:
			var mi := MeshInstance3D.new()
			mi.mesh = core
			chassis.add_child(mi)
		return
	BoxVis.box(chassis, BODY_SIZE, body_color)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.12, 0.16, 0.2)
	glass.metallic = 0.6
	glass.roughness = 0.15
	var cabin := MeshInstance3D.new()
	var cabin_mesh := BoxMesh.new()
	cabin_mesh.size = CABIN_SIZE
	cabin.mesh = cabin_mesh
	cabin.material_override = glass
	cabin.position = Vector3(-0.35, CABIN_LIFT, 0)
	chassis.add_child(cabin)
	# Headlight blocks so the nose reads at a glance.
	var lamp := StandardMaterial3D.new()
	lamp.albedo_color = Color(1.0, 0.98, 0.85)
	lamp.emission_enabled = true
	lamp.emission = Color(1.0, 0.95, 0.7)
	lamp.emission_energy_multiplier = 1.4
	for side in [-1.0, 1.0]:
		var light := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.06, 0.14, 0.34)
		light.mesh = lm
		light.material_override = lamp
		light.position = Vector3(BODY_SIZE.x / 2.0 + 0.02, 0.06, side * 0.6)
		chassis.add_child(light)


func _dress_wheel(wheel: Box3DBody) -> void:
	# A model car: the model's own rim, already centred/scaled onto this wheel.
	# It spins and travels with the wheel body, so suspension reads on it too.
	if _wheel_meshes.has(wheel.name):
		var rim := MeshInstance3D.new()
		rim.mesh = _wheel_meshes[wheel.name]
		wheel.add_child(rim)
		return
	var tire := StandardMaterial3D.new()
	tire.albedo_color = Color(0.09, 0.09, 0.1)
	tire.roughness = 0.9
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = _wheel_radius
	sphere.height = _wheel_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	mi.mesh = sphere
	mi.material_override = tire
	wheel.add_child(mi)
	# A bright spoke bar through the tire makes spin speed and wheel lock
	# (handbrake skids!) readable from the driver's seat.
	var spoke := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(_wheel_radius * 1.9, _wheel_radius * 0.22, _wheel_radius * 0.3)
	spoke.mesh = bar
	var hub := StandardMaterial3D.new()
	hub.albedo_color = Color(0.85, 0.82, 0.75)
	hub.metallic = 0.7
	hub.roughness = 0.35
	spoke.material_override = hub
	wheel.add_child(spoke)
