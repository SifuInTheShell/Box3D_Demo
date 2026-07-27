## Headless test runner for AmbientSim. Pure GDScript — no Box3D, runs anywhere:
##   godot --headless -s systems/ambient/ambient_sim_test.gd --path game
## The property under test: the ambient layer is cosmetic, but it must be
## deterministic under a fixed seed.
extends SceneTree

const AmbientSimRes = preload("res://systems/ambient/ambient_sim.gd")

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func _make_flock(seed_v: int, count := 10) -> AmbientSimRes.Flock:
	var f := AmbientSimRes.Flock.new(seed_v)
	f.set_perches([
		Vector3(0, 8, 0), Vector3(6, 9, 2), Vector3(-5, 7, 4),
		Vector3(10, 6, -6), Vector3(-8, 8, -8), Vector3(3, 10, 9),
	])
	f.spawn(count)
	return f


func _init() -> void:
	var dt := 1.0 / 30.0

	# --- 1. Flock: spawn + idle -----------------------------------------------
	var flock := _make_flock(7)
	check("birds spawn perched", flock.perched_count() == 10)
	var on_perch := true
	for i in 10:
		var near := false
		for p in flock.perches:
			if flock.position(i).distance_to(p) < 1.0:
				near = true
		on_perch = on_perch and near
	check("birds spawn on the perch set", on_perch)

	var wandered := false
	for s in int(90.0 / dt):  # 90 s idle: hops must happen, bounds must hold
		flock.update(dt)
		if flock.perched_count() < 10:
			wandered = true
	check("idle birds relocate now and then", wandered)
	var bounded := true
	var finite := true
	for i in 10:
		bounded = bounded and flock.position(i).length() < 40.0
		finite = finite and flock.position(i).is_finite()
	check("idle birds stay near the site", bounded)
	check("no NaN in positions", finite)

	# --- 2. Flock: determinism ------------------------------------------------
	var a := _make_flock(0xB1AD)
	var b := _make_flock(0xB1AD)
	for s in int(60.0 / dt):
		a.update(dt)
		b.update(dt)
	var same := true
	for i in 10:
		same = same and a.position(i).is_equal_approx(b.position(i))
	check("same seed, same flock", same)
	var c := _make_flock(0xB1AE)
	for s in int(60.0 / dt):
		c.update(dt)
	var differs := false
	for i in 10:
		differs = differs or a.position(i).distance_to(c.position(i)) > 0.5
	check("different seed, different flock", differs)

	# --- 3. Flock: scatter + resettle -----------------------------------------
	flock = _make_flock(11)
	var blast := Vector3(2.0, 1.0, 1.0)
	var before: Array = []
	for i in 10:
		before.append(flock.position(i).distance_to(blast))
	flock.disturb(blast, 100.0)
	check("everyone in radius flees", flock.perched_count() == 0)
	for s in int(1.5 / dt):
		flock.update(dt)
	var fled := true
	var climbed := true
	for i in 10:
		fled = fled and flock.position(i).distance_to(blast) > before[i]
		climbed = climbed and flock.velocity(i).y >= 0.0
	check("fleers move away from the blast", fled)
	check("fleers climb, never dive", climbed)

	flock = _make_flock(11)
	flock.disturb(Vector3(100.0, 0.0, 0.0), 5.0)  # far blast, small radius
	check("out-of-radius birds ignore it", flock.perched_count() == 10)

	flock = _make_flock(11)
	flock.disturb(blast, 100.0)
	for s in int(120.0 / dt):
		flock.update(dt)
	check("the flock resettles", flock.perched_count() >= 8,
			"%d/10 perched after 120 s" % flock.perched_count())

	# Airborne birds drift with the weather; perched birds ignore it. The
	# window stays under HOP_MIN so nobody takes off: gripping a ridge in a
	# gale must not slide a bird sideways.
	var still := _make_flock(13)
	var windy := _make_flock(13)
	windy.wind = Vector3(6.0, 0.0, 0.0)
	for s in int(5.0 / dt):
		still.update(dt)
		windy.update(dt)
	var pinned := true
	for i in 10:
		pinned = pinned and windy.position(i).is_equal_approx(still.position(i))
	check("perched birds ignore wind", pinned)
	still = _make_flock(13)
	windy = _make_flock(13)
	windy.wind = Vector3(6.0, 0.0, 0.0)
	still.disturb(Vector3.ZERO, 100.0)
	windy.disturb(Vector3.ZERO, 100.0)
	for s in int(2.0 / dt):
		still.update(dt)
		windy.update(dt)
	var drift := 0.0
	for i in 10:
		drift += windy.position(i).x - still.position(i).x
	check("fleeing birds blow downwind", drift / 10.0 > 2.0 * 0.9,
			"mean +%.1f m over 2 s" % (drift / 10.0))

	# --- 4. Windows: draw, fraction, darkening --------------------------------
	var win := AmbientSimRes.Windows.new(5, 0.4)
	var lit := 0
	for id in 400:
		if win.add_window(id, id / 100):  # 4 buildings x 100 windows
			lit += 1
	check("lit fraction lands near the request", absf(lit / 400.0 - 0.4) < 0.08,
			"%d/400 lit" % lit)
	check("ledger agrees", win.lit_count() == lit and win.count() == 400)

	var win2 := AmbientSimRes.Windows.new(5, 0.4)
	var same_draw := true
	for id in 400:
		var was: bool = win.is_lit(id)
		same_draw = same_draw and win2.add_window(id, id / 100) == was
	check("same seed, same windows", same_draw)

	var first_lit := -1
	for id in 400:
		if win.is_lit(id):
			first_lit = id
			break
	win.darken(first_lit)
	check("a broken window goes dark", not win.is_lit(first_lit))
	check("darkening is counted", win.lit_count() == lit - 1)
	var b0_lit := 0
	for id in 100:
		if win.is_lit(id):
			b0_lit += 1
	win.darken_building(0)
	var b0_after := 0
	for id in 100:
		if win.is_lit(id):
			b0_after += 1
	check("power loss darkens the whole building", b0_after == 0, "was %d lit" % b0_lit)
	# b0_lit was counted after the single darken, so the remainder is exact.
	check("other buildings keep their lights", win.lit_count() == lit - 1 - b0_lit)

	# --- 5. OneShots: intervals -----------------------------------------------
	var shots := AmbientSimRes.OneShots.new(3)
	shots.add_voice("birdsong", 4.0, 9.0)
	shots.add_voice("dog", 15.0, 40.0)
	var t := 0.0
	var first_at := -1.0
	var events := 0
	while t < 120.0:
		var fired: Array = shots.step(dt)
		t += dt
		if not fired.is_empty() and first_at < 0.0 and fired.has("birdsong"):
			first_at = t
		events += fired.size()
	check("no voice fires before its minimum gap", first_at >= 4.0, "first %.1f s" % first_at)
	check("birdsong fires by its maximum gap", first_at <= 9.0 + dt, "first %.1f s" % first_at)
	check("voices keep firing", events >= 12, "%d events in 120 s" % events)

	var s1 := AmbientSimRes.OneShots.new(9)
	var s2 := AmbientSimRes.OneShots.new(9)
	for nm in ["birdsong", "dog", "chatter"]:
		s1.add_voice(nm, 3.0, 12.0)
		s2.add_voice(nm, 3.0, 12.0)
	var seq_same := true
	for s in int(90.0 / dt):
		seq_same = seq_same and s1.step(dt) == s2.step(dt)
	check("same seed, same event sequence", seq_same)

	# --- 6. OneShots: the post-blast silence ----------------------------------
	shots = AmbientSimRes.OneShots.new(3)
	shots.add_voice("birdsong", 0.5, 1.0)  # chatty, so silence is provable
	for s in int(5.0 / dt):
		shots.step(dt)
	shots.disturb(8.0)
	check("bed fully ducked at the blast", shots.duck01() == 0.0)
	var quiet_events := 0
	for s in int(8.0 / dt):
		quiet_events += shots.step(dt).size()
	check("nothing sings through the quiet window", quiet_events == 0)
	check("bed recovers with the quiet", shots.duck01() >= 0.99, str(shots.duck01()))
	var resumed := 0
	for s in int(4.0 / dt):
		resumed += shots.step(dt).size()
	check("the world resumes after the silence", resumed >= 2, "%d events" % resumed)

	# --------------------------------------------------------------------------
	if failures == 0:
		print("\nAll ambient_sim checks passed.")
	else:
		printerr("\n%d ambient_sim check(s) FAILED." % failures)
	quit(1 if failures > 0 else 0)
