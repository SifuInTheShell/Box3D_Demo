extends Node3D

## GPU interactive-ripple heightfield for a water strip (docs/
## water-research.md §2): runs fx/water_sim.glsl on the MAIN
## RenderingDevice at a fixed 30 Hz, over a 3-texture ring cycled by RID
## (no copies), with this frame's impacts delivered as a storage buffer of
## splats. The newest texture is exposed to the water material through a
## Texture2DRD -- zero readback -- where it displaces vertices and bends
## normals. Headless-safe: with no RenderingDevice (settle tests, CI) the
## node stays inert and splat() is a no-op.
##
##   var sim := WaterSim.attach(zone, water_material, center, strip)
##   sim.splat(world_pos, radius_m, strength)   # negative = push down

const _Self = preload("res://lib/water/water_sim.gd")

const SIM_HZ := 30.0
const MAX_SPLATS := 64
const TEXELS_PER_M := 8.0
const DAMP := 0.012      # per-step energy loss
const EDGE_BAND := 16.0  # absorbing band on the open ends, texels
const MAX_DIM := 2048

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _tex: Array = []     # 3 R32F sim textures, cycled prev/curr/next
var _sets: Array = []    # one uniform set per ring rotation
var _splat_buf: RID
var _ring := 0
var _acc := 0.0
var _queue := PackedFloat32Array()
var _queued := 0
var _dims := Vector2i.ZERO
var _origin := Vector2.ZERO
var _span := Vector2.ONE
var _out_tex: Texture2DRD


static func attach(parent: Node3D, mat: ShaderMaterial, center: Vector3,
		strip: Vector2) -> Node3D:
	var s := _Self.new()
	s._origin = Vector2(center.x - strip.x * 0.5, center.z - strip.y * 0.5)
	s._span = strip
	parent.add_child(s)
	s._setup(mat)
	return s


## Queue an impact splat for the next sim step (world position, radius in
## metres, signed strength in sim units). Safe to call when disabled.
func splat(world_pos: Vector3, radius_m: float, strength: float) -> void:
	if _rd == null or _queued >= MAX_SPLATS:
		return
	var uv := (Vector2(world_pos.x, world_pos.z) - _origin) / _span
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return
	_queue.append_array(PackedFloat32Array([
		uv.x * _dims.x, uv.y * _dims.y,
		maxf(radius_m * TEXELS_PER_M, 2.0), strength]))
	_queued += 1


func _setup(mat: ShaderMaterial) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return  # headless / compatibility renderer: stay inert
	var shader_file = load("res://lib/fx/water_sim.glsl")
	if shader_file == null:
		_rd = null
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_warning("[water_sim] compute compile failed: %s"
				% spirv.compile_error_compute)
		_rd = null
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	_dims = Vector2i(
			mini(int(ceilf(_span.x * TEXELS_PER_M / 8.0)) * 8, MAX_DIM),
			mini(int(ceilf(_span.y * TEXELS_PER_M / 8.0)) * 8, MAX_DIM))
	var tf := RDTextureFormat.new()
	tf.width = _dims.x
	tf.height = _dims.y
	tf.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var zeros := PackedByteArray()
	zeros.resize(_dims.x * _dims.y * 4)
	for i in 3:
		_tex.append(_rd.texture_create(tf, RDTextureView.new(), [zeros]))
	_splat_buf = _rd.storage_buffer_create(MAX_SPLATS * 16)

	# One cached uniform set per ring rotation: prev/curr/next walk the ring.
	for r in 3:
		var us: Array = []
		for b in 3:
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.binding = b
			u.add_id(_tex[(r + b) % 3])
			us.append(u)
		var ub := RDUniform.new()
		ub.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		ub.binding = 3
		ub.add_id(_splat_buf)
		us.append(ub)
		_sets.append(_rd.uniform_set_create(us, _shader, 0))

	_out_tex = Texture2DRD.new()
	_out_tex.texture_rd_rid = _tex[2]
	mat.set_shader_parameter("ripple_tex", _out_tex)
	mat.set_shader_parameter("ripple_origin", _origin)
	mat.set_shader_parameter("ripple_span", _span)


func _process(delta: float) -> void:
	if _rd == null:
		return
	_acc = minf(_acc + delta, 4.0 / SIM_HZ)  # cap catch-up work
	var stepped := false
	while _acc >= 1.0 / SIM_HZ:
		_acc -= 1.0 / SIM_HZ
		_step()
		stepped = true
	if stepped:
		# _ring already advanced in _step(): the newest (just-written)
		# texture is the one that will serve as "curr" next step.
		_out_tex.texture_rd_rid = _tex[(_ring + 1) % 3]


func _step() -> void:
	if _queued > 0:
		_rd.buffer_update(_splat_buf, 0, _queued * 16, _queue.to_byte_array())
	var pc := PackedFloat32Array([
			float(_dims.x), float(_dims.y), DAMP, float(_queued),
			EDGE_BAND, 0.0, 0.0, 0.0])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _sets[_ring], 0)
	_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 32)
	@warning_ignore("integer_division")
	_rd.compute_list_dispatch(cl, _dims.x / 8, _dims.y / 8, 1)
	_rd.compute_list_end()
	_ring = (_ring + 1) % 3
	_queue.clear()
	_queued = 0


func _exit_tree() -> void:
	if _rd == null:
		return
	for s in _sets:
		if s.is_valid():
			_rd.free_rid(s)
	for t in _tex:
		_rd.free_rid(t)
	if _splat_buf.is_valid():
		_rd.free_rid(_splat_buf)
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_rd = null
