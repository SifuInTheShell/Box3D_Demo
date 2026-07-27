## Headless test runner for WindSim. Pure GDScript — no Box3D, runs anywhere:
##   godot --headless -s systems/wind/wind_sim_test.gd --path game
## The contract: seeded weather is a pure function of time; the breathing
## layer stays smooth and bounded; squalls genuinely happen (and veer) but
## never break the published bounds; dead calm stays exactly zero.
extends SceneTree

const WindSimRes = preload("res://systems/wind/wind_sim.gd")

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func _init() -> void:
	var base := Vector3(5.0, 0.0, 0.0)

	# --- 1. Calm and gustless -------------------------------------------------
	var calm := WindSimRes.new(7)
	check("dead calm is exactly zero", calm.sample(12.3) == Vector3.ZERO)
	check("calm gust01 is zero", calm.gust01() == 0.0)
	var steady := WindSimRes.new(7, base, 0.0)
	var drift := 0.0
	for t in 200:
		drift = maxf(drift, absf(steady.sample(t * 0.37).length() - 5.0))
	check("zero gust keeps base speed", drift < 1e-6, "max drift %f" % drift)

	# --- 2. Determinism ---------------------------------------------------------
	var a := WindSimRes.new(0x817D, base, 0.5)
	var b := WindSimRes.new(0x817D, base, 0.5)
	var same := true
	for i in 2000:
		var t := i * 0.31
		same = same and a.sample(t).is_equal_approx(b.sample(t))
	check("same seed, same weather (squalls included)", same)
	var c := WindSimRes.new(0x817E, base, 0.5)
	var differs := false
	for i in 100:
		differs = differs or a.sample(i * 0.31).distance_to(c.sample(i * 0.31)) > 0.05
	check("different seed, different weather", differs)
	for i in 60:
		a.update(1.0 / 30.0)
	check("update(dt) == sample(t)", a.current().is_equal_approx(b.sample(2.0)))

	# --- 3. Erratic, within bounds ----------------------------------------------
	var w := WindSimRes.new(0xCAB1, base, 0.5)
	var lo := INF
	var hi := 0.0
	var max_yaw := 0.0
	var vertical := 0.0
	var max_step := 0.0
	var prev := w.sample(0.0)
	var bad_gust01 := false
	for i in 60000:  # 30 minutes of weather at 30 Hz
		var t := i * (1.0 / 30.0)
		var v := w.sample(t)
		lo = minf(lo, v.length())
		hi = maxf(hi, v.length())
		max_yaw = maxf(max_yaw, absf(
				Vector2(v.x, v.z).angle_to(Vector2(base.x, base.z))))
		vertical = maxf(vertical, absf(v.y))
		max_step = maxf(max_step, v.distance_to(prev))
		prev = v
		w.update(0.0)
		var g: float = w.gust01()
		bad_gust01 = bad_gust01 or g < 0.0 or g > 1.0
	check("speed never breaks the published bound", hi <= w.speed_bound() + 1e-6,
			"%.2f vs bound %.2f" % [hi, w.speed_bound()])
	check("squalls genuinely happen", hi > 5.0 * 1.55,
			"peak %.2f m/s (breathing alone tops at 7.5)" % hi)
	check("lulls genuinely happen", lo < 5.0 * 0.75, "deepest %.2f m/s" % lo)
	check("lulls never go negative or die", lo >= 5.0 * WindSimRes.LULL_FLOOR - 1e-6)
	check("heading stays inside the veer bound", max_yaw <= w.veer_bound() + 1e-6,
			"max %.1f deg vs %.1f" % [rad_to_deg(max_yaw), rad_to_deg(w.veer_bound())])
	check("squalls veer beyond the calm meander", max_yaw > WindSimRes.MEANDER_RAD,
			"max %.1f deg" % rad_to_deg(max_yaw))
	check("wind stays horizontal", vertical == 0.0)
	check("no teleports between ticks", max_step < 1.2,
			"max %.2f m/s per 33 ms" % max_step)
	check("gust01 stayed in [0,1]", not bad_gust01)

	# --------------------------------------------------------------------------
	if failures == 0:
		print("\nAll wind_sim checks passed.")
	else:
		printerr("\n%d wind_sim check(s) FAILED." % failures)
	quit(1 if failures > 0 else 0)
