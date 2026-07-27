## Headless test runner for FireSim. Pure GDScript — no Box3D, runs anywhere:
##   godot --headless -s systems/fire/fire_sim_test.gd --path game
## Behaviors under test come from docs/fire-research.md.
extends SceneTree

## Explicit preload: `-s` runs skip the project scan that registers
## class_name globals, so the global FireSim identifier may not exist here.
const FireSim = preload("res://systems/fire/fire_sim.gd")

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


## Steps until the item ignites; returns elapsed seconds (INF = never).
func time_to_ignite(sim: FireSim, id: int, limit := 120.0, dt := 0.2) -> float:
	var t := 0.0
	while t < limit:
		sim.step(dt)
		t += dt
		if sim.state(id) == FireSim.BURNING:
			return t
	return INF


func plank(sim: FireSim, id: int, pos: Vector3, moisture := 0.0) -> void:
	sim.add_item(id, pos, Vector3(0.5, 0.5, 0.03), moisture)


func _init() -> void:
	# --- 1. Ignition threshold: nothing burns without enough heat -------------
	var sim := FireSim.new()
	plank(sim, 1, Vector3.ZERO)
	sim.add_heat(Vector3.ZERO, 2.0, 100.0)  # a warm nudge, far below ignition
	sim.step(0.2)
	check("small heat pulse does not ignite", sim.state(1) == FireSim.COLD)
	sim.add_heat(Vector3.ZERO, 2.0, 1e6)
	check("big heat pulse ignites", sim.state(1) == FireSim.BURNING)
	check("ignition event emitted",
			sim.events.any(func(e): return e["event"] == "ignited"))

	# --- 2. Cooling: sub-ignition heat decays back toward ambient -------------
	sim = FireSim.new()
	plank(sim, 1, Vector3.ZERO)
	sim.add_heat(Vector3.ZERO, 2.0, 3000.0)
	var warm: float = sim.items[1]["temp"]
	check("pulse warmed the plank", warm > FireSim.T_AMBIENT + 20.0, str(warm))
	for i in 300:
		sim.step(0.2)
	check("unfed warmth cools off",
			sim.items[1]["temp"] < warm * 0.35, str(sim.items[1]["temp"]))

	# --- 3. Thin fuel ignites before thick fuel -------------------------------
	sim = FireSim.new()
	sim.add_item(10, Vector3(1.2, 0.0, 0.0), Vector3(0.5, 0.5, 0.02))   # kindling
	sim.add_item(11, Vector3(-1.2, 0.0, 0.0), Vector3(0.5, 0.5, 0.22))  # beam
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.ignite(1)
	var t_thin := time_to_ignite(sim, 10)
	sim = FireSim.new()
	sim.add_item(10, Vector3(1.2, 0.0, 0.0), Vector3(0.5, 0.5, 0.02))
	sim.add_item(11, Vector3(-1.2, 0.0, 0.0), Vector3(0.5, 0.5, 0.22))
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.ignite(1)
	var t_thick := time_to_ignite(sim, 11)
	check("thin ignites before thick", t_thin < t_thick,
			"thin %.1fs thick %.1fs" % [t_thin, t_thick])

	# --- 4. Wet wood ignites later than dry wood ------------------------------
	sim = FireSim.new()
	plank(sim, 10, Vector3(1.2, 0.0, 0.0))
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.ignite(1)
	var t_dry := time_to_ignite(sim, 10)
	sim = FireSim.new()
	plank(sim, 10, Vector3(1.2, 0.0, 0.0), 0.6)
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.ignite(1)
	var t_wet := time_to_ignite(sim, 10)
	check("dry ignites before wet", t_dry < t_wet,
			"dry %.1fs wet %.1fs" % [t_dry, t_wet])

	# --- 5. Fire climbs: above beats lateral beats below ----------------------
	var times := {}
	for probe in [["up", Vector3(0.0, 1.6, 0.0)], ["side", Vector3(1.6, 0.0, 0.0)],
			["down", Vector3(0.0, -1.6, 0.0)]]:
		sim = FireSim.new()
		sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
		plank(sim, 10, probe[1])
		sim.ignite(1)
		times[probe[0]] = time_to_ignite(sim, 10, 240.0)
	check("upward spread fastest", times["up"] < times["side"],
			"up %.1fs side %.1fs" % [times["up"], times["side"]])
	check("downward spread slowest", times["side"] < times["down"],
			"side %.1fs down %.1fs" % [times["side"], times["down"]])

	# --- 6. Wind biases spread downwind ---------------------------------------
	sim = FireSim.new()
	sim.wind = Vector3(6.0, 0.0, 0.0)
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	plank(sim, 10, Vector3(1.7, 0.0, 0.0))   # downwind
	plank(sim, 11, Vector3(-1.7, 0.0, 0.0))  # upwind
	sim.ignite(1)
	var t_down_wind := time_to_ignite(sim, 10, 240.0)
	sim = FireSim.new()
	sim.wind = Vector3(6.0, 0.0, 0.0)
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	plank(sim, 10, Vector3(1.7, 0.0, 0.0))
	plank(sim, 11, Vector3(-1.7, 0.0, 0.0))
	sim.ignite(1)
	var t_up_wind := time_to_ignite(sim, 11, 240.0)
	check("downwind ignites before upwind", t_down_wind < t_up_wind,
			"downwind %.1fs upwind %.1fs" % [t_down_wind, t_up_wind])

	# --- 7. Firebreak: no spread across a wide gap ----------------------------
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	plank(sim, 10, Vector3(9.0, 0.0, 0.0))
	sim.ignite(1)
	check("no spread across 9 m gap",
			time_to_ignite(sim, 10, 120.0) == INF)

	# --- 8. Contact spreads faster than a small air gap -----------------------
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.add_item(10, Vector3(0.95, 0.0, 0.0), Vector3(0.5, 0.5, 0.03))  # touching
	sim.ignite(1)
	var t_touch := time_to_ignite(sim, 10)
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	sim.add_item(10, Vector3(1.75, 0.0, 0.0), Vector3(0.5, 0.5, 0.03))  # gapped
	sim.ignite(1)
	var t_gap := time_to_ignite(sim, 10)
	check("touching ignites before gapped", t_touch < t_gap,
			"touch %.1fs gap %.1fs" % [t_touch, t_gap])

	# --- 9. Charring weakens, then burns out ----------------------------------
	sim = FireSim.new()
	plank(sim, 1, Vector3.ZERO)
	sim.ignite(1)
	check("full strength before burning", absf(sim.strength(1) - 1.0) < 1e-6)
	sim.step(5.0)
	var s_early := sim.strength(1)
	sim.step(5.0)
	var s_late := sim.strength(1)
	check("strength falls while burning", s_late < s_early and s_early < 1.0,
			"%.2f -> %.2f" % [s_early, s_late])
	var guard := 0
	while sim.state(1) == FireSim.BURNING and guard < 4000:
		sim.step(0.2)
		guard += 1
	check("plank burns out", sim.state(1) == FireSim.BURNT_OUT)
	check("burnt out means zero strength", sim.strength(1) < 1e-6)
	check("burnout event emitted",
			sim.events.any(func(e): return e["event"] == "burnout"))

	# --- 10. Burnout ends spread: neighbours stop receiving flux --------------
	sim = FireSim.new()
	plank(sim, 1, Vector3.ZERO)
	sim.add_item(10, Vector3(0.0, 2.0, 0.0), Vector3(0.5, 0.5, 0.5), 0.0, 1.0)
	sim.ignite(1)
	guard = 0
	while sim.state(1) == FireSim.BURNING and guard < 4000:
		sim.step(0.2)
		guard += 1
	var temp_at_burnout: float = sim.items[10]["temp"]
	for i in 100:
		sim.step(0.2)
	check("no heating from a burnt-out item",
			sim.items[10]["temp"] <= temp_at_burnout + 0.01)

	# --- 11. Dousing: flaming -> smoldering -> rekindle; hard douse kills -----
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.5, 0.5, 0.1))
	sim.ignite(1)
	for i in 40:
		sim.step(0.2)  # build up char so the coals stay hot
	sim.douse(1, 0.6)
	check("light douse leaves smoldering coals",
			sim.state(1) == FireSim.SMOLDERING)
	guard = 0
	while sim.state(1) == FireSim.SMOLDERING and guard < 2000:
		sim.step(0.2)
		guard += 1
	check("unattended coals rekindle", sim.state(1) == FireSim.BURNING)
	sim.douse(1, 1.2)
	sim.douse(1, 1.2)
	check("hard douse puts the fire out fully",
			sim.state(1) == FireSim.COLD or sim.state(1) == FireSim.SMOLDERING)
	if sim.state(1) == FireSim.SMOLDERING:
		sim.douse(1, 1.2)
		check("soaked coals die", sim.state(1) == FireSim.COLD)

	# --- 12. Chain propagation: a fire line travels down a fence --------------
	sim = FireSim.new()
	for i in 6:
		sim.add_item(100 + i, Vector3(i * 0.9, 0.0, 0.0), Vector3(0.45, 0.5, 0.03))
	sim.ignite(100)
	var ignition_order: Array = []
	var t := 0.0
	while t < 240.0 and ignition_order.size() < 5:
		sim.step(0.2)
		t += 0.2
		for e in sim.events:
			if e["event"] == "ignited":
				ignition_order.append(e["id"])
	check("fire line reaches the far post", ignition_order.size() >= 5,
			str(ignition_order))
	var ordered := true
	for i in ignition_order.size() - 1:
		if ignition_order[i + 1] < ignition_order[i]:
			ordered = false
	check("fence burns in order", ordered, str(ignition_order))

	# --- 13. Moving fuel: update_pos carries the fire with the body -----------
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.4, 0.4, 0.4))
	plank(sim, 10, Vector3(20.0, 0.0, 0.0))
	sim.ignite(1)
	for i in 10:
		sim.step(0.2)
	check("far plank untouched", sim.state(10) == FireSim.COLD)
	sim.update_pos(10, Vector3(1.0, 0.5, 0.0))  # debris lands beside the fire
	check("moved plank ignites", time_to_ignite(sim, 10) < INF)

	# --- 14. Determinism: identical runs, identical state hash ----------------
	var hashes: Array = []
	for run in 2:
		sim = FireSim.new()
		sim.wind = Vector3(2.0, 0.0, 1.0)
		for i in 12:
			sim.add_item(i, Vector3((i % 4) * 1.1, (i / 4) * 1.0, 0.0),
					Vector3(0.5, 0.45, 0.04), 0.1 * (i % 3))
		sim.ignite(0)
		for i in 400:
			sim.step(0.2)
		hashes.append(sim.state_hash())
	check("two identical runs hash identically", hashes[0] == hashes[1],
			"%d vs %d" % [hashes[0], hashes[1]])

	# --- 15. Force-ignite respects burnout ------------------------------------
	sim = FireSim.new()
	sim.add_item(1, Vector3.ZERO, Vector3(0.5, 0.5, 0.02))
	sim.ignite(1)
	guard = 0
	while sim.state(1) != FireSim.BURNT_OUT and guard < 4000:
		sim.step(0.2)
		guard += 1
	sim.ignite(1)
	check("ash cannot reignite", sim.state(1) == FireSim.BURNT_OUT)

	print("")
	if failures == 0:
		print("ALL %s CHECKS PASSED" % "fire_sim")
	else:
		printerr("%d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
