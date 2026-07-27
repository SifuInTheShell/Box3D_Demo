extends Box3DBody

## A solid wall panel: the unit buildings are assembled from (piers, sills,
## lintel bands, slabs). Reads as one rigid slab until something hits it
## faster than FRACTURE_SPEED; then it breaks into a grid of breakable bricks
## (breakable_block.gd), which can shatter further into fragments. Two
## fracture tiers keep buildings solid at rest but locally destructible.

const BoxVis := preload("res://lib/fx/box_visuals.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")
const FractureQueue := preload("res://lib/fracture_queue.gd")
const FractureFX := preload("res://lib/fx/fracture_fx.gd")

const FRACTURE_SPEED := 7.0  # m/s relative impact speed that cracks a panel
const MAX_BRICKS := 3000  # global cap: past this, panels stop crumbling
const SPAWN_GRACE_TICKS := 21  # contacts ignored this long after spawn (depenetration)

var panel_color := Color(0.84, 0.76, 0.66)
## World-triplanar facade texture: adjacent panels sample it continuously in
## world space, so a building reads as one solid surface without seams.
var facade_tex: Texture2D = null
## Per-instance threshold: fire weakening (and wood construction) lower it.
var fracture_speed := FRACTURE_SPEED
## Structural material: "masonry" (default) fractures normally; "steel" only
## yields to cutting charges / the torch (speed >= STEEL_CUT_SPEED) -- blasts
## and boreholes rattle it, debris bounces off; "wood" is set by wood_gen.
var material := "masonry"
## Wood panels register with the fire system and burn (fire_system.gd).
var flammable := false
var fire_moisture := 0.05
var fire_fuel_scale := 1.0

var _fractured := false
var _impact_speed := FRACTURE_SPEED
var _impact_local := Vector3.ZERO
var _born_tick := 0  # physics frame at spawn; gates the grace window
# (tick-based, not wall-clock: fracture gating must be deterministic)
var _base_fracture := 0.0
var _base_color := Color.WHITE
var _burn_tier := 0  # last applied char re-tint step, avoids material churn


func _init() -> void:
	contact_monitor = true


func _ready() -> void:
	add_to_group("panel")
	if flammable:
		add_to_group("flammable")
	_base_fracture = fracture_speed
	_base_color = panel_color
	_born_tick = Engine.get_physics_frames()
	# NB: the rebuilt binding exposes body_hit (real approach speed + contact
	# point), but the structural fracture thresholds are calibrated to this
	# velocity-diff estimate -- swapping in the lower normal-approach speed
	# under-fractures and leaves too much of the structure standing.
	# Adopting body_hit here is a dedicated re-calibration pass.
	body_entered.connect(_on_body_entered)
	BoxVis.box(self, box_size, panel_color, true, facade_tex)


## Fuel description for the fire system (FireSim.add_item).
func fire_profile() -> Dictionary:
	return {"half": box_size * 0.5, "moisture": fire_moisture,
			"fuel_scale": fire_fuel_scale}


## Fire system tick while burning: char darkens the panel in steps, the
## residual strength scales the fracture threshold, and past the failure
## point the member gives way on its own (charred collapse, gentle scatter).
func set_burn(char_frac: float, burn_strength: float) -> void:
	if _fractured:
		return
	var tier := int(char_frac * 4.0)
	if tier != _burn_tier:
		_burn_tier = tier
		panel_color = _base_color.darkened(clampf(char_frac, 0.0, 1.0) * 0.75)
		BoxVis.recolor(self, panel_color, facade_tex)
	fracture_speed = _base_fracture * clampf(burn_strength, 0.3, 1.0)
	if burn_strength < 0.32:
		_fractured = true
		_impact_speed = FRACTURE_SPEED * 0.9
		_impact_local = Vector3.ZERO
		FractureQueue.enqueue(get_tree(), _shatter)


## Fully consumed by fire: most of the mass is gone -- a few charred stubs
## drop out of the ash cloud instead of a full debris field.
func burned_out() -> void:
	if _fractured or not is_inside_tree():
		queue_free()
		return
	_fractured = true
	var parent: Node = get_parent()
	while parent != null and not parent is Box3DWorld:
		parent = parent.get_parent()
	if parent == null:
		parent = get_parent()
	var rng := BreakableBlock.shared_rng()
	var xf := global_transform
	var char_color := _base_color.darkened(0.85)
	for i in 3:
		var frac_size: Vector3 = box_size * rng.randf_range(0.16, 0.3)
		var off := Vector3(
				(rng.randf() - 0.5) * box_size.x * 0.6,
				(rng.randf() - 0.5) * box_size.y * 0.6,
				(rng.randf() - 0.5) * box_size.z * 0.6)
		BreakableBlock.spawn_piece(parent, self, Transform3D(xf.basis, xf * off),
				frac_size, char_color, 99, get_linear_velocity(),
				get_angular_velocity())
	FractureFX.burst(parent, xf.origin, box_size.length() * 0.45, char_color)
	queue_free()


## Called by ExplosionFX's blast sweep: shatter as if hit at `speed` from the
## blast point. Blasts crack panels easier than contacts (0.7x threshold) --
## a pressure wave, not a poke.
const STEEL_CUT_SPEED := 24.0

func blast_fracture(at: Vector3, speed: float) -> void:
	if _fractured or speed < fracture_speed * 0.7:
		return
	if material == "steel" and speed < STEEL_CUT_SPEED:
		return  # only a cutting charge or the torch severs steel
	_fractured = true
	_impact_speed = speed
	_impact_local = to_local(at).clamp(-box_size * 0.5, box_size * 0.5)
	FractureQueue.enqueue(get_tree(), _shatter)


func _on_body_entered(other: Box3DBody) -> void:
	if _fractured or other == null or not is_instance_valid(other):
		return
	# Spawn grace: a panel placed snug against its neighbours must not be
	# self-destructed by the frame-1 depenetration impulse (see breakable_block).
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	var rel := (other.get_linear_velocity() - get_linear_velocity()).length()
	if rel < fracture_speed:
		return
	if material == "steel" and rel < STEEL_CUT_SPEED:
		return  # debris bounces off steel members
	_fractured = true
	_impact_speed = rel
	# Best available impact locus: our closest point to the other body.
	_impact_local = to_local(other.global_position).clamp(-box_size * 0.5, box_size * 0.5)
	# Queued, not deferred: the queue spreads mass fracturing over frames so
	# a city-wide blast cannot spawn every brick in a single frame.
	FractureQueue.enqueue(get_tree(), _shatter)


func _shatter() -> void:
	if not is_inside_tree():
		return
	if get_tree().get_nodes_in_group("block").size() >= MAX_BRICKS:
		return
	# Big uneven chunks: recursive random cuts, finer around the impact point,
	# more pieces the harder the hit. The wall thickness axis is too thin to
	# cut at this tier, so pieces read as broken masonry slabs.
	var rng := BreakableBlock.shared_rng()
	var budget := clampi(4 + int((_impact_speed - FRACTURE_SPEED) * 0.5), 4, 10)
	var pieces: Array = BreakableBlock.split_box_uneven(
			box_size, budget, 0.25, rng, _impact_local)
	# Pieces always spawn under the WORLD: spawn_piece transforms are world
	# space, and a panel may live under a rotated parent (the crane's slewing
	# rig), which would double-transform every piece.
	var parent: Node = get_parent()
	while parent != null and not parent is Box3DWorld:
		parent = parent.get_parent()
	if parent == null:
		parent = get_parent()
	var xf := global_transform
	var vel := get_linear_velocity()
	var ang := get_angular_velocity()
	var scatter := 0.4 + _impact_speed * 0.05
	for piece in pieces:
		var off: Vector3 = piece.off
		BreakableBlock.spawn_piece(parent, self, Transform3D(xf.basis, xf * off),
				piece.size, panel_color.darkened(rng.randf() * 0.12), 1,
				vel + ang.cross(xf.basis * off)
				+ Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * scatter,
				ang, facade_tex)
	FractureFX.burst(parent, xf.origin, box_size.length() * 0.6, panel_color)
	queue_free()
