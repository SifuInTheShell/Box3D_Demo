extends "res://scenes/demo/city_gym.gd"

## Headless settle check: builds the 6x6 city, reports panel count and peak
## panel speed every 2 s for 20 s, then quits. No input, no interference:
##   Godot --headless --path game res://scenes/test/settle_test.tscn

var _t := 0.0
var _next_report := 2.0
var _peak_panels := 0  # high-water mark: a drop means something self-destructed


func _init() -> void:
	grid_size = 6


func _process(delta: float) -> void:
	super(delta)
	_t += delta
	if _t < _next_report:
		return
	_next_report += 2.0
	var vmax := 0.0
	var n := 0
	for p in get_tree().get_nodes_in_group("panel"):
		vmax = maxf(vmax, p.get_linear_velocity().length())
		n += 1
	_peak_panels = maxi(_peak_panels, n)
	print("[settle] t=%2.0fs panels=%d blocks=%d vmax=%.3f" % [
		_t, n, get_tree().get_nodes_in_group("block").size(), vmax])
	if _t >= 20.0:
		# Stable = nothing self-destructed at spawn (count held at its peak) and
		# the city came fully to rest. Robust to changes in the generated count.
		var stable := n > 0 and n == _peak_panels and vmax < 0.05
		print("[settle] RESULT -> %s (panels %d/%d, vmax %.3f)" % [
			"STABLE" if stable else "UNSTABLE", n, _peak_panels, vmax])
		# The exit code IS the verdict — CI must be able to gate on it.
		get_tree().quit(0 if stable else 1)
