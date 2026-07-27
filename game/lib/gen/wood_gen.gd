extends RefCounted

## Generates timber structures -- the fuel for the fire system: plank-sided
## cabins, board fences, log piles and lumber stacks. Everything is built
## from flammable WallPanels / BreakableBlocks (wood density 0.5, low
## fracture threshold), so the same structures also break, float and burn.
##
## No wood texture ships in the repo (nothing here needs a download), so the
## plank albedo is generated procedurally once and shared: vertical boards,
## per-board shade, grain
## streaks and seam lines, tinted per structure like every other facade.

const WallPanel := preload("res://lib/bodies/wall_panel.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")
const GlassPane := preload("res://lib/glass/glass_pane.gd")

const WIN_W := 0.8  # cabin side-window width (rows 1-2 of the +X wall)

const DENSITY := 0.5      # wood (water_fx floats it; panels at 1.2 sink)
const FRICTION := 0.7
const FRACTURE := 5.5     # wood cracks easier than masonry (7.0)
const BOARD_T := 0.06     # siding thickness: kindling, catches fast
const BOARD_H := 0.42
const POST_T := 0.17      # corner posts: real timber, slow to ignite
const WALL_H := 2.5

const TINTS := [
	Color(0.98, 0.9, 0.78),   # fresh pine
	Color(0.9, 0.78, 0.62),   # aged spruce
	Color(0.82, 0.66, 0.5),   # oiled brown
	Color(0.75, 0.72, 0.66),  # weathered gray
]

static var _plank_tex: ImageTexture


## Procedural plank albedo (256^2, deterministic): warm boards ready for the
## facade shader's near-white tints, like the photo textures.
static func plank_texture() -> ImageTexture:
	if _plank_tex != null:
		return _plank_tex
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x1000D
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var boards := 10
	@warning_ignore("integer_division")
	var bw := 256 / boards + 1
	for b in boards:
		var shade := 0.72 + rng.randf() * 0.24
		var phase := rng.randf() * TAU
		var freq := 0.06 + rng.randf() * 0.05
		for x in bw:
			@warning_ignore("integer_division")
			var px := b * (256 / boards) + x
			if px >= 256:
				break
			var edge := 0.62 if (x <= 1 or x >= bw - 2) else 1.0
			for y in 256:
				var grain := 0.9 + 0.1 * sin(y * freq + phase + x * 0.35) \
						+ 0.05 * sin(y * 0.31 + phase * 3.0)
				var v := clampf(shade * grain * edge, 0.0, 1.0)
				img.set_pixel(px, y, Color(v, v * 0.82, v * 0.6))
	_plank_tex = ImageTexture.create_from_image(img)
	return _plank_tex


## A timber cabin: corner posts, horizontal siding boards (with a door gap on
## the front), and a flat overhung plank roof. Returns bodies spawned.
static func cabin(parent: Node3D, origin: Vector3, w: float, d: float,
		rng: RandomNumberGenerator, building_id := 0) -> int:
	var tint: Color = TINTS[rng.randi() % TINTS.size()]
	var count := 0
	# Corner posts, slightly inset so the siding closes the corner.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_post(parent, origin + Vector3(
					sx * (w * 0.5 - POST_T * 0.5), 0.0,
					sz * (d * 0.5 - POST_T * 0.5)), WALL_H, tint, rng)
			count += 1
	# Siding rows. Front (+z) rows leave a door gap; the top row spans it.
	var rows := int(WALL_H / BOARD_H)
	var door_w := 0.9
	var inner_w := w - 2.0 * POST_T
	var inner_d := d - 2.0 * POST_T
	for row in rows:
		var y := row * BOARD_H
		var front_z := origin.z + (d - BOARD_T) * 0.5
		if row >= rows - 1:
			_board(parent, Vector3(origin.x, origin.y + y, front_z),
					inner_w, true, tint, rng)
			count += 1
		else:
			var seg := (inner_w - door_w) * 0.5
			for side in [-1.0, 1.0]:
				_board(parent, Vector3(
						origin.x + side * (door_w * 0.5 + seg * 0.5),
						origin.y + y, front_z), seg, true, tint, rng)
				count += 1
		_board(parent, Vector3(origin.x, origin.y + y,
				origin.z - (d - BOARD_T) * 0.5), inner_w, true, tint, rng)
		count += 1
		for side in [-1.0, 1.0]:
			# The +X wall gets a window across rows 1-2: two flanking boards
			# and one pane -- a burning cabin pops its own glass.
			if side > 0.0 and (row == 1 or row == 2):
				var seg2 := (inner_d - WIN_W) * 0.5
				for zs in [-1.0, 1.0]:
					var b := WallPanel.new()
					_wood(b, Vector3(BOARD_T, BOARD_H, seg2), tint)
					b.position = origin + Vector3(side * (w - BOARD_T) * 0.5,
							y + BOARD_H * 0.5, zs * (WIN_W * 0.5 + seg2 * 0.5))
					parent.add_child(b)
					count += 1
				if row == 1:
					var pane := GlassPane.new()
					pane.box_size = Vector3(0.03, BOARD_H * 2.0 - 0.04, WIN_W - 0.04)
					pane.position = origin + Vector3(side * (w - BOARD_T) * 0.5,
							y + BOARD_H, 0.0)
					pane.set_meta("building_id", building_id)
					parent.add_child(pane)
					count += 1
				continue
			_board(parent, Vector3(origin.x + side * (w - BOARD_T) * 0.5,
					origin.y + y, origin.z), inner_d, false, tint, rng)
			count += 1
	# Roof: one overhung plank slab plus a ridge cap for silhouette.
	var roof := WallPanel.new()
	_wood(roof, Vector3(w + 0.5, 0.09, d + 0.5), tint.darkened(0.25))
	roof.position = origin + Vector3(0.0, rows * BOARD_H + 0.045, 0.0)
	parent.add_child(roof)
	var cap := WallPanel.new()
	_wood(cap, Vector3(w * 0.5, 0.14, 0.5), tint.darkened(0.35))
	cap.position = origin + Vector3(0.0, rows * BOARD_H + 0.16, 0.0)
	parent.add_child(cap)
	return count + 2


## A run of board-fence segments from `from` toward `to`: standing plank
## panels with sliver gaps -- touching in fire terms, so a lit fence end
## carries the flame down the line (the propagation test track).
static func fence(parent: Node3D, from: Vector3, to: Vector3,
		rng: RandomNumberGenerator) -> int:
	var dir := (to - from)
	var length := dir.length()
	if length < 0.5:
		return 0
	dir /= length
	var seg := 1.4
	var gap := 0.08
	var n := maxi(int(length / (seg + gap)), 1)
	var count := 0
	var tint: Color = TINTS[rng.randi() % TINTS.size()].darkened(0.1)
	for i in n:
		var center := from + dir * ((i + 0.5) * (seg + gap))
		var p := WallPanel.new()
		_wood(p, Vector3(seg, 0.55, 0.09), tint)
		p.position = center + Vector3(0.0, 0.275, 0.0)
		if absf(dir.x) < absf(dir.z):
			p.box_size = Vector3(0.09, 0.55, seg)
		parent.add_child(p)
		count += 1
	return count


## A stacked log pile (boxes: hull debris comes from fracturing anyway).
static func log_pile(parent: Node3D, at: Vector3,
		rng: RandomNumberGenerator) -> int:
	var count := 0
	var rot := rng.randf_range(0.0, TAU)
	var layers: Array[int] = [3, 2, 1]
	for li in layers.size():
		for i in layers[li]:
			var log_body := BreakableBlock.new()
			log_body.box_size = Vector3(0.28, 0.28, 1.9)
			log_body.density = DENSITY
			log_body.friction = FRICTION
			log_body.flammable = true
			log_body.block_color = Color(0.5, 0.36, 0.22).darkened(rng.randf() * 0.15)
			var off: float = (i - (layers[li] - 1) * 0.5) * 0.3
			log_body.position = at + Vector3(off, 0.14 + li * 0.28, 0.0) \
					.rotated(Vector3.UP, rot)
			log_body.rotation.y = rot
			parent.add_child(log_body)
			count += 1
	return count


## A criss-cross lumber stack: layers of sawn planks, the classic yard fuel.
static func lumber_stack(parent: Node3D, at: Vector3,
		rng: RandomNumberGenerator) -> int:
	var count := 0
	var rot := rng.randf_range(0.0, TAU)
	for layer in 5:
		var along_x := layer % 2 == 0
		for i in 3:
			var plank := BreakableBlock.new()
			plank.box_size = Vector3(1.7, 0.08, 0.42) if along_x \
					else Vector3(0.42, 0.08, 1.7)
			plank.density = DENSITY
			plank.friction = FRICTION
			plank.flammable = true
			plank.block_color = Color(0.85, 0.7, 0.5).darkened(rng.randf() * 0.12)
			var off := (i - 1) * 0.55
			var local := Vector3(0.0, 0.04 + layer * 0.11, off) if along_x \
					else Vector3(off, 0.04 + layer * 0.11, 0.0)
			plank.position = at + local.rotated(Vector3.UP, rot)
			plank.rotation.y = rot
			parent.add_child(plank)
			count += 1
	return count


static func _post(parent: Node3D, at: Vector3, h: float, tint: Color,
		_rng: RandomNumberGenerator) -> void:
	var p := WallPanel.new()
	_wood(p, Vector3(POST_T, h, POST_T), tint.darkened(0.2))
	p.position = at + Vector3(0.0, h * 0.5, 0.0)
	parent.add_child(p)


static func _board(parent: Node3D, center_ground: Vector3, length: float,
		along_x: bool, tint: Color, _rng: RandomNumberGenerator) -> void:
	var p := WallPanel.new()
	if along_x:
		_wood(p, Vector3(length, BOARD_H, BOARD_T), tint)
	else:
		_wood(p, Vector3(BOARD_T, BOARD_H, length), tint)
	p.position = center_ground + Vector3(0.0, BOARD_H * 0.5, 0.0)
	parent.add_child(p)


static func _wood(p: WallPanel, size: Vector3, tint: Color) -> void:
	p.box_size = size
	p.density = DENSITY
	p.friction = FRICTION
	p.fracture_speed = FRACTURE
	p.flammable = true
	p.material = "wood"
	p.panel_color = tint
	p.facade_tex = plank_texture()
