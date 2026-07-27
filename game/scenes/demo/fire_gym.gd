extends "res://gyms/destruction/destruction_gym.gd"

## Fire gym (key 8): the propagation test range. A timber district built to
## verify every fire behavior by eye:
##
##   - cabin A and cabin B joined by a board fence -- torch the far fence end
##     and watch the fire line walk the fence and jump into cabin A, climb its
##     siding (upward bias) and hand itself to cabin B
##   - cabin C across a wide firebreak gap -- must NOT catch from the row
##   - a lumber yard (plank stacks, log piles) -- dense fuel, big pyre
##   - a brick control house between the rows -- masonry never ignites
##   - street trees -- crown fires, charred collapse
##
##   F  torch the surface under the cursor (hand ignition)
##   G  water burst under the cursor (douse; under-dousing leaves smoldering
##      coals that rekindle -- soak them to kill them)
##   V  toggle wind 0 <-> 5 m/s +X (watch spread lean downwind)
##
## Explosions and demolition charges also start fires here (blast heat +
## lingering pyres radiate into the sim), so RMB works as a fire starter.

const WoodGen := preload("res://lib/gen/wood_gen.gd")
const BuildingGen2 := preload("res://lib/gen/building_gen.gd")
const Scenery2 := preload("res://lib/gen/scenery.gd")
const GlassPane2 := preload("res://lib/glass/glass_pane.gd")
const BrickTex3 = preload("res://lib/fx/textures/facades/brick.jpg")

const WIND := Vector3(5.0, 0.0, 0.0)

# Wind is on by default now (base gym); V just flips the range calm <-> gusty.
var _windy := true
var _fire_label: Label


func _ready() -> void:
	super()
	_pivot.position = Vector3(0.0, 3.0, 0.0)
	_distance = 34.0
	_pitch = -0.3
	_update_camera()


func _ground_size() -> float:
	return 90.0


func _target_extent() -> float:
	return 16.0


## Plant the windsock beside the timber row, not out at the ground edge -- the
## fire range is a small cluster on a big 90 m ground, so the default corner
## sits it far from everything.
func _windsock_pos() -> Vector3:
	return Vector3(9.0, 0.0, -6.5)


func _build_structures() -> void:
	_rng.seed = 0xF12E
	# The connected row: cabin A -- fence -- cabin B (the fire bridge).
	WoodGen.cabin(_world, Vector3(-9.0, 0.0, 0.0), 5.0, 4.2, _rng)
	WoodGen.cabin(_world, Vector3(0.5, 0.0, 0.0), 5.5, 4.6, _rng)
	WoodGen.fence(_world, Vector3(-6.4, 0.0, 0.6), Vector3(-2.4, 0.0, 0.6), _rng)
	# The firebreak: cabin C sits 8+ m from the row and must survive it.
	WoodGen.cabin(_world, Vector3(13.5, 0.0, 0.0), 5.0, 4.2, _rng)
	# A long test fence running away from the row: the propagation stopwatch.
	WoodGen.fence(_world, Vector3(-9.0, 0.0, 6.0), Vector3(9.0, 0.0, 6.0), _rng)
	# The brick control house: masonry between the fuels, never ignites.
	BuildingGen2.build(_world, Vector3(2.0, 0.0, -10.0), 6.0, 5.0, 2,
			Color(1.0, 1.0, 1.0), BrickTex3, _rng)
	# The lumber yard.
	WoodGen.lumber_stack(_world, Vector3(-12.0, 0.0, -9.0), _rng)
	WoodGen.lumber_stack(_world, Vector3(-9.5, 0.0, -11.0), _rng)
	WoodGen.log_pile(_world, Vector3(-12.5, 0.0, -12.5), _rng)
	WoodGen.log_pile(_world, Vector3(-8.0, 0.0, -13.5), _rng)
	# Street trees: two near the row (crown-fire feed), one isolated.
	Scenery2.tree(_world, Vector3(-4.5, 0.0, 3.2), _rng)
	Scenery2.tree(_world, Vector3(4.8, 0.0, 2.6), _rng)
	Scenery2.tree(_world, Vector3(15.0, 0.0, 8.0), _rng)
	# Glass rack: free-standing panes for point-blank shatter tests (shoot
	# one, blast near another -- the ledger counts them as neutral), plus a
	# pane beside the log pile that pops thermally once the pile burns.
	for i in 4:
		var pane := GlassPane2.new()
		pane.box_size = Vector3(1.2, 0.9, 0.05)
		pane.position = Vector3(-3.0 + i * 1.8, 0.45, -5.5)
		pane.rotation.y = 0.12 * (i - 1.5)
		_world.add_child(pane)
	var firepane := GlassPane2.new()
	firepane.box_size = Vector3(1.2, 0.9, 0.05)
	firepane.position = Vector3(-10.3, 0.45, -13.2)
	_world.add_child(firepane)
	# Asphalt path so the range reads as a place.
	Scenery2.road(_world, Vector3(0.0, 0.0, 3.6), Vector2(44.0, 4.0), true)


func _build_hud() -> void:
	super()
	var layer: CanvasLayer = _stats.get_parent()
	_fire_label = Label.new()
	_fire_label.text = "FIRE RANGE:  F torch cursor | G douse cursor | V wind on/off | RMB blasts start fires + break glass"
	_fire_label.position = Vector2(12, 104)
	_fire_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	_style_label(_fire_label)
	layer.add_child(_fire_label)


func _extra_key(code: int) -> void:
	match code:
		# F (torch) is handled by the base gym so every gym can ignite; the
		# fire range adds douse and wind on top.
		KEY_G:
			var at := _cursor_point()
			if at != Vector3.INF:
				_fire.douse_at(at, 3.0, 0.8)
		KEY_V:
			# Wind is already live (base-gym default). V flips the range
			# between a stiff gusty 5 m/s and dead calm to compare spread.
			_windy = not _windy
			var ws := get_tree().get_first_node_in_group("wind_system")
			if ws != null:
				ws.set_base(WIND if _windy else Vector3.ZERO)
			_fire_label.text = "FIRE RANGE:  F torch | G douse | V wind (%s) | RMB blasts start fires too" \
					% ("5 m/s +X, gusty" if _windy else "calm")


