extends Node3D

## Dual-mode Box3D stress benchmark: pushes the solver (CPU) and, when a window
## is available, the renderer (GPU) until each subsystem hits its ceiling on the
## machine. One scene, mode picked automatically:
##
##   headless  -- pure solver: rain an escalating pile of cubes into a bin with
##                sleep disabled (every body solved every tick) and report the
##                per-step solver cost per body count.
##   windowed  -- the same pile, but the bodies are drawn through
##                Box3DMultiMeshRenderer (GPU instancing -- one draw call for
##                the whole pile, transforms synced in C++), under a shadowed
##                sun and glow post (the iGPU stressors from this doc's GPU
##                notes), vsync off, and it also reports fps under that load.
##
## Escalates 2k -> 96k bodies and STOPS early once a stage saturates (step time
## or fps floor), so a weak laptop finds its limit fast while a strong one keeps
## climbing. Fixed seed + layout: the contact counts come out byte-identical on
## any CPU (a determinism cross-check), only the timings move.
##
##   headless CPU ceiling:
##     godot --headless --path game res://scenes/test/bench_stress.tscn
##   windowed CPU+GPU:
##     godot --path game res://scenes/test/bench_stress.tscn
##
## Rows print as "[bench] ..." and a CSV lands in the user data dir (path
## printed at the end). Extended DLL diagnostics (get_profile / get_counters /
## get_awake_body_count) are used when present; otherwise it falls back to the
## TIME_PHYSICS_PROCESS monitor and the spawned count.

const STAGES: Array[int] = [2000, 4000, 8000, 16000, 24000, 32000, 48000, 64000, 96000]
const WORKERS := 4              # match the gyms' solver config (perf doc §1)
const BOX := 0.5                # cube edge, metres (uniform: one MultiMesh mesh)
const PIT := 32.0               # half-extent of the containing floor
const WALL_H := 40.0
const SPAWN_Y := 6.0            # drop height above the pile
const SETTLE_TICKS := 60        # let a batch fall and reach the pile (1 s)
const SAMPLE_TICKS := 90        # ticks averaged into each stage's numbers (1.5 s)
const STOP_STEP_MS := 55.0      # bail escalating once the solver is this slow
const STOP_FPS := 8.0           # or (rendered) once fps floors out
const BUDGET_60_MS := 1000.0 / 60.0
const BUDGET_30_MS := 1000.0 / 30.0

var _world: Box3DWorld
var _rng := RandomNumberGenerator.new()
var _rendered := false          # windowed -> render + GPU stress
var _have_profile := false
var _have_mm := false           # Box3DMultiMeshRenderer available in this DLL
var _stage := 0
var _container: Node3D          # holds the current stage's bodies (freed per stage)
var _sampling := false
var _ticks := 0
var _sum_step := 0.0
var _max_step := 0.0
var _sum_fps := 0.0
var _min_fps := 0.0
var _samples := 0
var _rows: Array[String] = []
var _sus60 := 0
var _sus30 := 0
var _gpu60 := 0
var _gpu30 := 0


func _ready() -> void:
	_rendered = DisplayServer.get_name() != "headless"
	_rng.seed = 0xB3DBED
	_have_mm = ClassDB.class_exists("Box3DMultiMeshRenderer")
	_world = Box3DWorld.new()
	_world.name = "BenchWorld"
	_world.continuous_collision = false
	_world.worker_count = WORKERS
	_have_profile = _world.has_method("get_profile")
	if _world.has_method("set_enable_sleep"):
		_world.set_enable_sleep(false)     # keep the whole pile awake
	if "async_step" in _world:
		_world.async_step = false          # measure the solve head-on
	add_child(_world)
	_build_pit()
	if _rendered:
		_build_view()
	_print_header()
	_begin_stage()


func _build_pit() -> void:
	_static_box(Vector3(0, -0.5, 0), Vector3(PIT * 2.0 + 4.0, 1.0, PIT * 2.0 + 4.0))
	for s in [-1.0, 1.0]:
		_static_box(Vector3(s * (PIT + 0.5), WALL_H * 0.5, 0.0),
				Vector3(1.0, WALL_H, PIT * 2.0 + 2.0))
		_static_box(Vector3(0.0, WALL_H * 0.5, s * (PIT + 0.5)),
				Vector3(PIT * 2.0 + 2.0, WALL_H, 1.0))


func _static_box(at: Vector3, size: Vector3) -> void:
	var b := Box3DBody.new()
	b.body_type = Box3DBody.STATIC
	b.box_size = size
	b.position = at
	b.friction = 0.8
	_world.add_child(b)


## Camera + shadowed sun + glow, vsync off: a real fill/shadow/post load so the
## GPU is actually worked, not just handed a cheap draw call.
func _build_view() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -32, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.45)
	env.glow_enabled = true                # fullscreen post -- the iGPU killer
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var cam := Camera3D.new()
	cam.position = Vector3(PIT * 1.3, PIT * 0.9, PIT * 1.3)
	cam.far = 500.0
	add_child(cam)
	cam.look_at(Vector3(0, 2, 0), Vector3.UP)


## Fresh pile per stage: tear down the previous bodies, rain in `target` new
## cubes over a loose grid. Rendered mode parents them to a MultiMesh renderer
## (built on its _ready, so the bodies must exist first), else a plain node.
func _begin_stage() -> void:
	if _container != null and is_instance_valid(_container):
		_container.queue_free()
	var target: int = STAGES[_stage]
	if _rendered and _have_mm:
		_container = ClassDB.instantiate("Box3DMultiMeshRenderer") as Node3D
	else:
		_container = Node3D.new()
	_container.name = "Stage_%d" % target
	_spawn_pile(target, _container)
	_world.add_child(_container)
	_sampling = false
	_ticks = 0
	_sum_step = 0.0
	_max_step = 0.0
	_sum_fps = 0.0
	_min_fps = 1.0e9
	_samples = 0


func _spawn_pile(n: int, parent: Node) -> void:
	var per_row := int(PIT * 2.0 / (BOX * 1.5))
	var placed := 0
	var tier := 0
	while placed < n:
		for gz in per_row:
			for gx in per_row:
				if placed >= n:
					break
				var b := Box3DBody.new()
				b.box_size = Vector3(BOX, BOX, BOX)
				b.density = 1.0
				b.friction = 0.6
				b.position = Vector3(
						-PIT + BOX + gx * (BOX * 1.5) + _rng.randf_range(-0.05, 0.05),
						SPAWN_Y + tier * (BOX * 1.3),
						-PIT + BOX + gz * (BOX * 1.5) + _rng.randf_range(-0.05, 0.05))
				parent.add_child(b)
				placed += 1
			if placed >= n:
				break
		tier += 1


func _physics_process(_delta: float) -> void:
	_ticks += 1
	if not _sampling:
		if _ticks >= SETTLE_TICKS:
			_sampling = true
			_ticks = 0
		return
	var step_ms: float
	if _have_profile:
		var prof: Dictionary = _world.get_profile()
		step_ms = prof.get("step", 0.0)
	else:
		step_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_sum_step += step_ms
	_max_step = maxf(_max_step, step_ms)
	var fps := Engine.get_frames_per_second()
	_sum_fps += fps
	_min_fps = minf(_min_fps, fps)
	_samples += 1
	if _ticks >= SAMPLE_TICKS:
		_finish_stage()


func _finish_stage() -> void:
	var target: int = STAGES[_stage]
	var awake := target
	if _world.has_method("get_awake_body_count"):
		awake = _world.get_awake_body_count()
	var contacts := 0
	if _world.has_method("get_counters"):
		var c: Dictionary = _world.get_counters()
		contacts = c.get("contacts", 0)
	var avg_step := _sum_step / float(maxi(_samples, 1))
	var avg_fps := _sum_fps / float(maxi(_samples, 1))
	if avg_step <= BUDGET_60_MS:
		_sus60 = target
	if avg_step <= BUDGET_30_MS:
		_sus30 = target
	if _rendered:
		if avg_fps >= 60.0:
			_gpu60 = target
		if avg_fps >= 30.0:
			_gpu30 = target
	_rows.append("%d,%d,%d,%.3f,%.3f,%.1f,%.1f" % [
			target, awake, contacts, avg_step, _max_step, avg_fps, _min_fps])
	print("[bench] bodies=%6d awake=%6d contacts=%8d  step avg=%6.2f max=%6.2fms  fps avg=%5.0f min=%5.0f" % [
			target, awake, contacts, avg_step, _max_step, avg_fps, _min_fps])
	var saturated := avg_step > STOP_STEP_MS or (_rendered and avg_fps < STOP_FPS)
	_stage += 1
	if saturated:
		print("[bench] saturated at %d bodies -- stopping escalation" % target)
		_report()
	elif _stage >= STAGES.size():
		_report()
	else:
		_begin_stage()


func _print_header() -> void:
	var mode := "cpu+gpu (windowed)" if _rendered else "cpu (headless)"
	var gpu := "n/a (headless)"
	if _rendered:
		gpu = "%s / %s / %s" % [RenderingServer.get_video_adapter_name(),
				RenderingServer.get_video_adapter_vendor(), _adapter_type()]
	print("[bench] Box3D dual stress benchmark -- mode=%s" % mode)
	print("[bench] cpu=%s cores=%d workers=%d godot=%s timer=%s" % [
			OS.get_processor_name(), OS.get_processor_count(), WORKERS,
			Engine.get_version_info()["string"],
			"extended" if _have_profile else "fallback"])
	print("[bench] gpu=%s multimesh=%s" % [
			gpu, "yes" if (_rendered and _have_mm) else "no"])
	print("[bench] columns: bodies,awake,contacts,step_avg_ms,step_max_ms,fps_avg,fps_min")


func _adapter_type() -> String:
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
			return "integrated"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			return "discrete"
		RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
			return "virtual"
		RenderingDevice.DEVICE_TYPE_CPU:
			return "cpu(llvmpipe)"
		_:
			return "other"


func _report() -> void:
	print("[bench] ---- summary ----")
	print("[bench] CPU solver: %d bodies @60 Hz, %d @30 Hz (step budget)" % [_sus60, _sus30])
	if _rendered:
		print("[bench] GPU render: %d bodies @60 fps, %d @30 fps (under combined load)" % [
				_gpu60, _gpu30])
	_write_csv()
	get_tree().quit()


func _write_csv() -> void:
	var path := "user://bench_stress.csv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[bench] could not open %s for writing" % path)
		return
	var gpu := "n/a"
	if _rendered:
		gpu = "%s (%s)" % [RenderingServer.get_video_adapter_name(), _adapter_type()]
	f.store_line("# mode=%s cpu=%s cores=%d workers=%d gpu=%s godot=%s timer=%s" % [
			"cpu+gpu" if _rendered else "cpu",
			OS.get_processor_name(), OS.get_processor_count(), WORKERS, gpu,
			Engine.get_version_info()["string"],
			"extended" if _have_profile else "fallback"])
	f.store_line("bodies,awake,contacts,step_avg_ms,step_max_ms,fps_avg,fps_min")
	for r in _rows:
		f.store_line(r)
	f.close()
	print("[bench] CSV: %s" % ProjectSettings.globalize_path(path))
