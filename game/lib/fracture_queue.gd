extends Node

## Global pacing for destruction. Panels and bricks enqueue their fracture
## callables here instead of running them all in the frame a blast lands;
## a fixed number execute per frame, so a 36-building nuke spreads its debris
## avalanche over ~a second (which also reads as a nice progressive collapse)
## instead of one giant frame spike.
##
## The pump node lives under the tree root, so it survives scene reloads;
## callables whose bodies died with the old scene fail is_valid() and are
## dropped.

const _Self = preload("res://lib/fracture_queue.gd")

const PER_FRAME := 20

static var _queue: Array[Callable] = []
static var _pump: Node = null


## Drop stale work and the pump itself. Deterministic runs (scene reloads,
## the CI harness) call this so run N+1 recreates the pump at the same tree
## position and frame as run 1 -- a surviving pump would pump debris in a
## different sibling order than the first run saw.
static func reset() -> void:
	_queue.clear()
	if _pump != null and is_instance_valid(_pump):
		_pump.queue_free()
	_pump = null


static func enqueue(tree: SceneTree, fracture: Callable) -> void:
	_queue.append(fracture)
	if _pump == null or not is_instance_valid(_pump):
		_pump = _Self.new()
		_pump.name = "FractureQueuePump"
		# Deferred: enqueue is called from physics contact dispatch.
		tree.root.add_child.call_deferred(_pump)


## Pumped per RENDER frame. Determinism scope, stated honestly: fracture
## pacing follows frame delivery, so bit-exact replays hold under the
## documented harness (`--fixed-fps 60`, fresh process — where frames and
## physics ticks are locked 1:1) and are NOT promised under free-running
## frame rates, which diverge engine-wide regardless of this queue.
func _process(_delta: float) -> void:
	var budget := PER_FRAME
	while budget > 0 and not _queue.is_empty():
		var fracture: Callable = _queue.pop_front()
		if fracture.is_valid():
			fracture.call()
			budget -= 1
