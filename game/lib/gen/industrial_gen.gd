extends RefCounted

## Generates industrial demolition targets out of solid Box3D wall panels:
## factory halls, brick smokestacks, steel water towers and multi-span
## concrete viaducts -- the structures real demolition crews get hired for.
## Same platform-construction rules as building_gen.gd: every panel rests on
## something below it, so structures stand rigid until blasted.

const WallPanel := preload("res://lib/bodies/wall_panel.gd")
const Drum := preload("res://lib/bodies/drum.gd")
const Cable := preload("res://lib/bodies/cable.gd")
const BoxVisuals := preload("res://lib/fx/box_visuals.gd")
const CraneRig := preload("res://lib/bodies/crane.gd")

const CorrugatedTex = preload("res://lib/fx/textures/facades/corrugated.jpg")
const MetalTex = preload("res://lib/fx/textures/facades/metal.jpg")
const BrickTex = preload("res://lib/fx/textures/facades/brick.jpg")
const ConcreteTex = preload("res://lib/fx/textures/facades/concrete.jpg")

const T := 0.35  # wall thickness
const DENSITY := 1.2
const FRICTION := 0.8


## A tall corrugated-steel hall: high pier walls with a wide gate up front, a
## clerestory window row above, flat roof with parapet and rooftop vents, and
## (usually) a brick smokestack attached at a back corner.
static func add_factory(parent: Node3D, origin: Vector3,
		rng: RandomNumberGenerator) -> int:
	var w := rng.randf_range(9.5, 11.0)
	var d := rng.randf_range(6.0, 7.0)
	var tint := Color(0.95, 1.0, 1.05).lerp(Color(1.05, 0.98, 0.88), rng.randf())
	var count := 0

	# Main hall row: tall piers, half-height sills, wide openings, one gate.
	var y := origin.y
	count += _wall_row(parent, Vector3(origin.x, y, origin.z + (d - T) * 0.5),
			w, true, 3.1, 1.15, 0.85, 1.7, 1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x, y, origin.z - (d - T) * 0.5),
			w, true, 3.1, 1.15, 0.85, 1.7, -1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x - (w - T) * 0.5, y, origin.z),
			d - 2.0 * T, false, 3.1, 1.15, 0.85, 1.7, -1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x + (w - T) * 0.5, y, origin.z),
			d - 2.0 * T, false, 3.1, 1.15, 0.85, 1.7, -1, tint, CorrugatedTex)
	y += 3.95

	# Clerestory row: short piers, all-window, lets light into the hall.
	count += _wall_row(parent, Vector3(origin.x, y, origin.z + (d - T) * 0.5),
			w, true, 1.4, 0.5, 0.6, 1.7, -1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x, y, origin.z - (d - T) * 0.5),
			w, true, 1.4, 0.5, 0.6, 1.7, -1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x - (w - T) * 0.5, y, origin.z),
			d - 2.0 * T, false, 1.4, 0.5, 0.6, 1.7, -1, tint, CorrugatedTex)
	count += _wall_row(parent, Vector3(origin.x + (w - T) * 0.5, y, origin.z),
			d - 2.0 * T, false, 1.4, 0.5, 0.6, 1.7, -1, tint, CorrugatedTex)
	y += 2.0

	# Flat roof, parapet, rooftop vents.
	var rw := w + 0.5
	var rd := d + 0.5
	_box(parent, Vector3(origin.x, y + 0.15, origin.z),
			Vector3(rw, 0.3, rd), Color(0.4, 0.42, 0.44), null)
	count += 1
	var roof_top := y + 0.3
	var pt := 0.18
	_box(parent, Vector3(origin.x, roof_top + 0.25, origin.z + (rd - pt) * 0.5),
			Vector3(rw, 0.5, pt), tint, CorrugatedTex)
	_box(parent, Vector3(origin.x, roof_top + 0.25, origin.z - (rd - pt) * 0.5),
			Vector3(rw, 0.5, pt), tint, CorrugatedTex)
	_box(parent, Vector3(origin.x - (rw - pt) * 0.5, roof_top + 0.25, origin.z),
			Vector3(pt, 0.5, rd - 2.0 * pt), tint, CorrugatedTex)
	_box(parent, Vector3(origin.x + (rw - pt) * 0.5, roof_top + 0.25, origin.z),
			Vector3(pt, 0.5, rd - 2.0 * pt), tint, CorrugatedTex)
	count += 4
	for i in rng.randi_range(2, 3):
		_box(parent, Vector3(
				origin.x + rng.randf_range(-0.32, 0.32) * w, roof_top + 0.4,
				origin.z + rng.randf_range(-0.25, 0.25) * d),
				Vector3(0.9, 0.8, 0.9), Color(0.55, 0.57, 0.6), MetalTex)
		count += 1

	if rng.randf() < 0.65:
		count += add_smokestack(parent, Vector3(
				origin.x - w * 0.5 - 1.6, origin.y, origin.z - d * 0.25),
				rng.randi_range(9, 12), rng)
	return count


## A masonry chimney, square or octagonal: stacked brick rings over a wider
## plinth, soot-darkened toward the top, capped with a collar ring. Ring
## orientation alternates like masonry bond. The classic fell-it-in-one-piece
## demolition target.
static func add_smokestack(parent: Node3D, origin: Vector3, rings: int,
		rng: RandomNumberGenerator) -> int:
	var tint := Color(0.95, 0.82, 0.78).lerp(Color(0.85, 0.75, 0.7), rng.randf())
	var soot := Color(0.38, 0.33, 0.3)
	var count := 0
	var y := origin.y
	for i in 2:  # plinth: two wider, shorter rings
		count += _ring(parent, Vector3(origin.x, y, origin.z), 2.6, 1.0,
				i % 2 == 1, tint, BrickTex)
		y += 1.0
	if rng.randf() < 0.45:
		# Round shaft: REAL cylinder drums on a transition slab. Felling it
		# breaks the stack into ring sections, just like film footage.
		_box(parent, Vector3(origin.x, y + 0.125, origin.z),
				Vector3(2.7, 0.25, 2.7), tint * 0.9, BrickTex)
		count += 1
		y += 0.25
		for i in rings:
			var ring_tint := tint.lerp(soot, 0.55 * float(i) / float(maxi(rings - 1, 1)))
			_drum(parent, Vector3(origin.x, y + 0.65, origin.z),
					1.2, 1.3, ring_tint, BrickTex)
			count += 1
			y += 1.3
		_drum(parent, Vector3(origin.x, y + 0.275, origin.z), 1.35, 0.55, soot, BrickTex)
		return count + 1
	for i in rings:
		var ring_tint := tint.lerp(soot, 0.55 * float(i) / float(maxi(rings - 1, 1)))
		count += _ring(parent, Vector3(origin.x, y, origin.z), 2.0, 1.3,
				i % 2 == 0, ring_tint, BrickTex)
		y += 1.3
	count += _ring(parent, Vector3(origin.x, y, origin.z), 2.3, 0.55,
			rings % 2 == 0, soot, BrickTex)
	return count


## A steel water tower: four stacked-segment legs, a platform slab, and a
## riveted plate tank with a lid. Blow the legs, watch it topple.
static func add_water_tower(parent: Node3D, origin: Vector3,
		rng: RandomNumberGenerator) -> int:
	var leg_tint := Color(0.75, 0.78, 0.82)  # dark steel lattice legs
	var tank_tint := Color(1.0, 1.0, 1.02).lerp(Color(1.05, 0.82, 0.62), rng.randf() * 0.7)
	var count := 0
	var leg_s := 0.55
	var seg_h := 2.3
	var c := 1.3  # leg centre offset from tower axis
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			for seg in 2:
				_box(parent, Vector3(origin.x + sx * c, origin.y + (seg + 0.5) * seg_h,
						origin.z + sz * c),
						Vector3(leg_s, seg_h, leg_s), leg_tint, MetalTex)
				count += 1
	var platform_y := origin.y + 2.0 * seg_h
	_box(parent, Vector3(origin.x, platform_y + 0.15, origin.z),
			Vector3(3.5, 0.3, 3.5), tank_tint * 0.9, CorrugatedTex)
	count += 1
	var tank_base := platform_y + 0.3
	if rng.randf() < 0.55:
		# Round tank: a REAL cylinder shell under a conical roof.
		_drum(parent, Vector3(origin.x, tank_base + 1.15, origin.z),
				1.8, 2.3, tank_tint, CorrugatedTex)
		_drum(parent, Vector3(origin.x, tank_base + 2.3 + 0.45, origin.z),
				1.95, 0.9, tank_tint * 0.85, CorrugatedTex, true)
		count += 2
		return count
	var s := 3.0
	var th := 2.2
	var tt := 0.25
	_box(parent, Vector3(origin.x, tank_base + th * 0.5, origin.z + (s - tt) * 0.5),
			Vector3(s, th, tt), tank_tint, CorrugatedTex)
	_box(parent, Vector3(origin.x, tank_base + th * 0.5, origin.z - (s - tt) * 0.5),
			Vector3(s, th, tt), tank_tint, CorrugatedTex)
	_box(parent, Vector3(origin.x - (s - tt) * 0.5, tank_base + th * 0.5, origin.z),
			Vector3(tt, th, s - 2.0 * tt), tank_tint, CorrugatedTex)
	_box(parent, Vector3(origin.x + (s - tt) * 0.5, tank_base + th * 0.5, origin.z),
			Vector3(tt, th, s - 2.0 * tt), tank_tint, CorrugatedTex)
	_box(parent, Vector3(origin.x, tank_base + th + 0.125, origin.z),
			Vector3(s + 0.2, 0.25, s + 0.2), tank_tint * 0.85, CorrugatedTex)
	count += 5
	return count


## A multi-span concrete viaduct running along X, centred on `center`:
## two-column pier bents with cap beams, deck slabs resting span-to-span,
## and side barriers. Drop a pier and both neighbouring spans come down.
static func add_viaduct(parent: Node3D, center: Vector3, length: float,
		_rng: RandomNumberGenerator) -> int:
	var span := 6.5
	var spans := maxi(int(length / span), 2)
	var start_x := center.x - spans * span * 0.5
	var col_h := 3.4
	var cap_h := 0.8
	var deck_w := 4.0
	var deck_t := 0.4
	var pier_tint := Color(0.85, 0.86, 0.88)
	var deck_tint := Color(0.62, 0.63, 0.65)
	var count := 0
	for i in spans + 1:
		var px := start_x + i * span
		for sz in [-1.0, 1.0]:
			_drum(parent, Vector3(px, center.y + col_h * 0.5, center.z + sz * 1.45),
					0.45, col_h, pier_tint, ConcreteTex)
			count += 1
		_box(parent, Vector3(px, center.y + col_h + cap_h * 0.5, center.z),
				Vector3(0.9, cap_h, deck_w + 0.4), pier_tint, ConcreteTex)
		count += 1
	var deck_y := center.y + col_h + cap_h + deck_t * 0.5
	for i in spans:
		var dx := start_x + (i + 0.5) * span
		_box(parent, Vector3(dx, deck_y, center.z),
				Vector3(span - 0.12, deck_t, deck_w), deck_tint, ConcreteTex)
		count += 1
		for sz in [-1.0, 1.0]:
			_box(parent, Vector3(dx, deck_y + deck_t * 0.5 + 0.26,
					center.z + sz * (deck_w * 0.5 - 0.09)),
					Vector3(span - 0.2, 0.52, 0.16), pier_tint, ConcreteTex)
			count += 1
	return count


## A tower crane with a slewing boom and a wrecking ball on a REAL jointed
## cable (cable.gd + crane.gd). The mast is static -- a swinging 26 t ball
## yanks any dynamic frame over through the cable (verified, twice) -- but
## still made of WallPanels, so demolition charges shatter it; crane.gd then
## drops the whole boom. G/H slew, J/K trolley, PgUp/PgDn hoist, arrows
## pump the ball. `yaw` aims the jib (0 = +X).
static func add_wrecking_crane(parent: Node3D, origin: Vector3, yaw: float,
		_rng: RandomNumberGenerator) -> int:
	var yellow := Color(1.05, 0.85, 0.3)  # crane yellow over the steel texture
	var count := 0

	# Static base + mast, shatterable by explosives.
	var mast: Array[Node3D] = []
	mast.append(_box(parent, Vector3(origin.x, origin.y + 0.4, origin.z),
			Vector3(3.0, 0.8, 3.0), Color(0.5, 0.52, 0.54), ConcreteTex))
	var y := origin.y + 0.8
	for seg in 5:
		mast.append(_box(parent, Vector3(origin.x, y + 1.5, origin.z),
				Vector3(1.0, 3.0, 1.0), yellow, CorrugatedTex))
		y += 3.0
	for m in mast:
		m.body_type = Box3DBody.STATIC
	count += mast.size()

	# Slewing rig: kinematic boom bodies under one rotating pivot node.
	var rig := CraneRig.new()
	rig.position = Vector3(origin.x, origin.y, origin.z)
	rig.rotation.y = yaw
	rig.mast_parts = mast
	parent.add_child(rig)
	_kin(rig, Vector3(0, 16.45, 0), Vector3(1.5, 1.3, 1.5), yellow, CorrugatedTex)
	_kin(rig, Vector3(0, 18.05, 0), Vector3(0.55, 1.9, 0.55), yellow, CorrugatedTex)
	_kin(rig, Vector3(7.0, 17.35, 0), Vector3(13.5, 0.55, 0.75), yellow, CorrugatedTex)
	_kin(rig, Vector3(-2.6, 17.35, 0), Vector3(4.6, 0.55, 0.75), yellow, CorrugatedTex)
	_kin(rig, Vector3(-4.6, 16.6, 0), Vector3(1.3, 1.5, 1.7),
			Color(0.5, 0.52, 0.54), ConcreteTex)
	var tie_a := _kin(rig, Vector3(3.9, 18.4, 0), Vector3(7.9, 0.1, 0.1),
			yellow * 0.85, CorrugatedTex)
	tie_a.rotation.z = -0.19
	var tie_b := _kin(rig, Vector3(-2.3, 18.4, 0), Vector3(4.9, 0.1, 0.1),
			yellow * 0.85, CorrugatedTex)
	tie_b.rotation.z = 0.31
	var trolley := _kin(rig, Vector3(9.0, 16.9, 0), Vector3(0.8, 0.4, 1.0),
			Color(0.35, 0.36, 0.4), MetalTex)
	rig.trolley = trolley
	count += 8

	# The ball: heavy, CCD'd, and in the groups that make it playable. It
	# hangs low enough to smash ground floors and swings up from there.
	var tg: Vector3 = trolley.global_position
	var ball := Box3DBody.new()
	ball.shape_type = Box3DBody.SPHERE
	ball.sphere_radius = 0.85
	ball.density = 10.0
	ball.friction = 0.6
	ball.continuous = true
	ball.position = Vector3(tg.x, origin.y + 2.2, tg.z)
	ball.add_to_group("projectile")
	ball.add_to_group("wrecking_ball")
	parent.add_child(ball)
	BoxVisuals.sphere(ball, 0.85, Color(0.14, 0.14, 0.16))
	count += 1

	# Rope mass ~8-15% of the ball's (~26 t) so the last pin holds taut.
	# Collides with the world (no ghosting through walls) and pins to the
	# ball's TOP so links never spawn inside the sphere they collide with.
	var opts: Dictionary = CraneRig.CABLE_OPTS.duplicate()
	opts["body_a"] = trolley
	opts["body_b"] = ball
	rig.ball = ball
	rig.cable = Cable.spawn(parent, tg - Vector3(0, 0.2, 0),
			ball.position + Vector3(0, 0.9, 0), opts)

	# The hoist line: a rigid distance joint trolley->ball that crane.gd
	# winches (PgUp/PgDn). The chain above goes slack when the ball is
	# raised, exactly like a real crane's spare cable.
	var hoist := Box3DDistanceJoint.new()
	hoist.body_a = trolley.get_path()
	hoist.body_b = ball.get_path()
	hoist.length = tg.distance_to(ball.position)
	hoist.position = tg
	parent.add_child(hoist)
	rig.hoist = hoist
	rig.hoist_len = hoist.length
	return count


## One kinematic boom body parented to the slewing rig (local coordinates).
static func _kin(rig: Node3D, at: Vector3, size: Vector3, tint: Color,
		tex: Texture2D) -> Node3D:
	var p := WallPanel.new()
	p.box_size = size
	p.position = at
	p.body_type = Box3DBody.KINEMATIC
	p.density = DENSITY
	p.friction = FRICTION
	var c := tint
	c.a = 1.0
	p.panel_color = c
	p.facade_tex = tex
	rig.add_child(p)
	return p


## One REAL round piece: Box3D native cylinder (or cone) hull + matching
## mesh, fracture behaviour in drum.gd. `center` is the piece's mid-point.
static func _drum(parent: Node3D, center: Vector3, radius: float, h: float,
		tint: Color, tex: Texture2D, cone := false) -> Node3D:
	var d := Drum.new()
	d.shape_type = Box3DBody.CONE if cone else Box3DBody.CYLINDER
	d.capsule_radius = radius
	d.capsule_height = h
	d.cylinder_sides = 16
	d.density = DENSITY
	d.friction = FRICTION
	var c := tint
	c.a = 1.0
	d.drum_color = c
	d.facade_tex = tex
	d.position = center
	parent.add_child(d)
	return d


## A cluster of 2-3 round corrugated grain silos -- REAL cylinders (Box3D
## native hulls), stacked as drums so blasts knock them into rolling
## sections -- with conical caps, heights staggered like the real thing.
static func add_silo_group(parent: Node3D, origin: Vector3,
		rng: RandomNumberGenerator) -> int:
	var n := rng.randi_range(2, 3)
	var radius := rng.randf_range(1.5, 1.8)
	var gap := radius * 2.0 + 0.7
	var tint := Color(1.0, 1.0, 1.02).lerp(Color(1.05, 0.85, 0.65), rng.randf() * 0.5)
	var count := 0
	for si in n:
		var cx := origin.x + (si - (n - 1) * 0.5) * gap
		var drums := rng.randi_range(5, 7)
		var drum_h := 1.5
		var y := origin.y
		for i in drums:
			_drum(parent, Vector3(cx, y + drum_h * 0.5, origin.z),
					radius, drum_h, tint, CorrugatedTex)
			count += 1
			y += drum_h
		_drum(parent, Vector3(cx, y + 0.45, origin.z),
				radius + 0.12, 0.9, tint * 0.88, CorrugatedTex, true)
		count += 1
	return count
## One ring of a square masonry shaft: two full-width panels and two fitted
## between them; `flip` swaps which pair spans full width (masonry bond).
static func _ring(parent: Node3D, base: Vector3, side: float, h: float,
		flip: bool, tint: Color, tex: Texture2D) -> int:
	var half := (side - T) * 0.5
	var mid := base + Vector3(0, h * 0.5, 0)
	if flip:
		_box(parent, mid + Vector3(0, 0, half), Vector3(side, h, T), tint, tex)
		_box(parent, mid + Vector3(0, 0, -half), Vector3(side, h, T), tint, tex)
		_box(parent, mid + Vector3(half, 0, 0), Vector3(T, h, side - 2.0 * T), tint, tex)
		_box(parent, mid + Vector3(-half, 0, 0), Vector3(T, h, side - 2.0 * T), tint, tex)
	else:
		_box(parent, mid + Vector3(half, 0, 0), Vector3(T, h, side), tint, tex)
		_box(parent, mid + Vector3(-half, 0, 0), Vector3(T, h, side), tint, tex)
		_box(parent, mid + Vector3(0, 0, half), Vector3(side - 2.0 * T, h, T), tint, tex)
		_box(parent, mid + Vector3(0, 0, -half), Vector3(side - 2.0 * T, h, T), tint, tex)
	return 4


## One wall row: piers with sills between them and a lintel band on top --
## building_gen's pattern with every height tunable. `door_col` picks which
## opening becomes a full-height gate (-1 for none).
static func _wall_row(parent: Node3D, ground_center: Vector3, length: float,
		along_x: bool, pier_h: float, sill_h: float, band_h: float, win_w: float,
		door_col: int, tint: Color, tex: Texture2D) -> int:
	var n_win := maxi(int((length - 1.2) / (win_w * 2.2)), 1)
	var pier_w := (length - n_win * win_w) / (n_win + 1.0)
	var count := 0
	var cursor := -length * 0.5
	for i in 2 * n_win + 1:
		var is_pier := i % 2 == 0
		var cw := pier_w if is_pier else win_w
		var cx := cursor + cw * 0.5
		cursor += cw
		var face: Vector2
		var mid_h: float
		if is_pier:
			face = Vector2(cw, pier_h)
			mid_h = pier_h * 0.5
		elif i == door_col:
			continue  # gate: open all the way to the band
		else:
			face = Vector2(cw, sill_h)
			mid_h = sill_h * 0.5
		if along_x:
			_box(parent, ground_center + Vector3(cx, mid_h, 0.0),
					Vector3(face.x, face.y, T), tint, tex)
		else:
			_box(parent, ground_center + Vector3(0.0, mid_h, cx),
					Vector3(T, face.y, face.x), tint, tex)
		count += 1
	var band_mid := pier_h + band_h * 0.5
	if along_x:
		_box(parent, ground_center + Vector3(0.0, band_mid, 0.0),
				Vector3(length, band_h, T), tint, tex)
	else:
		_box(parent, ground_center + Vector3(0.0, band_mid, 0.0),
				Vector3(T, band_h, length), tint, tex)
	return count + 1


static func _box(parent: Node3D, center: Vector3, size: Vector3, tint: Color,
		tex: Texture2D) -> Node3D:
	var p := WallPanel.new()
	p.box_size = size
	p.position = center
	p.density = DENSITY
	p.friction = FRICTION
	var c := tint
	c.a = 1.0
	p.panel_color = c
	p.facade_tex = tex
	parent.add_child(p)
	return p
