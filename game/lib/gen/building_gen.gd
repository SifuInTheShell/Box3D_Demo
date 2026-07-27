extends RefCounted

## Generates a small multi-storey building out of solid Box3D wall panels,
## platform-construction style: each storey's walls carry a full-footprint
## floor slab, the next storey stands on that slab, a roof slab caps it off.
##
## A wall storey is: full-height piers, window sills between them, and one
## continuous lintel band along the top (resting on the piers, spanning the
## window and door openings) -- so every panel is supported and buildings
## stand rigid until shot at.
##
##   band   ────────────────────
##   piers  █  gap █  gap  █      (gap = window above sill, or door)
##   sills  █ ▄▄▄▄ █ ▄▄▄▄  █

const WallPanel := preload("res://lib/bodies/wall_panel.gd")
const GlassPane := preload("res://lib/glass/glass_pane.gd")

const T := 0.35  # wall thickness
const PIER_H := 2.05  # pier height = door-gap height
const BAND_H := 0.75  # lintel band along the wall top
const STORY_H := 2.8  # PIER_H + BAND_H
const SILL_H := 0.95  # sill panel under a window; gap = PIER_H - SILL_H
const WIN_W := 1.15  # window / door width
const SLAB_T := 0.22  # intermediate floor slab thickness
const DENSITY := 1.2
const FRICTION := 0.8
const ROOF_COLORS := [
	Color(0.36, 0.3, 0.28),  # dark brown
	Color(0.45, 0.32, 0.26),  # tile red
	Color(0.32, 0.34, 0.38),  # slate
	Color(0.42, 0.4, 0.36),  # weathered gray
]


## Builds one building with its footprint centred on origin (ground level).
## Returns the number of bodies spawned. `glass_tag` marks every window pane
## for the glass ledger ("target" / "protected" / "neutral"); `building_id`
## is stamped on every pane so window_life.gd can darken a whole building
## at once (power loss).
static func build(parent: Node3D, origin: Vector3, w: float, d: float, stories: int,
		tint: Color, tex: Texture2D, rng: RandomNumberGenerator,
		glass_tag := "neutral", building_id := 0) -> int:
	var count := 0
	var y := origin.y
	for s in stories:
		# Front (+z, with a door on the ground floor) and back walls span the
		# full width; side walls fit between them.
		count += _wall(parent, Vector3(origin.x, y, origin.z + (d - T) * 0.5),
				w, true, s == 0, tint, tex, rng, glass_tag, building_id)
		count += _wall(parent, Vector3(origin.x, y, origin.z - (d - T) * 0.5),
				w, true, false, tint, tex, rng, glass_tag, building_id)
		count += _wall(parent, Vector3(origin.x - (w - T) * 0.5, y, origin.z),
				d - 2.0 * T, false, false, tint, tex, rng, glass_tag, building_id)
		count += _wall(parent, Vector3(origin.x + (w - T) * 0.5, y, origin.z),
				d - 2.0 * T, false, false, tint, tex, rng, glass_tag, building_id)
		y += STORY_H
		if s < stories - 1:
			_slab(parent, Vector3(origin.x, y + SLAB_T * 0.5, origin.z),
					Vector3(w, SLAB_T, d), tint * 0.82, tex, rng)
			count += 1
			y += SLAB_T
	var roof_tint: Color = ROOF_COLORS[rng.randi() % ROOF_COLORS.size()]
	var rw := w + 0.5
	var rd := d + 0.5
	_slab(parent, Vector3(origin.x, y + 0.14, origin.z),
			Vector3(rw, 0.28, rd), roof_tint, null, rng)
	count += 1
	var roof_top := y + 0.28

	if rng.randf() < 0.55:
		_slab(parent, Vector3(
				origin.x + rng.randf_range(-0.3, 0.3) * w, roof_top + 0.45,
				origin.z + rng.randf_range(-0.3, 0.3) * d),
				Vector3(0.55, 0.9, 0.55), tint * 0.85, null, rng)
		count += 1

	if rng.randf() < 0.4:
		var ph := 0.5  # parapet wall around the roof edge
		var pt := 0.18
		_slab(parent, Vector3(origin.x, roof_top + ph * 0.5, origin.z + (rd - pt) * 0.5),
				Vector3(rw, ph, pt), tint, tex, rng)
		_slab(parent, Vector3(origin.x, roof_top + ph * 0.5, origin.z - (rd - pt) * 0.5),
				Vector3(rw, ph, pt), tint, tex, rng)
		_slab(parent, Vector3(origin.x - (rw - pt) * 0.5, roof_top + ph * 0.5, origin.z),
				Vector3(pt, ph, rd - 2.0 * pt), tint, tex, rng)
		_slab(parent, Vector3(origin.x + (rw - pt) * 0.5, roof_top + ph * 0.5, origin.z),
				Vector3(pt, ph, rd - 2.0 * pt), tint, tex, rng)
		count += 4
	return count


## One wall storey: pier / opening columns plus the top band. ground_center is
## the wall's footprint centre at floor level; the wall runs along X or Z.
static func _wall(parent: Node3D, ground_center: Vector3, length: float, along_x: bool,
		with_door: bool, tint: Color, tex: Texture2D, rng: RandomNumberGenerator,
		glass_tag := "neutral", building_id := 0) -> int:
	var n_win := 2 if length >= 6.0 else 1
	var pier_w := (length - n_win * WIN_W) / (n_win + 1.0)
	var door_col := 1 if with_door else -1  # first opening column becomes the door
	var count := 0
	var cursor := -length * 0.5
	for i in 2 * n_win + 1:
		var is_pier := i % 2 == 0
		var cw := pier_w if is_pier else WIN_W
		var cx := cursor + cw * 0.5
		cursor += cw
		if is_pier:
			_panel(parent, ground_center, cx, PIER_H * 0.5, Vector2(cw, PIER_H),
					along_x, tint, tex, rng)
			count += 1
		elif i == door_col:
			pass  # door: gap all the way up to the band
		else:
			_panel(parent, ground_center, cx, SILL_H * 0.5, Vector2(cw, SILL_H),
					along_x, tint, tex, rng)
			count += 1
			# Glazing: a pane fills the opening between sill top and band.
			var pane := GlassPane.new()
			var gh := PIER_H - SILL_H - 0.04
			if along_x:
				pane.box_size = Vector3(cw - 0.06, gh, 0.03)
				pane.position = ground_center + Vector3(cx, SILL_H + gh * 0.5 + 0.02, 0.0)
			else:
				pane.box_size = Vector3(0.03, gh, cw - 0.06)
				pane.position = ground_center + Vector3(0.0, SILL_H + gh * 0.5 + 0.02, cx)
			pane.glass_tag = glass_tag
			pane.set_meta("building_id", building_id)
			parent.add_child(pane)
			count += 1
	_panel(parent, ground_center, 0.0, PIER_H + BAND_H * 0.5, Vector2(length, BAND_H),
			along_x, tint, tex, rng)
	return count + 1


static func _panel(parent: Node3D, ground_center: Vector3, offset: float, mid_h: float,
		face: Vector2, along_x: bool, tint: Color, tex: Texture2D,
		rng: RandomNumberGenerator) -> void:
	var p := WallPanel.new()
	if along_x:
		p.box_size = Vector3(face.x, face.y, T)
		p.position = ground_center + Vector3(offset, mid_h, 0.0)
	else:
		p.box_size = Vector3(T, face.y, face.x)
		p.position = ground_center + Vector3(0.0, mid_h, offset)
	_finish(p, tint, tex, rng)
	parent.add_child(p)


static func _slab(parent: Node3D, center: Vector3, size: Vector3, tint: Color,
		tex: Texture2D, rng: RandomNumberGenerator) -> void:
	var p := WallPanel.new()
	p.box_size = size
	p.position = center
	_finish(p, tint, tex, rng)
	parent.add_child(p)


## Every panel of an element gets the exact same tint and a WORLD-triplanar
## texture: identical shading plus continuous texturing is what makes the
## individual panels read as one solid surface.
static func _finish(p: Node3D, tint: Color, tex: Texture2D,
		_rng: RandomNumberGenerator) -> void:
	p.density = DENSITY
	p.friction = FRICTION
	var c := tint
	c.a = 1.0
	p.panel_color = c
	p.facade_tex = tex
