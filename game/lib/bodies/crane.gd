extends Node3D

## Tower-crane slewing rig. This node IS the pivot: every kinematic boom
## body (cab, apex, jib, counter-jib, counterweight, tie bars, trolley) is a
## child, so rotating this node slews the whole boom and Box3D sweeps each
## body to its target, pushing debris properly along the way. The wrecking
## ball hangs from the trolley on a real jointed cable (cable.gd), so
## slewing and trolley travel carry the ball with full pendulum physics.
##
##   G / H        slew the boom left / right
##   J / K        drive the trolley in / out along the jib
##   PgUp / PgDn  hoist the ball up / down (winches a rigid distance joint;
##                the chain goes slack above a raised ball, like real spare
##                cable)
##   arrows       pump the ball's swing (handled by destruction_gym)
##
## The mast below is static but shatterable: when any mast piece is
## demolished the boom loses its support, every kinematic part goes dynamic
## and the whole top comes crashing down, ball and cable included.

const CableLib := preload("res://lib/bodies/cable.gd")

const SLEW_SPEED := 0.65  # rad/s
const TROLLEY_SPEED := 3.6  # m/s
const TROLLEY_MIN := 3.5
const TROLLEY_MAX := 12.5
const HOIST_SPEED := 3.0  # m/s
const HOIST_MIN := 3.2
const HOIST_MAX := 14.5

## Shared spec for the winch cable; industrial_gen adds body_a/body_b.
const CABLE_OPTS := {
	"segment": 1.0, "radius": 0.075, "density": 24.0,
	"color": Color(0.2, 0.2, 0.22), "break_stretch": 2.6, "collide": true,
}

var mast_parts: Array[Node3D] = []
var trolley: Node3D = null
var hoist: Node = null
var ball: Node3D = null
var cable: Node3D = null
var trolley_r := 9.0  # ball rests well clear of the mast (see crane setback)
var hoist_len := 14.5
var _boom_live := true
var _winched := 0.0


func _key_down(code: Key) -> bool:
	return Input.is_physical_key_pressed(code) or Input.is_key_pressed(code)


func _physics_process(delta: float) -> void:
	if not _boom_live:
		return
	for m in mast_parts:
		if not is_instance_valid(m):
			_release_boom()
			return
	var slew := 0.0
	if _key_down(KEY_G):
		slew += 1.0
	if _key_down(KEY_H):
		slew -= 1.0
	if slew != 0.0:
		rotation.y += slew * SLEW_SPEED * delta
	var travel := 0.0
	if _key_down(KEY_J):
		travel -= 1.0
	if _key_down(KEY_K):
		travel += 1.0
	if travel != 0.0 and is_instance_valid(trolley):
		trolley_r = clampf(trolley_r + travel * TROLLEY_SPEED * delta,
				TROLLEY_MIN, TROLLEY_MAX)
		trolley.position.x = trolley_r
	var winch := 0.0
	if _key_down(KEY_PAGEUP):
		winch -= 1.0
	if _key_down(KEY_PAGEDOWN):
		winch += 1.0
	if winch != 0.0 and hoist != null and is_instance_valid(hoist):
		var prev := hoist_len
		hoist_len = clampf(hoist_len + winch * HOIST_SPEED * delta,
				HOIST_MIN, HOIST_MAX)
		hoist.length = hoist_len
		# Reel the visible chain in steps: rebuild it to the live trolley->
		# ball distance every ~metre of winching, like cable wrapping a drum.
		_winched += absf(hoist_len - prev)
		if _winched > 0.7:
			_rebuild_cable()


## Replace the chain with one matching the current trolley->ball distance.
func _rebuild_cable() -> void:
	_winched = 0.0
	if not (is_instance_valid(cable) and is_instance_valid(ball)
			and is_instance_valid(trolley)):
		return
	var world := cable.get_parent()
	cable.queue_free()
	var opts: Dictionary = CABLE_OPTS.duplicate()
	opts["body_a"] = trolley
	opts["body_b"] = ball
	cable = CableLib.spawn(world, trolley.global_position - Vector3(0, 0.2, 0),
			ball.global_position + Vector3(0, 0.9, 0), opts)


## Part of the mast is gone: nothing holds the boom up. Every kinematic
## boom part goes dynamic, and so do the surviving static mast pieces --
## otherwise they would hover where the explosion left them.
##
## Do NOT reparent the parts out of this node: a Box3DBody only creates its
## physics body on its one-and-only READY, so exit/re-enter leaves it
## bodiless and frozen in the air. Instead the pivot itself collapses to
## identity and each child's world pose is baked into its local transform --
## with an identity parent, the dynamic sync's world-space writes are
## exactly right and nothing double-transforms.
func _release_boom() -> void:
	_boom_live = false
	var poses := {}
	for c in get_children():
		if c is Box3DBody and is_instance_valid(c):
			poses[c] = c.global_transform
	global_transform = Transform3D.IDENTITY
	for c in poses:
		c.global_transform = poses[c]
		c.body_type = Box3DBody.DYNAMIC
	for m in mast_parts:
		if is_instance_valid(m):
			m.body_type = Box3DBody.DYNAMIC
