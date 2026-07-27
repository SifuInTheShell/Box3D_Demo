extends Box3DBody

## A window pane: a thin transparent Box3D body that exists to shatter.
## Breaks from fast contact (annealed glass is fragile), from the explosion
## fracture sweep, from blast overpressure and fire heat (glass_system.gd
## decides those and calls shatter()). Shards are cosmetic flat wedges cut
## by GlassSim.shatter_pattern, jittered, lifetime-capped and globally
## budgeted per the survey (docs/glass-research.md §1).
##
## Builders set box_size (thinnest axis = the glass), glass_tag and
## optionally pane_tint before add_child.

const GlassFX = preload("res://lib/glass/glass_fx.gd")
const BreakableBlock := preload("res://lib/bodies/breakable_block.gd")

const MAX_SHARDS := 240   # global live-shard budget (evictions via lifetime)
const SHARD_GROUP := "glass_shard"
const SPAWN_GRACE_TICKS := 21  # contacts ignored this long after spawn (depenetration)

## "target" / "protected" / "neutral" -- the ledger's scoring key.
var glass_tag := "neutral"
var pane_tint := Color(0.62, 0.78, 0.82, 0.30)

var _shattered := false
var _cracked := false  # a softer knock crazed it (cosmetic; still whole)
var _born_tick := 0  # physics frame at spawn; gates the grace window
# (tick-based, not wall-clock: fracture gating must be deterministic)

static var _mats := {}


func _init() -> void:
	contact_monitor = true


func _ready() -> void:
	add_to_group("glass")
	density = 2.4
	friction = 0.4
	_born_tick = Engine.get_physics_frames()
	# The break stays on the calibrated velocity-diff path (body_entered). The
	# rebuilt binding's body_hit -- real approach speed + contact point -- drives
	# the sub-break CRACK, which is cosmetic and so can't shift the calibration.
	body_entered.connect(_on_body_entered)
	if has_signal("body_hit"):
		connect("body_hit", _on_body_hit)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = box_size
	mi.mesh = mesh
	mi.material_override = _glass_material(pane_tint)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Sub-shatter contact (rebuilt binding's body_hit -> real approach speed +
## contact point): below the break speed but above the crack floor leaves a
## crack, not a break. The break itself runs through the calibrated
## _on_body_entered path, so this cannot move the ledger numbers.
func _on_body_hit(_other: Box3DBody, point: Vector3, _normal: Vector3,
		approach_speed: float) -> void:
	if _shattered or _cracked:
		return
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	if approach_speed >= GlassSim.CRACK_SPEED and approach_speed < GlassSim.IMPACT_SPEED:
		crack(point)


func _on_body_entered(other: Box3DBody) -> void:
	if _shattered or other == null or not is_instance_valid(other):
		return
	# Spawn grace: a pane inset snug in its opening must not be shattered by the
	# frame-1 depenetration impulse -- glass's threshold is very low (see
	# breakable_block for the rationale).
	if Engine.get_physics_frames() - _born_tick < SPAWN_GRACE_TICKS:
		return
	var rel := (other.get_linear_velocity() - get_linear_velocity()).length()
	if rel < GlassSim.IMPACT_SPEED:
		return
	# The system keeps the ledger; it calls shatter() back. Fall back to a
	# direct shatter if a gym somehow runs without one.
	if get_tree().get_nodes_in_group("glass_system").is_empty():
		shatter(other.global_position, clampf(rel / 8.0, 0.2, 1.0))
	else:
		get_tree().call_group("glass_system", "pane_impact", self, rel,
				other.global_position)


## Explosion inner sweep (ExplosionFX.blast): route through the system so
## the ledger sees the break; overpressure handles the wider radius.
func blast_fracture(at: Vector3, speed: float) -> void:
	if _shattered:
		return
	if get_tree().get_nodes_in_group("glass_system").is_empty():
		shatter(at, 1.0)
	else:
		get_tree().call_group("glass_system", "pane_impact", self,
				maxf(speed, GlassSim.IMPACT_SPEED), at)


## Break now: glitter burst + flat shards cut finer toward the impact point.
func shatter(at_world: Vector3, energy01: float) -> void:
	if _shattered or not is_inside_tree():
		return
	_shattered = true
	var parent: Node = get_parent()
	while parent != null and not parent is Box3DWorld:
		parent = parent.get_parent()
	if parent == null:
		parent = get_parent()

	# Pane-local face frame: thinnest axis is the glass normal.
	var n_axis := box_size.min_axis_index()
	var u_axis: int = (n_axis + 1) % 3
	var v_axis: int = (n_axis + 2) % 3
	var face := Vector2(box_size[u_axis], box_size[v_axis])
	var local := to_local(at_world)
	var impact := Vector2(clampf(local[u_axis], -face.x * 0.5, face.x * 0.5),
			clampf(local[v_axis], -face.y * 0.5, face.y * 0.5))

	GlassFX.burst(parent, global_position, maxf(face.x, face.y) * 0.7)
	var tree := get_tree()
	if tree != null and tree.get_nodes_in_group(SHARD_GROUP).size() < MAX_SHARDS:
		var rng := BreakableBlock.shared_rng()
		var xf := global_transform
		var vel := get_linear_velocity()
		var out_sign := 1.0 if local[n_axis] <= 0.0 else -1.0
		for cell in GlassSim.shatter_pattern(face, impact, energy01):
			var off_2: Vector2 = cell["off"]
			var size_2: Vector2 = cell["size"]
			var shard := Box3DBody.new()
			var ssize := Vector3.ONE * box_size[n_axis]
			ssize[u_axis] = maxf(size_2.x - 0.012, 0.02)
			ssize[v_axis] = maxf(size_2.y - 0.012, 0.02)
			shard.box_size = ssize
			shard.density = 2.4
			shard.friction = 0.4
			shard.add_to_group("fragment")
			shard.add_to_group(SHARD_GROUP)
			shard.set_meta("born_tick", Engine.get_physics_frames())
			var off := Vector3.ZERO
			off[u_axis] = off_2.x
			off[v_axis] = off_2.y
			var tilt := Basis.from_euler(Vector3(
					(rng.randf() - 0.5) * 0.25,
					(rng.randf() - 0.5) * 0.25,
					(rng.randf() - 0.5) * 0.25))
			shard.transform = Transform3D(xf.basis * tilt, xf * off)
			parent.add_child(shard)
			# Outward puff away from the hit face, stronger near the impact.
			var punch: float = (1.0 + energy01 * 2.5) \
					/ (1.0 + off_2.distance_to(impact) * 2.0)
			var normal := Vector3.ZERO
			normal[n_axis] = out_sign
			shard.set_linear_velocity(vel + xf.basis * normal * punch
					+ Vector3(rng.randf() - 0.5, rng.randf() * 0.4,
							rng.randf() - 0.5) * 0.6)
			var mi := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = ssize
			mi.mesh = mesh
			mi.material_override = _glass_material(pane_tint)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			shard.add_child(mi)
	queue_free()


## A softer knock crazes the glass: radiating crack lines drawn on the pane
## face, but it stays whole and counts as intact in the ledger. Cosmetic and
## one-way -- no body, no shards, no RNG into physics -- so it can't move the
## determinism hash or the glass ledger. A real hit still shatters normally
## (shatter()'s queue_free frees these lines with the pane).
func crack(at_world: Vector3) -> void:
	if _cracked or _shattered or not is_inside_tree():
		return
	_cracked = true
	var n_axis := box_size.min_axis_index()
	var u_axis: int = (n_axis + 1) % 3
	var v_axis: int = (n_axis + 2) % 3
	var face := Vector2(box_size[u_axis], box_size[v_axis])
	var local := to_local(at_world)
	var c := Vector2(clampf(local[u_axis], -face.x * 0.45, face.x * 0.45),
			clampf(local[v_axis], -face.y * 0.45, face.y * 0.45))
	var rng := RandomNumberGenerator.new()
	rng.seed = get_instance_id()  # cosmetic-only, isolated from the physics RNG
	var off := box_size[n_axis] * 0.5 + 0.003
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, _crack_material())
	var spokes := 5 + rng.randi() % 3
	var tips: Array[Vector2] = []
	for k in spokes:
		var ang := k * TAU / spokes + rng.randf_range(-0.35, 0.35)
		var dir := Vector2(cos(ang), sin(ang))
		var reach := rng.randf_range(0.32, 0.5) * face.length()
		var p := c
		for s in 3:
			var np := c + dir * (reach * (s + 1) / 3.0) + Vector2(
					rng.randf_range(-0.03, 0.03), rng.randf_range(-0.03, 0.03))
			np.x = clampf(np.x, -face.x * 0.5, face.x * 0.5)
			np.y = clampf(np.y, -face.y * 0.5, face.y * 0.5)
			_crack_line(im, p, np, u_axis, v_axis, n_axis, off)
			p = np
		tips.append(p)
	for k in tips.size():
		if rng.randf() < 0.6:  # a few chords for a spider-web look
			_crack_line(im, tips[k].lerp(c, 0.4),
					tips[(k + 1) % tips.size()].lerp(c, 0.4),
					u_axis, v_axis, n_axis, off)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _crack_line(im: ImmediateMesh, a: Vector2, b: Vector2,
		u: int, v: int, n: int, off: float) -> void:
	var pa := Vector3.ZERO
	pa[u] = a.x; pa[v] = a.y; pa[n] = off
	var pb := Vector3.ZERO
	pb[u] = b.x; pb[v] = b.y; pb[n] = off
	im.surface_add_vertex(pa)
	im.surface_add_vertex(pb)


static var _crack_mat: StandardMaterial3D

static func _crack_material() -> StandardMaterial3D:
	if _crack_mat == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.92, 0.96, 1.0, 0.85)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_crack_mat = m
	return _crack_mat


## Shared transparent material per quantized tint: hundreds of shards, a
## handful of GPU materials.
static func _glass_material(tint: Color) -> StandardMaterial3D:
	var key := tint.to_html(true)
	if not _mats.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.06
		mat.metallic = 0.1
		mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mats[key] = mat
	return _mats[key]
