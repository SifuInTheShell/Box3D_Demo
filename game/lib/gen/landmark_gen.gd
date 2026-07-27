extends RefCounted

## Recreates famous demolition-magnet landmarks out of solid Box3D panels.
## Everything obeys the platform-construction rule (each panel rests on
## something below), so the landmarks stand rigid and collapse honestly.
##
## The Golden Gate's cables are REAL rope physics (cable.gd): jointed chains
## pinned to the tower tops and anchorage blocks, sagging into a natural
## catenary, with suspender chains tying the main cables to the deck. Kill a
## tower and the cables whip down with it; drop the deck and it drags the
## cables along by the suspenders.

const WallPanel := preload("res://lib/bodies/wall_panel.gd")
const IndustrialGen := preload("res://lib/gen/industrial_gen.gd")
const Cable := preload("res://lib/bodies/cable.gd")

const CorrugatedTex = preload("res://lib/fx/textures/facades/corrugated.jpg")
const ConcreteTex = preload("res://lib/fx/textures/facades/concrete.jpg")
const PlasterTex = preload("res://lib/fx/textures/facades/plaster.jpg")
const BrickTex = preload("res://lib/fx/textures/facades/brick.jpg")

const DENSITY := 1.2
const FRICTION := 0.8

# International orange: tint > 1 is fine, the shader just multiplies.
const ORANGE := Color(1.15, 0.44, 0.28)
const DECK_GRAY := Color(0.55, 0.56, 0.58)
const PIER_GRAY := Color(0.85, 0.86, 0.88)


## Golden Gate Bridge, running along X and centred on `center`. Two portal
## towers (leg segments sandwiching full-width beams, like lintel bands),
## one 58 m rigid main-span deck resting on the tower portals -- drop a
## tower and the whole span comes down -- approach viaducts on orange bents,
## concrete anchorage blocks, and real jointed catenary cables with
## suspenders down to the deck.
static func add_golden_gate(parent: Node3D, center: Vector3, _rng: RandomNumberGenerator) -> int:
	var count := 0
	var deck_top := center.y + 5.9
	var beam_top := center.y + 16.2
	var tower_beams := {}
	var anchorages := {}

	for sx in [-1.0, 1.0]:
		var tx: float = center.x + sx * 29.0
		var tower := _gg_tower(parent, Vector3(tx, center.y, center.z))
		count += tower.count
		tower_beams[sx] = tower.beam
		# Approach bents + deck slabs out to the anchorage.
		for bx in [36.5, 44.0, 51.5]:
			count += _gg_bent(parent, Vector3(center.x + sx * bx, center.y, center.z))
		for pair in [[29.1, 36.4], [36.6, 43.9], [44.1, 51.4]]:
			var mid: float = (pair[0] + pair[1]) * 0.5
			count += _gg_deck(parent, Vector3(center.x + sx * mid, deck_top, center.z),
					pair[1] - pair[0]).count
		# Rooted 3 m down on the riverbed, rising through the water.
		anchorages[sx] = _box(parent,
				Vector3(center.x + sx * 54.5, center.y + 0.25, center.z),
				Vector3(3.5, 6.5, 5.6), PIER_GRAY, ConcreteTex)
		count += 1

	# Main span: one rigid 58 m deck resting only on the two tower portals.
	var main := _gg_deck(parent, Vector3(center.x, deck_top, center.z), 58.0)
	count += main.count

	# Real cables: main catenary tower-to-tower (slack makes the sag),
	# backstays down to the anchorages, suspenders tying cable to deck.
	var cable_col := Color(0.55, 0.18, 0.11)
	for sz in [-1.0, 1.0]:
		var cz: float = center.z + sz * 2.05
		var a := Vector3(center.x - 29.0, beam_top + 0.2, cz)
		var b := Vector3(center.x + 29.0, beam_top + 0.2, cz)
		var main_cable: Node3D = Cable.spawn(parent, a, b, {
			"slack": 1.06, "segment": 1.7, "radius": 0.09,
			"color": cable_col, "density": 3.0, "break_stretch": 2.4,
			"body_a": tower_beams[-1.0], "body_b": tower_beams[1.0],
		})
		var n_links: int = main_cable.links.size()
		for i in range(3, n_links - 3, 4):
			var link: Node3D = main_cable.links[i]
			var top := link.global_position
			if top.y < deck_top + 1.0:
				continue
			Cable.spawn(parent, top, Vector3(top.x, deck_top, cz), {
				"slack": 1.04, "segment": 0.8, "radius": 0.045,
				"color": cable_col, "break_stretch": 3.0,
				"body_a": link, "body_b": main.slab,
			})
		for sx in [-1.0, 1.0]:
			Cable.spawn(parent,
					Vector3(center.x + sx * 29.0, beam_top + 0.2, cz),
					Vector3(center.x + sx * 54.5, center.y + 3.6, cz), {
						"slack": 1.015, "segment": 1.6, "radius": 0.09,
						"color": cable_col, "density": 3.0, "break_stretch": 2.4,
						"body_a": tower_beams[sx], "body_b": anchorages[sx],
					})
	return count


## Returns {count, beam}: `beam` is the topmost portal beam, the cables'
## saddle body.
static func _gg_tower(parent: Node3D, base: Vector3) -> Dictionary:
	var count := 0
	var y := base.y
	var beam: Node3D = null
	# Concrete caissons: the legs' footing, standing on the riverbed 3 m
	# below the surface.
	for sz in [-1.0, 1.0]:
		_box(parent, Vector3(base.x, base.y - 1.5, base.z + sz * 3.0),
				Vector3(1.7, 3.0, 1.7), PIER_GRAY, ConcreteTex)
		count += 1
	# Three portal layers: leg pair, then a full-width beam the next pair
	# stands on. The gaps between beams are the Golden Gate's portal look.
	for layer in 3:
		var segs := 2
		for s in segs:
			for sz in [-1.0, 1.0]:
				_box(parent, Vector3(base.x, y + (s + 0.5) * 2.3, base.z + sz * 3.0),
						Vector3(1.2, 2.3, 1.2), ORANGE, CorrugatedTex)
				count += 1
		y += segs * 2.3
		beam = _box(parent, Vector3(base.x, y + 0.4, base.z),
				Vector3(1.2, 0.8, 7.2), ORANGE, CorrugatedTex)
		count += 1
		y += 0.8
	return {"count": count, "beam": beam}


static func _gg_bent(parent: Node3D, base: Vector3) -> int:
	# Columns run from the riverbed (-3) up to the cap.
	for sz in [-1.0, 1.0]:
		_box(parent, Vector3(base.x, base.y + 0.8, base.z + sz * 1.55),
				Vector3(0.8, 7.6, 0.8), ORANGE, CorrugatedTex)
	_box(parent, Vector3(base.x, base.y + 5.0, base.z),
			Vector3(0.9, 0.8, 4.8), ORANGE, CorrugatedTex)
	return 3


## Returns {count, slab}: `slab` is the roadway body suspenders pin to.
static func _gg_deck(parent: Node3D, top_center: Vector3, length: float) -> Dictionary:
	var slab := _box(parent, top_center - Vector3(0, 0.25, 0),
			Vector3(length, 0.5, 4.6), DECK_GRAY, ConcreteTex)
	var count := 1
	var rails := maxi(int(length / 7.5), 1)
	var rl := length / rails
	for i in rails:
		var rx := top_center.x - length * 0.5 + (i + 0.5) * rl
		for sz in [-1.0, 1.0]:
			_box(parent, Vector3(rx, top_center.y + 0.26, top_center.z + sz * 2.22),
					Vector3(rl - 0.12, 0.52, 0.14), ORANGE, CorrugatedTex)
			count += 1
	return {"count": count, "slab": slab}


## Elizabeth Tower ("Big Ben"): square limestone shaft, a pale clock stage,
## and a stepped slate spire of shrinking slabs.
static func add_big_ben(parent: Node3D, origin: Vector3, _rng: RandomNumberGenerator) -> int:
	var stone := Color(0.93, 0.87, 0.72)
	var clock := Color(0.99, 0.97, 0.9)
	var slate := Color(0.45, 0.5, 0.48)
	var count := 0
	var y := origin.y
	for i in 13:
		count += IndustrialGen._ring(parent, Vector3(origin.x, y, origin.z),
				3.4, 1.5, i % 2 == 1, stone, PlasterTex)
		y += 1.5
	count += IndustrialGen._ring(parent, Vector3(origin.x, y, origin.z),
			3.8, 1.7, false, clock, PlasterTex)
	y += 1.7
	count += IndustrialGen._ring(parent, Vector3(origin.x, y, origin.z),
			3.4, 1.2, true, stone, PlasterTex)
	y += 1.2
	var side := 3.6
	while side > 0.5:
		_box(parent, Vector3(origin.x, y + 0.275, origin.z),
				Vector3(side, 0.55, side), slate, null)
		count += 1
		y += 0.55
		side -= 0.6
	IndustrialGen._drum(parent, Vector3(origin.x, y + 0.65, origin.z),
			0.45, 1.3, slate, null, true)  # real cone spire tip
	return count + 1


## Leaning Tower of Pisa: REAL marble cylinders (native Box3D hulls) with a
## smaller belfry drum, leaning ~3 degrees -- and it must SURVIVE settling
## that way, which soft contacts allow because the centre of mass stays
## well inside the base.
static func add_pisa_tower(parent: Node3D, origin: Vector3, _rng: RandomNumberGenerator) -> int:
	var marble := Color(1.0, 0.99, 0.95)
	var lean := tan(deg_to_rad(3.0))
	var count := 0
	var drum_h := 1.45
	var y := origin.y
	for i in 9:
		var mid := y - origin.y + drum_h * 0.5
		IndustrialGen._drum(parent,
				Vector3(origin.x + mid * lean, y + drum_h * 0.5, origin.z),
				2.5, drum_h, marble, PlasterTex)
		count += 1
		y += drum_h
	var bmid := y - origin.y + 0.65
	IndustrialGen._drum(parent,
			Vector3(origin.x + bmid * lean, y + 0.65, origin.z),
			2.2, 1.3, marble, PlasterTex)
	y += 1.3
	IndustrialGen._drum(parent,
			Vector3(origin.x + (y - origin.y + 0.125) * lean, y + 0.125, origin.z),
			2.35, 0.25, marble * 0.92, PlasterTex)
	return count + 2


## Great Pyramid of Giza: stepped solid slabs at a scale that dwarfs the
## other landmarks, the way it should. Trivially stable, absurdly
## satisfying to crack open.
static func add_pyramid(parent: Node3D, origin: Vector3, _rng: RandomNumberGenerator) -> int:
	var sand := Color(1.0, 0.9, 0.68)
	var count := 0
	var side := 30.0
	var y := origin.y
	while side > 2.0:
		_box(parent, Vector3(origin.x, y + 0.55, origin.z),
				Vector3(side, 1.1, side), sand, PlasterTex)
		count += 1
		y += 1.1
		side -= 2.3
	_box(parent, Vector3(origin.x, y + 0.5, origin.z),
			Vector3(1.4, 1.0, 1.4), sand * 0.95, PlasterTex)
	return count + 1


static func _box(parent: Node3D, center: Vector3, size: Vector3, tint: Color,
		tex: Texture2D) -> Node3D:
	var p := WallPanel.new()
	p.box_size = size
	p.position = center
	_finish(p, tint, tex)
	parent.add_child(p)
	return p


static func _finish(p: Node3D, tint: Color, tex: Texture2D) -> void:
	p.density = DENSITY
	p.friction = FRICTION
	var c := tint
	c.a = 1.0
	p.panel_color = c
	p.facade_tex = tex
