extends Node3D

## Cosmetic bird flock: the MultiMesh face of AmbientSim.Flock (Townscaper
## model — perch, hop, scatter on a blast, resettle). One draw call for the
## whole flock; the bird is a ~30-tri procedural dart, wings flapped in the
## vertex shader off per-instance custom data, so there is no per-bird node
## and no per-frame script cost beyond mirroring sim positions out.
##
##   BirdFlock.attach(world, perches, count, seed)
##   call_group / AmbientLife relays disturb(at, radius) on blasts.
##
## STRICTLY COSMETIC: birds are not bodies, cast no shadows, never touch
## physics or the sim results. Perches are fixed points (roof lines, branches)
## supplied by the scene builder; a collapsed building's perch just stops
## being chosen once birds flee it (they resettle away from the threat).

const _Self = preload("res://lib/ambient/bird_flock.gd")

const MAX_DT := 0.05  # clamp catch-up steps so a hitch cannot teleport birds

var _flock  # AmbientSim.Flock
var _mmi: MultiMeshInstance3D
var _wind: Node        # cached wind_system, or null on calm sites
var _yaws: Array = []  # per-bird resting yaw while perched


static func attach(world: Node3D, perches: Array, count: int, seed_v: int) -> Node3D:
	var bf := _Self.new()
	bf._flock = AmbientSim.Flock.new(seed_v)
	bf._flock.set_perches(perches)
	bf._flock.spawn(count)
	world.add_child(bf)
	return bf


func disturb(at: Vector3, radius: float) -> void:
	_flock.disturb(at, radius)


func perched_count() -> int:
	return _flock.perched_count()


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _bird_mesh()
	mm.instance_count = _flock.birds.size()
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)
	for i in _flock.birds.size():
		_yaws.append(fmod(float(i) * 2.399963, TAU))  # golden-angle spread
	_mirror()


func _process(delta: float) -> void:
	# Airborne birds ride the weather (perched ones just grip the ridge).
	if _wind == null or not is_instance_valid(_wind):
		_wind = get_tree().get_first_node_in_group("wind_system")
	_flock.wind = _wind.current() if _wind != null else Vector3.ZERO
	_flock.update(minf(delta, MAX_DT))
	_mirror()


func _mirror() -> void:
	var mm := _mmi.multimesh
	for i in _flock.birds.size():
		var pos: Vector3 = _flock.position(i)
		var vel: Vector3 = _flock.velocity(i)
		var flying: bool = _flock.state(i) != AmbientSim.Flock.PERCHED
		var yaw: float = _yaws[i]
		if flying and Vector2(vel.x, vel.z).length() > 0.2:
			yaw = atan2(-vel.x, -vel.z)
		mm.set_instance_transform(i,
				Transform3D(Basis(Vector3.UP, yaw), pos))
		# custom: r = flap phase, g = wings out (0 folded / 1 flying)
		mm.set_instance_custom_data(i,
				Color(_yaws[i], 1.0 if flying else 0.0, 0.0, 0.0))


## A dart-shaped bird: 8-tri body + 4-tri wings, wings identified in the
## shader purely by |z| so no vertex attributes are needed.
static func _bird_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nose := Vector3(0.0, 0.0, -0.17)
	var tail := Vector3(0.0, 0.03, 0.15)
	var top := Vector3(0.0, 0.05, -0.02)
	var bot := Vector3(0.0, -0.04, -0.02)
	var l := Vector3(-0.045, 0.0, -0.02)
	var r := Vector3(0.045, 0.0, -0.02)
	for tri in [[nose, top, l], [nose, r, top], [nose, l, bot], [nose, bot, r],
			[tail, l, top], [tail, top, r], [tail, bot, l], [tail, r, bot]]:
		for v in tri:
			st.add_vertex(v)
	var shoulder_f := Vector3(0.0, 0.02, -0.06)
	var shoulder_b := Vector3(0.0, 0.02, 0.04)
	for side in [-1.0, 1.0]:
		var tip_f := Vector3(side * 0.24, 0.03, -0.02)
		var tip_b := Vector3(side * 0.22, 0.03, 0.07)
		if side < 0.0:
			st.add_vertex(shoulder_f); st.add_vertex(tip_f); st.add_vertex(tip_b)
			st.add_vertex(shoulder_f); st.add_vertex(tip_b); st.add_vertex(shoulder_b)
		else:
			st.add_vertex(shoulder_f); st.add_vertex(tip_b); st.add_vertex(tip_f)
			st.add_vertex(shoulder_f); st.add_vertex(shoulder_b); st.add_vertex(tip_b)
	st.generate_normals()
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://lib/ambient/bird_flap.gdshader")
	mesh.surface_set_material(0, mat)
	return mesh
