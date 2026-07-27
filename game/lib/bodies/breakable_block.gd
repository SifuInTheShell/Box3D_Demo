extends Box3DBody

## A destructible chunk. When something slams into it hard enough it splits
## into UNEVEN pieces: recursive random cuts, biased so the debris is finer
## near the impact point, with piece count and scatter scaling with impact
## speed. Pieces are irregular convex hull shards (jittered-corner boxes), so
## rubble reads as broken material rather than boxes dissolving into boxes.
## Chunks fracture again under further hits until the generation cap or
## minimum size turns pieces into inert fragments; global caps bound totals.

const _Self = preload("res://lib/bodies/breakable_block.gd")
const BoxVis := preload("res://lib/fx/box_visuals.gd")
const FractureQueue := preload("res://lib/fracture_queue.gd")
const FractureFX := preload("res://lib/fx/fracture_fx.gd")

const FRACTURE_SPEED := 12.0  # m/s relative speed needed to shatter
const MIN_SPLIT_EXTENT := 0.15  # cuts never produce slivers thinner than this
const INERT_EXTENT := 0.22  # pieces thinner than this stop fracturing further
const FLAMMABLE_MIN := 0.05  # flammable debris this thin still carries fire (inert fuel)
const SHARD_EXTENT := 0.12  # pieces thinner than this stay boxes (hull-safe)
const MAX_FRAGMENTS := 2500  # global cap: past this, chunks stay whole
const MAX_BRICKS := 3000  # global cap on breakable chunks
const SPAWN_GRACE_TICKS := 21  # contacts ignored this long after spawn (see below)

# Cube corner quads (index = x*4 + y*2 + z, minus = 0), Godot front winding.
const SHARD_FACES := [
	[0, 2, 3, 1], [4, 5, 7, 6],  # -X +X
	[0, 1, 5, 4], [2, 6, 7, 3],  # -Y +Y
	[0, 4, 6, 2], [1, 3, 7, 5],  # -Z +Z
]

## Shared seeded RNG: Box3D itself is deterministic, so keeping our layer
## layer's fracture patterns seeded preserves run-to-run reproducibility.
static var _rng := RandomNumberGenerator.new()

var block_color := Color(0.78, 0.68, 0.52)
var cast_shadows := true  # debris chunks turn this off to spare the GPU
## Wooden chunks register with the fire system and burn (fire_system.gd).
var flammable := false
## Fracture depth. Hand-placed blocks and panel-spawned chunks start at 1;
## pieces spawned by a generation-2 chunk are inert fragments.
var generation := 1
## When set, this chunk is an irregular shard: collision hull + visual both
## use this mesh; box_size stays as the bounding extents for further splits.
var shard_mesh: ArrayMesh = null
## Facade texture inherited from the wall this debris came from
## (object-space triplanar, so it rides along with the piece).
var facade_tex: Texture2D = null

var _fractured := false
var _impact_speed := FRACTURE_SPEED
var _impact_local := Vector3.ZERO
var _born_tick := 0  # physics frame at spawn; gates the grace window
# (tick-based, not wall-clock: fracture gating must be deterministic)


static func _static_init() -> void:
	_rng.seed = 0xFACADE


static func shared_rng() -> RandomNumberGenerator:
	return _rng


func _init() -> void:
	contact_monitor = true


func _ready() -> void:
	add_to_group("block")
	if flammable:
		add_to_group("flammable")
	_born_tick = Engine.get_physics_frames()
	body_entered.connect(_on_body_entered)
	if shard_mesh != null:
		shape_type = Box3DBody.HULL
		collision_mesh = shard_mesh
		BoxVis.custom(self, shard_mesh, block_color, cast_shadows, facade_tex)
	else:
		BoxVis.box(self, box_size, block_color, cast_shadows, facade_tex)


## Fuel description for the fire system (FireSim.add_item).
func fire_profile() -> Dictionary:
	return {"half": box_size * 0.5, "moisture": 0.0, "fuel_scale": 1.0}


## Fire system tick while burning: chunks just char darker -- they are
## already rubble, so there is no threshold left to weaken.
func set_burn(char_frac: float, _burn_strength: float) -> void:
	if _fractured:
		return
	var tint := block_color.darkened(clampf(char_frac, 0.0, 1.0) * 0.7)
	if int(char_frac * 4.0) != int(get_meta("burn_tier", 0)):
		set_meta("burn_tier", int(char_frac * 4.0))
		BoxVis.recolor(self, tint, facade_tex)


## Fully consumed: wooden debris burns away to an ember puff.
func burned_out() -> void:
	if is_inside_tree():
		var parent := get_parent()
		FractureFX.burst(parent, global_position, box_size.length() * 0.4,
				Color(0.12, 0.1, 0.09))
	queue_free()


## Called by ExplosionFX's blast sweep: shatter as if hit at `speed` from the
## blast point. Full contact threshold applies -- only the blast's inner zone
## re-shatters chunks into finer shards.
func blast_fracture(at: Vector3, speed: float) -> void:
	if _fractured or speed < FRACTURE_SPEED:
		return
	_fractured = true
	_impact_speed = speed
	_impact_local = to_local(at).clamp(-box_size * 0.5, box_size * 0.5)
	FractureQueue.enqueue(get_tree(), _fracture)


func _on_body_entered(other: Box3DBody) -> void:
	if _fractured or other == null or not is_instance_valid(other):
		return
	# Spawn grace: structures are placed at rest but can spawn snug against a
	# neighbour; Box3D depenetrates that overlap with a hard frame-1 impulse
	# which reads here as a fast separating contact. Ignore contacts briefly
	# after spawn so a tight-but-valid placement cannot self-destruct.
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	# Velocities are read post-solve, but a cannonball or blast-driven block
	# still separates from us fast; resting contacts stay near zero.
	var rel := (other.get_linear_velocity() - get_linear_velocity()).length()
	if rel < FRACTURE_SPEED:
		return
	_fractured = true
	_impact_speed = rel
	# Best available impact locus: the closest point of our box to the other
	# body's centre. Steers the split so debris is finest where it was hit.
	_impact_local = to_local(other.global_position).clamp(-box_size * 0.5, box_size * 0.5)
	# Queued, not deferred: the queue spreads mass fracturing over frames so
	# a city-wide blast cannot spawn every fragment in a single frame.
	FractureQueue.enqueue(get_tree(), _fracture)


func _fracture() -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree.get_nodes_in_group("fragment").size() >= MAX_FRAGMENTS:
		return
	# Harder hits shatter into more pieces.
	var budget := clampi(3 + int((_impact_speed - FRACTURE_SPEED) * 0.4), 3, 7)
	var pieces := split_box_uneven(box_size, budget, MIN_SPLIT_EXTENT, _rng, _impact_local)
	if pieces.size() <= 1:
		return  # too small to split; stays whole
	var allow_breakable := generation < 2 \
			and tree.get_nodes_in_group("block").size() < MAX_BRICKS
	var parent := get_parent()
	var xf := global_transform
	var vel := get_linear_velocity()
	var ang := get_angular_velocity()
	var scatter := 0.5 + _impact_speed * 0.06
	for piece in pieces:
		var off: Vector3 = piece.off
		var psize: Vector3 = piece.size
		var tint := block_color.darkened(_rng.randf() * 0.18)
		spawn_piece(parent, self, Transform3D(xf.basis, xf * off), psize, tint,
				generation + 1 if allow_breakable else 99,
				vel + ang.cross(xf.basis * off)
				+ Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) * scatter,
				ang, facade_tex)
	FractureFX.burst(parent, xf.origin, box_size.length() * 0.5, block_color)
	queue_free()


## Spawns one debris piece: an irregular hull shard when big enough (a plain
## box for slivers), breakable while `piece_generation` <= 2 and above the
## inert size. Shared by chunks and wall panels.
static func spawn_piece(parent: Node, source: Box3DBody, xform: Transform3D,
		psize: Vector3, tint: Color, piece_generation: int,
		lin_vel: Vector3, ang_vel: Vector3, tex: Texture2D = null) -> void:
	var min_ext := psize[psize.min_axis_index()]
	var shard: ArrayMesh = null
	if min_ext >= SHARD_EXTENT:
		shard = make_shard_mesh(psize, 0.3 + _rng.randf() * 0.25, _rng)
	var piece: Box3DBody
	var flammable_src: bool = source.get("flammable") == true
	var big_enough := min_ext >= INERT_EXTENT  # thick enough to keep fracturing
	# Fire has to ride the rubble. A thin plank or board sits below INERT_EXTENT,
	# so without the flammable branch below it would drop to an inert fragment
	# and the fire would die the instant the wood breaks. Flammable debris down
	# to FLAMMABLE_MIN stays a body that can register with the fire system.
	if piece_generation <= 2 and (big_enough or (flammable_src and min_ext >= FLAMMABLE_MIN)):
		var bb := _Self.new()
		# Thin fuel that only exists to burn is made inert to further fracture
		# (generation 99): it carries fire without spawning an unbounded cascade
		# of ever-smaller flammable chips (its own fracture yields gen-99 pieces,
		# which fail this gate and become plain fragments).
		bb.generation = piece_generation if big_enough else 99
		bb.block_color = tint
		bb.cast_shadows = false
		bb.shard_mesh = shard
		bb.facade_tex = tex
		# Wood stays wood: pieces of a flammable body can burn too, and pieces
		# of a BURNING body are born alight (the fire system picks the meta up
		# on its next sweep) -- a collapsing burning wall seeds fires below.
		if flammable_src:
			bb.flammable = true
			if source.has_meta("on_fire"):
				bb.set_meta("born_burning", true)
				bb.set_meta("burn_char", source.get_meta("burn_char", 0.0))
		piece = bb
	else:
		piece = Box3DBody.new()
		piece.add_to_group("fragment")
		if shard != null:
			piece.shape_type = Box3DBody.HULL
			piece.collision_mesh = shard
	piece.box_size = psize
	piece.density = source.density
	piece.friction = source.friction
	# Random tilt: breaks the flush BSP crack planes the instant the piece
	# spawns, so debris never reads as a sliced grid (the slight neighbour
	# overlap it causes pops pieces apart, which suits an impact anyway).
	var tilt := Basis.from_euler(Vector3(
			(_rng.randf() - 0.5) * 0.3,
			(_rng.randf() - 0.5) * 0.3,
			(_rng.randf() - 0.5) * 0.3))
	piece.transform = Transform3D(xform.basis * tilt, xform.origin)
	parent.add_child(piece)
	piece.set_linear_velocity(lin_vel)
	piece.set_angular_velocity(ang_vel)
	if not (piece is _Self):
		if shard != null:
			BoxVis.custom(piece, shard, tint, false, tex)
		else:
			BoxVis.box(piece, psize, tint, false, tex)


## An irregular convex shard roughly filling `size`: each corner of a box is
## pulled inward by a random amount AND displaced sideways, so pieces come
## out as skewed wedges rather than shrunken boxes. One mesh serves as both
## collision hull (Box3D builds the hull from its vertices) and the visual.
static func make_shard_mesh(size: Vector3, irregularity: float,
		rng: RandomNumberGenerator) -> ArrayMesh:
	var pts: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var p := Vector3(sx, sy, sz) * size * 0.5
				p *= Vector3(
						1.0 - rng.randf() * irregularity,
						1.0 - rng.randf() * irregularity,
						1.0 - rng.randf() * irregularity)
				p += Vector3(
						(rng.randf() - 0.5) * size.x * 0.24,
						(rng.randf() - 0.5) * size.y * 0.24,
						(rng.randf() - 0.5) * size.z * 0.24)
				pts.append(p)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # faceted: every face gets its own flat normal
	for f in SHARD_FACES:
		st.add_vertex(pts[f[0]])
		st.add_vertex(pts[f[1]])
		st.add_vertex(pts[f[2]])
		st.add_vertex(pts[f[0]])
		st.add_vertex(pts[f[2]])
		st.add_vertex(pts[f[3]])
	st.generate_normals()
	return st.commit()


## Recursively split a box into up to `count` uneven axis-aligned pieces.
## Cuts favour the longest axis (with some randomness) at a random 25-75%
## position, and the half containing `focus` (the impact point, local space)
## receives most of the remaining budget -- fine debris near the hit, big
## chunks away from it.
## Returns an Array of { off: Vector3 local-center offset, size: Vector3 }.
static func split_box_uneven(size: Vector3, count: int, min_ext: float,
		rng: RandomNumberGenerator, focus := Vector3.ZERO) -> Array:
	var pieces: Array = []
	_split_rec(Vector3.ZERO, size, count, min_ext, rng, focus, pieces)
	return pieces


static func _split_rec(off: Vector3, size: Vector3, budget: int, min_ext: float,
		rng: RandomNumberGenerator, focus: Vector3, out: Array) -> void:
	if budget <= 1:
		out.append({"off": off, "size": size})
		return
	var axes: Array[int] = []
	for a in 3:
		if size[a] >= min_ext * 2.0:
			axes.append(a)
	if axes.is_empty():
		out.append({"off": off, "size": size})
		return
	var axis: int = axes[0]
	for a in axes:
		if size[a] > size[axis]:
			axis = a
	if axes.size() > 1 and rng.randf() < 0.35:
		axis = axes[rng.randi() % axes.size()]
	var lo := min_ext / size[axis]
	var frac := rng.randf_range(maxf(lo, 0.25), minf(1.0 - lo, 0.75))
	var s1 := size
	s1[axis] = size[axis] * frac
	var s2 := size
	s2[axis] = size[axis] - s1[axis]
	var o1 := off
	o1[axis] = off[axis] - size[axis] * 0.5 + s1[axis] * 0.5
	var o2 := off
	o2[axis] = off[axis] + size[axis] * 0.5 - s2[axis] * 0.5
	# Impact side gets ~2/3 of the budget: it shatters finer.
	var plane := off[axis] - size[axis] * 0.5 + s1[axis]
	var share := 0.66 if focus[axis] <= plane else 0.34
	var b1 := clampi(roundi(budget * share + rng.randf_range(-0.4, 0.4)), 1, budget - 1)
	_split_rec(o1, s1, b1, min_ext, rng, focus, out)
	_split_rec(o2, s2, budget - b1, min_ext, rng, focus, out)
