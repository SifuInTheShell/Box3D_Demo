## Headless test runner for DemoMath. Pure GDScript — no Box3D, runs anywhere:
##   godot --headless -s systems/demolition/demo_math_test.gd --path game
## Expected values come from the validated Python reference (docs/core-math.md).
extends SceneTree

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _init() -> void:
	# 1. Charge scaling
	check("radius doubles per 8x mass",
			approx(DemoMath.charge_radius(8.0) / DemoMath.charge_radius(1.0), 2.0, 1e-9))

	# 2. Vibration
	check("PPV(50m, 10kg) ~= 13.76 mm/s", approx(DemoMath.ppv(50.0, 10.0), 13.76, 0.05),
			str(DemoMath.ppv(50.0, 10.0)))
	check("PPV monotonic in W", DemoMath.ppv(50.0, 20.0) > DemoMath.ppv(50.0, 10.0))
	check("PPV monotonic in D", DemoMath.ppv(25.0, 10.0) > DemoMath.ppv(50.0, 10.0))

	var p := Vector3.ZERO
	var charges: Array = [
		{"time_ms": 0.0, "mass_kg": 4.0, "position": p},
		{"time_ms": 5.0, "mass_kg": 4.0, "position": p},
		{"time_ms": 20.0, "mass_kg": 2.0, "position": p},
		{"time_ms": 26.0, "mass_kg": 2.0, "position": p},
		{"time_ms": 100.0, "mass_kg": 8.0, "position": p},
	]
	var groups := DemoMath.group_charges(charges)
	var group_masses: Array = groups.map(func(g): return g["mass_kg"])
	check("8ms grouping = [8, 4, 8]", group_masses == [8.0, 4.0, 8.0], str(group_masses))

	var sensor := [Vector3(30.0, 0.0, 0.0)]
	var seq := DemoMath.max_ppv(charges, sensor)
	var simul := DemoMath.ppv(30.0, 20.0)
	check("sequenced peak ~= 26.06 mm/s", approx(seq, 26.06, 0.1), str(seq))
	check("sequencing beats simultaneous (54.24)", seq < simul, str(simul))

	# 3. Support graph
	var masses := {"roof": 1000.0, "colL": 100.0, "colR": 100.0}
	var supports := {"roof": ["colL", "colR"], "colL": ["ground"], "colR": ["ground"]}
	var loads := DemoMath.support_loads(masses, supports)
	check("portal frame: colL->ground = 600 kg",
			approx(loads["weld_load"]["colL->ground"], 600.0, 1e-6))
	check("portal frame: colR->ground = 600 kg",
			approx(loads["weld_load"]["colR->ground"], 600.0, 1e-6))
	var ground_total: float = loads["weld_load"]["colL->ground"] \
			+ loads["weld_load"]["colR->ground"]
	check("ground carries total mass", approx(ground_total, 1200.0, 1e-6))
	check("utilization(600kg, 0.09m2) ~= 0.0327",
			approx(DemoMath.weld_utilization(600.0, 0.09), 0.0327, 0.0005))

	# 3b. Area-weighted distribution + bending (validated Python reference)
	var wl := DemoMath.support_loads_weighted(masses, supports,
			{"roof->colL": 0.09, "roof->colR": 0.03})
	check("area-weighted split 750/250",
			approx(wl["weld_load"]["roof->colL"], 750.0, 1e-6)
			and approx(wl["weld_load"]["roof->colR"], 250.0, 1e-6))
	var mu := 1800.0 * 0.4 * 0.4    # brick-row linear density kg/m
	var lmax := DemoMath.max_cantilever(mu, 0.4, 0.4)
	check("masonry max cantilever ~1.23m (~3 bricks: derives span_max)",
			approx(lmax, 1.23, 0.02), str(lmax))
	var arm := 3 * 0.4
	check("bare 3-brick arm holds",
			DemoMath.bending_ok(DemoMath.cantilever_moment(mu, arm), 0.4, 0.4))
	check("3-brick arm + 500kg tip fails (mass-aware)",
			not DemoMath.bending_ok(DemoMath.cantilever_moment(mu, arm, 500.0), 0.4, 0.4))

	# 4. Toppling
	check("tip_speed(30) ~= 29.71", approx(DemoMath.tip_speed(30.0), 29.71, 0.02))
	check("free_fall_time < tip arrival speed relation",
			DemoMath.tip_speed(30.0) > sqrt(2.0 * DemoMath.GRAVITY * 30.0))
	var t1 := DemoMath.tip_time(30.0, deg_to_rad(1.0))
	var t5 := DemoMath.tip_time(30.0, deg_to_rad(5.0))
	check("tip_time(30m, 1deg) ~= 7.49 s", approx(t1, 7.49, 0.05), str(t1))
	check("more lean falls sooner", t5 < t1, "%s < %s" % [t5, t1])
	check("fell strip 30m -> 34.5m", approx(DemoMath.fell_strip_length(30.0), 34.5, 1e-9))

	# 5. Hash
	var a := DemoMath.state_hash(PackedFloat64Array([1.00004, 2.0, -3.5]))
	var b := DemoMath.state_hash(PackedFloat64Array([1.00003, 2.0, -3.5]))
	var c := DemoMath.state_hash(PackedFloat64Array([1.2, 2.0, -3.5]))
	check("hash stable under sub-quantum jitter", a == b)
	check("hash differs for real change", a != c)

	print("")
	if failures == 0:
		print("ALL PASS")
	else:
		printerr("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
