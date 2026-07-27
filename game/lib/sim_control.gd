extends Node

## Fixed-tick simulation driver: owns stepping a
## Box3DWorld deterministically. auto_step is off; this node calls
## step(TICK_DT) from _physics_process, counts ticks, and fires per-tick
## callbacks -- the tick counter is the only clock, so a plan replayed
## against the same world produces the same collapse, bit for bit
## (worker_count 1, fixed substeps, seeded RNG everywhere else).
##
##   var sim := SimControl.attach(world)   # before bodies are added
##   sim.on_tick = func(t): ...            # detonation schedules etc.
##   sim.state_hash()                      # FNV-1a over quantized transforms

const _Self = preload("res://lib/sim_control.gd")

const TICK_DT := 1.0 / 60.0
const SUBSTEPS := 4

var world: Node3D
var tick := 0
var running := true
var on_tick: Callable = Callable()


static func attach(p_world: Node3D) -> Node:
	var sim := _Self.new()
	sim.world = p_world
	p_world.auto_step = false
	p_world.substep_count = SUBSTEPS
	p_world.worker_count = 1  # determinism over throughput in assessed runs
	p_world.add_child(sim)
	return sim


func _physics_process(_delta: float) -> void:
	if not running or world == null or not is_instance_valid(world):
		return
	world.step(TICK_DT)
	tick += 1
	if on_tick.is_valid():
		on_tick.call(tick)


## FNV-1a 64-ish digest of every dynamic body's quantized transform, in tree
## order (deterministic builds -> deterministic order). 1e-3 quantization
## absorbs float printing, not solver divergence.
func state_hash() -> int:
	var h := 0x4BF29CE484222325
	for body in world.find_children("*", "Box3DBody", true, false):
		if body.body_type != body.DYNAMIC:
			continue
		var xf: Transform3D = body.global_transform
		for v in [xf.origin, xf.basis.x, xf.basis.y, xf.basis.z]:
			for i in 3:
				h = ((h ^ (int(round(v[i] * 1000.0)) & 0xFFFFFFFF)) * 0x100000001B3) \
						& 0xFFFFFFFFFFFFFF
	return h
