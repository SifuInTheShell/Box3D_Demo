## Settling detector (core-math §5.1): settled when the caller-supplied max
## debris speed has stayed below eps for `hold_s` continuously; any spike
## resets the hold. The caller polls its bodies and feeds max speed + elapsed
## dt — no engine dependency, headless-testable.
class_name SettleDetector

const DM = preload("res://systems/demolition/demo_math.gd")

var eps := DM.SETTLE_SPEED
var hold_s := DM.SETTLE_TIME
var timeout_s := 45.0

var _below := 0.0
var _elapsed := 0.0


func reset() -> void:
	_below = 0.0
	_elapsed = 0.0


## Feed the current max speed over all watched bodies. Returns true once
## settled (stays true until reset).
func update(max_speed: float, dt: float) -> bool:
	_elapsed += dt
	if max_speed < eps:
		_below += dt
	else:
		_below = 0.0
	return settled()


func settled() -> bool:
	return _below >= hold_s


func timed_out() -> bool:
	return _elapsed >= timeout_s and not settled()
