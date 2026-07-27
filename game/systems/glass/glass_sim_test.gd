## Headless test runner for GlassSim. Pure GDScript — no Box3D, runs anywhere:
##   godot --headless -s systems/glass/glass_sim_test.gd --path game
## Behaviors under test come from docs/glass-research.md.
extends SceneTree

const GlassSim = preload("res://systems/glass/glass_sim.gd")

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func _init() -> void:
	# --- 1. Overpressure physics ----------------------------------------------
	check("overpressure falls with distance",
			GlassSim.overpressure_kpa(10.0, 10.0) > GlassSim.overpressure_kpa(10.0, 30.0))
	check("overpressure grows with charge",
			GlassSim.overpressure_kpa(50.0, 20.0) > GlassSim.overpressure_kpa(5.0, 20.0))
	var r5 := GlassSim.break_distance(5.36)    # the gym's small charge
	var r34 := GlassSim.break_distance(34.3)   # medium
	var r125 := GlassSim.break_distance(125.0) # large
	check("break radius grows with charge", r5 < r34 and r34 < r125,
			"%.0f / %.0f / %.0f m" % [r5, r34, r125])
	check("break radius consistent with the fit",
			absf(GlassSim.overpressure_kpa(34.3, r34) - GlassSim.BREAK_KPA) < 0.1,
			str(GlassSim.overpressure_kpa(34.3, r34)))
	# The collateral indicator: the medium charge fractures masonry to 6.5 m
	# (CHARGE_SPECS) but must rain glass much further than that.
	check("glass breaks far beyond structural damage", r34 > 6.5 * 3.0,
			"glass %.0f m vs structure 6.5 m" % r34)

	# --- 2. Blast breakage + ledger -------------------------------------------
	var sim := GlassSim.new()
	sim.add_pane(1, Vector3(8.0, 2.0, 0.0), 1.2, "target")
	sim.add_pane(2, Vector3(r34 * 0.7, 2.0, 0.0), 1.2, "protected")
	sim.add_pane(3, Vector3(r34 * 2.0, 2.0, 0.0), 1.2, "protected")
	var broken: Array = sim.blast(Vector3.ZERO, 34.3)
	check("panes inside the radius break", broken.has(1) and broken.has(2))
	check("panes beyond the radius survive", not broken.has(3) and sim.has_pane(3))
	check("nearest pane breaks first", broken[0] == 1, str(broken))
	check("ledger counts by tag",
			sim.broken("target")["count"] == 1 and sim.broken("protected")["count"] == 1)
	check("ledger tracks area",
			absf(sim.broken("target")["area"] - 1.2) < 1e-6)
	check("ledger tracks cause",
			sim.broken("protected")["by_cause"].get("blast", 0) == 1)
	check("total across tags", sim.total_broken() == 2)

	# --- 3. Impact breakage ---------------------------------------------------
	sim = GlassSim.new()
	sim.add_pane(1, Vector3.ZERO, 1.0)
	check("slow contact spares the pane", not sim.impact(1, 1.0))
	check("pane still registered", sim.has_pane(1))
	check("fast contact breaks it", sim.impact(1, 4.0))
	check("impact tallied",
			sim.broken("neutral")["by_cause"].get("impact", 0) == 1)

	# --- 4. Thermal breakage: pulses accumulate, cooling saves ----------------
	sim = GlassSim.new()
	sim.add_pane(1, Vector3(1.0, 0.0, 0.0), 1.0)
	var popped := false
	for i in 12:
		if not sim.add_heat(Vector3.ZERO, 4.0, 30.0).is_empty():
			popped = true
			break
	check("steady fire heat pops the pane", popped)
	sim = GlassSim.new()
	sim.add_pane(1, Vector3(1.0, 0.0, 0.0), 1.0)
	popped = false
	for i in 12:
		if not sim.add_heat(Vector3.ZERO, 4.0, 30.0).is_empty():
			popped = true
			break
		sim.cool(60.0)  # long gaps: the pane sheds the heat between pulses
	check("spaced pulses with cooling do not", not popped)
	sim = GlassSim.new()
	sim.add_pane(1, Vector3(9.0, 0.0, 0.0), 1.0)
	for i in 30:
		sim.add_heat(Vector3.ZERO, 4.0, 30.0)
	check("heat respects the radius", sim.has_pane(1))

	# --- 5. Moving panes ------------------------------------------------------
	sim = GlassSim.new()
	sim.add_pane(1, Vector3(5.0, 0.0, 0.0), 1.0)
	sim.update_pos(1, Vector3(500.0, 0.0, 0.0))
	check("moved pane escapes the blast",
			sim.blast(Vector3.ZERO, 34.3).is_empty())

	# --- 6. Shatter pattern ---------------------------------------------------
	var size := Vector2(1.1, 0.9)
	var pat: Array = GlassSim.shatter_pattern(size, Vector2(-0.35, 0.1), 0.8)
	var area := 0.0
	var inside := true
	for s in pat:
		area += s["size"].x * s["size"].y
		var off: Vector2 = s["off"]
		var half: Vector2 = s["size"] * 0.5
		if absf(off.x) + half.x > size.x * 0.5 + 1e-4 \
				or absf(off.y) + half.y > size.y * 0.5 + 1e-4:
			inside = false
	check("shards tile the pane area", absf(area - size.x * size.y) < 1e-4,
			"%.4f vs %.4f" % [area, size.x * size.y])
	check("shards stay inside the pane", inside)
	var few: Array = GlassSim.shatter_pattern(size, Vector2.ZERO, 0.0)
	check("harder hits mean more shards", pat.size() > few.size(),
			"%d vs %d" % [pat.size(), few.size()])
	# Impact on the left: left-side shards come out finer than right-side.
	var left := 0.0
	var nl := 0
	var right := 0.0
	var nr := 0
	for s in pat:
		if s["off"].x < 0.0:
			left += s["size"].x
			nl += 1
		else:
			right += s["size"].x
			nr += 1
	check("shards are finer near the impact",
			nl > 0 and nr > 0 and left / nl < right / nr,
			"avg w %.3f vs %.3f" % [left / maxf(nl, 1), right / maxf(nr, 1)])

	# --- 7. Determinism -------------------------------------------------------
	var a := GlassSim.shatter_pattern(size, Vector2(0.2, -0.1), 0.5)
	var b := GlassSim.shatter_pattern(size, Vector2(0.2, -0.1), 0.5)
	check("pattern is deterministic", str(a) == str(b))

	print("")
	if failures == 0:
		print("ALL %s CHECKS PASSED" % "glass_sim")
	else:
		printerr("%d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
