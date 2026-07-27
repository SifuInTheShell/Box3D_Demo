extends "res://gyms/destruction/destruction_gym.gd"

## City gym: the heavier stress test. A grid of diverse panel-built buildings
## (see building_gen.gd) replaces the tower: slim towers, low houses and
## mid-rise blocks with varied facades, roofs, chimneys and parapets, plus
## crate stacks in the streets. The far row is an industrial district --
## factories, smokestacks, water towers (see industrial_gen.gd) -- and a
## concrete highway viaduct runs past the near edge of town. Buildings are
## solid wall panels that crack into bricks, which shatter into fragments --
## the scene starts at a few hundred bodies and climbs into the thousands
## as you level it.
##
## Scenario keys (handled by destruction_gym): 1 tower gym, 2 landmark
## park, 3 city (re-press toggles medium <-> large), 4 fire.

const BuildingGen := preload("res://lib/gen/building_gen.gd")
const IndustrialGen := preload("res://lib/gen/industrial_gen.gd")
const LandmarkGen := preload("res://lib/gen/landmark_gen.gd")
const Scenery := preload("res://lib/gen/scenery.gd")
const WaterFX := preload("res://lib/water/water_fx.gd")
const WoodGen := preload("res://lib/gen/wood_gen.gd")
const SiteProps := preload("res://lib/gen/site_props.gd")
const Ragdoll := preload("res://lib/bodies/human_ragdoll.gd")
const AmbientLife := preload("res://lib/ambient/ambient_life.gd")
const BirdSwarm := preload("res://lib/ambient/bird_swarm.gd")

const SPACING := 15.0

const PlasterTex = preload("res://lib/fx/textures/facades/plaster.jpg")
const BrickTex = preload("res://lib/fx/textures/facades/brick.jpg")
const ConcreteTex = preload("res://lib/fx/textures/facades/concrete.jpg")

# Facade styles: CC0 material photo (ambientCG) x light tint. The texture
# carries the detail, so tints stay near white.
const STYLES := [
	{"tint": Color(1.0, 0.95, 0.85), "tex": PlasterTex},  # warm plaster
	{"tint": Color(0.95, 0.86, 0.72), "tex": PlasterTex},  # tan plaster
	{"tint": Color(1.0, 1.0, 1.0), "tex": BrickTex},  # red brick
	{"tint": Color(0.92, 0.92, 0.95), "tex": ConcreteTex},  # concrete
	{"tint": Color(0.85, 0.9, 1.0), "tex": PlasterTex},  # cool plaster
	{"tint": Color(0.95, 0.82, 0.78), "tex": BrickTex},  # washed brick
	{"tint": Color(0.99, 0.98, 0.94), "tex": PlasterTex},  # white plaster
	{"tint": Color(0.82, 0.84, 0.86), "tex": ConcreteTex},  # gray concrete
]

## Persists across scene reloads so re-pressing key 3 can resize the city.
static var grid_size := 3
## Key 2: replace the city with the famous-landmarks park.
static var landmark_mode := false


func _ready() -> void:
	super()
	_pivot.position.y = 9.0 if landmark_mode else 5.0
	_distance = 72.0 if landmark_mode else clampf(14.0 * grid_size, 30.0, 60.0)
	_pitch = -0.35
	_update_camera()


## Buildings reach out to (grid-1)*SPACING/2 plus ~9 m of footprint; debris
## flies a good 25 m past that. Scale the slab so nothing rains off the edge.
func _ground_size() -> float:
	if landmark_mode:
		return 160.0
	return (grid_size - 1) * SPACING + 70.0


func _target_extent() -> float:
	if landmark_mode:
		return 45.0
	return (grid_size - 1) * SPACING * 0.5 + 4.0


## The landmark park's pyramid (30 m base centred at x32,z26) sits right where
## the default corner windsock lands -- planting it under the stones. In that
## mode stand it in the open green out front instead.
func _windsock_pos() -> Vector3:
	if landmark_mode:
		return Vector3(14.0, 0.0, -2.0)
	return super()


func _build_structures() -> void:
	if landmark_mode:
		_build_landmark_park()
		return
	_rng.seed = 0xB0C5 + grid_size  # deterministic city per size
	var centers: Array[Vector3] = []
	var roofs: Array = []  # residential roof height per lot; -1 = no perch
	var half := grid_size >> 1
	var indus_row := grid_size - half - 1  # far row = industrial district
	var idx := 0
	var indus_idx := 0
	for gx in range(-half, grid_size - half):
		for gz in range(-half, grid_size - half):
			var pos := Vector3(
				gx * SPACING + _rng.randf_range(-0.8, 0.8), 0.0,
				gz * SPACING + _rng.randf_range(-0.8, 0.8))
			if gz == indus_row:
				_build_industrial_lot(pos, indus_idx)
				indus_idx += 1
				roofs.append(-1.0)
			else:
				roofs.append(_build_residential_lot(pos, idx))
			centers.append(pos)
			idx += 1
	# The highway viaduct runs past the near edge of town, parallel to the
	# first building row -- far enough out that no debris arc reaches it.
	IndustrialGen.add_viaduct(_world,
			Vector3(0.0, 0.0, -(half * SPACING + 9.0)),
			(grid_size - 1) * SPACING + 26.0, _rng)
	# One wrecking crane on the staging ground past the industrial district,
	# jib aimed at town: slew (G/H), trolley (J/K) and hoist (PgUp/PgDn)
	# bring the ball to the first row, arrows pump the swing.
	IndustrialGen.add_wrecking_crane(_world,
			Vector3(_rng.randf_range(-2.0, 2.0), 0.0,
					indus_row * SPACING + 18.0), PI / 2.0, _rng)
	_scatter_crates(centers)
	_dress_city(centers, half)
	_scatter_props(centers, half)
	_scatter_birds(centers, roofs)


## A cosmetic bird flock perched on the rooftops (procedural MultiMesh --
## bird_flock.gd -- no downloaded asset, so the demo stays asset-clean). Birds
## ride the wind and scatter well past any blast: explosion_fx broadcasts to the
## "ambient_life" group, which AmbientLife joins on attach. Strictly visual --
## no bodies, no physics, no effect on settle/determinism.
func _scatter_birds(centers: Array[Vector3], roofs: Array) -> void:
	if centers.is_empty():
		return
	var brng := RandomNumberGenerator.new()
	brng.seed = 0xB12D5 + grid_size
	var perches: Array = []
	for i in centers.size():
		var rh: float = roofs[i]
		if rh <= 0.0:
			continue  # industrial lot: no rooftop perch
		var c: Vector3 = centers[i]
		# perch points sitting ON the roof, kept inside the roof footprint
		perches.append(c + Vector3(brng.randf_range(-1.6, 1.6), rh + 0.05,
				brng.randf_range(-1.6, 1.6)))
		if brng.randf() < 0.7:
			perches.append(c + Vector3(brng.randf_range(-1.6, 1.6), rh + 0.05,
					brng.randf_range(-1.6, 1.6)))
	if perches.is_empty():
		return
	AmbientLife.attach(_world, {
		"birds": clampi(perches.size() * 2, 10, 34),
		"perches": perches,
		"ambience": "",
	}, 0xB12D5 + grid_size)
	# A low swarm wheeling over the whole town, cruising and leaning downwind.
	var span := grid_size * SPACING * 0.5
	BirdSwarm.attach(_world, Vector3(0.0, 16.0 + span * 0.1, 0.0),
			clampi(grid_size * grid_size * 9, 60, 130), span + 7.0,
			0x5A11 + grid_size)


## Asphalt streets on the building-row grid lines plus fir trees along the
## curbs (clear of building footprints) -- a town, not a demo slab.
func _dress_city(centers: Array[Vector3], half: int) -> void:
	var ext := (grid_size - 1) * SPACING * 0.5 + 14.0
	for i in range(-half, grid_size - half - 1):
		var c := (i + 0.5) * SPACING
		Scenery.road(_world, Vector3(0.0, 0.0, c), Vector2(ext * 2.0, 4.6), true)
		Scenery.road(_world, Vector3(c, 0.0, 0.0), Vector2(ext * 2.0, 4.6), false)
	Scenery.road(_world, Vector3(0.0, 0.0, -(half * SPACING + 9.0)),
			Vector2(ext * 2.0 + 26.0, 7.0), true)
	for i in range(-half, grid_size - half - 1):
		var cz := (i + 0.5) * SPACING
		for side in [-1.0, 1.0]:
			var x := -ext
			while x < ext:
				x += _rng.randf_range(6.5, 11.0)
				if _rng.randf() > 0.6:
					continue
				var at := Vector3(x, 0.0, cz + side * 3.1)
				var blocked := false
				for b in centers:
					if Vector2(at.x - b.x, at.z - b.z).length() < 7.2:
						blocked = true
						break
				if not blocked:
					Scenery.tree(_world, at, _rng)


## Street furniture down the road CENTRELINES -- ~7.5 m from either building row,
## so a settling or toppling prop can never reach a wall and destabilise the city:
## primitive-built striped barriers, dumpsters, cone clusters and pallet stacks,
## plus two photoscanned Poly Haven props (a wooden crate and a fire hydrant), all
## Box3D bodies in group "prop" so a blast tosses them with the rest of the rubble.
## Plus a warning-tape cordon on the open ground out front.
func _scatter_props(centers: Array[Vector3], half: int) -> void:
	var ext := (grid_size - 1) * SPACING * 0.5 + 8.0
	for i in range(-half, grid_size - half - 1):
		var cz := (i + 0.5) * SPACING  # road centre = half a lot from either row
		var x := -ext + _rng.randf_range(0.0, 12.0)
		while x < ext:
			x += _rng.randf_range(13.0, 22.0)
			var at := Vector3(x, 0.0, cz)
			if _prop_blocked(at, centers, 6.0):
				continue
			var r := _rng.randf()
			if r < 0.20:
				SiteProps.barrier(_world, at, _rng.randf() * TAU)
			elif r < 0.38:
				SiteProps.dumpster(_world, at, _rng.randf() * TAU)
			elif r < 0.56:
				var cn := _rng.randi_range(2, 4)
				for k in cn:
					SiteProps.cone(_world, at + Vector3(
							(k - (cn - 1) * 0.5) * 0.7, 0.0,
							_rng.randf_range(-0.3, 0.3)), _rng)
			elif r < 0.72:
				SiteProps.pallet_stack(_world, at, _rng.randi_range(2, 3), _rng)
			elif r < 0.87:
				SiteProps.crate(_world, at, _rng)
			else:
				SiteProps.hydrant(_world, at, _rng.randf() * TAU)
	# Pedestrians dotted down the streets: each stands frozen until a blast or a
	# flung chunk of rubble reaches it, then ragdolls (human_ragdoll.gd). Also on the
	# road centrelines, so a settling building can't knock them into a cascade.
	var rows := maxi(grid_size - 1, 1)
	var people := clampi(grid_size * grid_size / 2, 4, 18)
	for n in people:
		var pi := _rng.randi_range(0, rows - 1) - half
		var at2 := Vector3(_rng.randf_range(-ext, ext), 0.0, (pi + 0.5) * SPACING)
		if not _prop_blocked(at2, centers, 5.5):
			Ragdoll.spawn(_world, at2, _rng, _rng.randf() * TAU)
	# A warning-tape cordon across the open ground in front of the town.
	var fz := -(half * SPACING + 6.0)
	SiteProps.tape_run(_world, Vector3(-6.0, 0.0, fz), Vector3(6.0, 0.0, fz))


func _prop_blocked(at: Vector3, centers: Array[Vector3], radius: float) -> bool:
	for c in centers:
		if Vector2(at.x - c.x, at.z - c.z).length() < radius:
			return true
	return false


## Builds one residential lot and returns its roof height (so birds perch on
## the actual roof, not a guessed altitude).
func _build_residential_lot(pos: Vector3, idx: int) -> float:
	var roll := _rng.randf()
	var w: float
	var d: float
	var stories: int
	if roll < 0.14:  # timber cabin lot: the city's flammable pockets
		WoodGen.cabin(_world, pos, _rng.randf_range(4.6, 5.8),
				_rng.randf_range(4.0, 5.0), _rng)
		WoodGen.fence(_world,
				pos + Vector3(-3.6, 0.0, 3.4), pos + Vector3(3.6, 0.0, 3.4), _rng)
		if _rng.randf() < 0.6:
			WoodGen.log_pile(_world, pos + Vector3(3.4, 0.0, -2.6), _rng)
		return 3.1  # cabin ridge
	if roll < 0.2:  # slim tower
		w = _rng.randf_range(4.6, 5.6)
		d = _rng.randf_range(4.4, 5.4)
		stories = _rng.randi_range(4, 5)
	elif roll < 0.5:  # low house
		w = _rng.randf_range(5.0, 6.5)
		d = _rng.randf_range(4.2, 5.6)
		stories = _rng.randi_range(1, 2)
	else:  # mid-rise block
		w = _rng.randf_range(6.0, 8.5)
		d = _rng.randf_range(4.8, 6.6)
		stories = _rng.randi_range(2, 3)
	var style: Dictionary = STYLES[idx % STYLES.size()]
	BuildingGen.build(_world, pos, w, d, stories, style.tint, style.tex, _rng)
	return stories * BuildingGen.STORY_H + 0.3  # roof slab top


## Landmark mode carves a real river channel where the flat slab was: two
## grass banks at ground level and a dark bed 3 m down, so the water has
## actual depth -- debris plunges in, drifts to the bed and slips under.
func _build_ground() -> void:
	if not landmark_mode:
		super()
		return
	var s := _ground_size()
	var north_d := s * 0.5 - 24.5
	var south_d := s * 0.5 - 7.5
	_ground_slab(Vector3(0, -0.5, -24.5 - north_d * 0.5),
			Vector3(s, 1, north_d), Color(0.75, 0.85, 0.65), true)
	_ground_slab(Vector3(0, -0.5, -7.5 + south_d * 0.5),
			Vector3(s, 1, south_d), Color(0.75, 0.85, 0.65), true)
	_ground_slab(Vector3(0, -3.5, -16.0), Vector3(s, 1, 17.0),
			Color(0.3, 0.28, 0.24), false)


## The famous-landmarks park: the Golden Gate spans a waterway up front,
## with Big Ben and Pisa on a tree-dotted green behind it and the Great
## Pyramid -- properly massive -- on its own sand apron to the east.
func _build_landmark_park() -> void:
	_rng.seed = 0x60D5
	LandmarkGen.add_golden_gate(_world, Vector3(0.0, 0.0, -16.0), _rng)
	LandmarkGen.add_big_ben(_world, Vector3(-30.0, 0.0, 18.0), _rng)
	LandmarkGen.add_pisa_tower(_world, Vector3(-8.0, 0.0, 22.0), _rng)
	LandmarkGen.add_pyramid(_world, Vector3(32.0, 0.0, 26.0), _rng)
	Scenery.water(_world, Vector3(0.0, 0.0, -16.0), Vector2(128.0, 17.0))
	# The water is wet: plunging debris splashes, drags and sinks away.
	WaterFX.zone(_world, Vector3(0.0, 0.05, -16.0), Vector2(128.0, 17.0))
	Scenery.sand(_world, Vector3(32.0, 0.0, 26.0), 25.0)
	for i in 16:
		var at := Vector3(_rng.randf_range(-48.0, 8.0), 0.0,
				_rng.randf_range(4.0, 44.0))
		if at.distance_to(Vector3(-30.0, 0.0, 18.0)) < 6.0 \
				or at.distance_to(Vector3(-8.0, 0.0, 22.0)) < 7.5:
			continue
		Scenery.tree(_world, at, _rng)


## One industrial-district lot. The first lot is always a factory so every
## city size gets at least one; after that the pool is weighted.
func _build_industrial_lot(pos: Vector3, indus_idx: int) -> void:
	var roll := _rng.randf()
	if indus_idx == 0 or roll < 0.4:
		IndustrialGen.add_factory(_world, pos, _rng)
	elif roll < 0.52:
		# Lumber yard: stacked sawn planks and log piles -- the industrial
		# district's fire hazard (and the fire system's dense-fuel test).
		WoodGen.lumber_stack(_world, pos + Vector3(-2.0, 0.0, -1.4), _rng)
		WoodGen.lumber_stack(_world, pos + Vector3(0.6, 0.0, 1.2), _rng)
		WoodGen.log_pile(_world, pos + Vector3(2.8, 0.0, -1.8), _rng)
		WoodGen.fence(_world,
				pos + Vector3(-4.2, 0.0, 3.2), pos + Vector3(4.2, 0.0, 3.2), _rng)
	elif roll < 0.62:
		IndustrialGen.add_water_tower(_world, pos, _rng)
	elif roll < 0.72:
		IndustrialGen.add_smokestack(_world, pos, _rng.randi_range(11, 14), _rng)
	elif roll < 0.85:
		IndustrialGen.add_silo_group(_world, pos, _rng)
	else:  # long low brick warehouse
		BuildingGen.build(_world, pos, _rng.randf_range(8.5, 10.0),
				_rng.randf_range(5.5, 6.5), 1,
				Color(0.9, 0.78, 0.72), BrickTex, _rng)


## Street clutter: crate stacks in the gaps between buildings.
func _scatter_crates(centers: Array[Vector3]) -> void:
	var extent := (grid_size - 1) * SPACING * 0.5 + 4.0
	var wanted := ((grid_size * grid_size) >> 1) + 2
	var placed := 0
	var attempts := 0
	while placed < wanted and attempts < 80:
		attempts += 1
		var p := Vector3(
			_rng.randf_range(-extent, extent), 0.0, _rng.randf_range(-extent, extent))
		var blocked := false
		for c in centers:
			if Vector2(p.x - c.x, p.z - c.z).length() < 6.5:
				blocked = true
				break
		if blocked:
			continue
		placed += 1
		var stack_rot := _rng.randf_range(0.0, TAU)
		for i in _rng.randi_range(2, 4):
			var crate := BreakableBlock.new()
			crate.box_size = Vector3.ONE * 0.75
			crate.density = 0.5
			crate.friction = 0.7
			crate.block_color = Color(0.62, 0.47, 0.3).darkened(_rng.randf() * 0.15)
			crate.position = p + Vector3(
				_rng.randf_range(-0.08, 0.08), 0.375 + i * 0.75,
				_rng.randf_range(-0.08, 0.08))
			crate.rotation.y = stack_rot + _rng.randf_range(-0.15, 0.15)
			_world.add_child(crate)
