## Ambient-life core: the deterministic models behind the cosmetic "the site
## is alive" layer. Three small parts, all reactive rather than simulated —
## the pattern every shipped example uses (see the notes below):
##
##   Flock     Townscaper-grade birds: perch, occasionally hop, scatter on
##             a disturbance, resettle after a cooldown. One flee rule, no
##             bird-to-bird behavior, no persistent memory.
##   Windows   lit/unlit habitation ledger: each registered window draws
##             its lit state once, deterministically; breakage and power
##             loss only ever darken (nobody flips lights on mid-blast).
##   OneShots  the Tsushima "fake birds" audio scheduler: named voices fire
##             on seeded random intervals; a disturbance opens a quiet
##             window (timers freeze, the bed ducks) -- the post-blast
##             silence is the point.
##
## STRICTLY COSMETIC by design: nothing here may feed
## physics, the sim results, or the determinism hash. Deterministic anyway (each
## part owns a RandomNumberGenerator seeded at construction, iteration in
## insertion order) so scenes replay identically and the suite can assert
## behavior. The engine layer (lib/ambient/) mirrors states out; nothing
## here references Box3D or nodes.
class_name AmbientSim


## Perch-flee-resettle birds. Positions are advanced with explicit update(dt)
## calls; the caller owns the clock (the visual layer ticks per frame, the
## test suite ticks a fixed dt).
class Flock:
	enum { PERCHED, FLYING, FLEEING }

	const CRUISE := 6.0        # m/s toward a perch
	const TURN := 3.2          # 1/s steering rate while flying
	const FLEE_SPEED := 11.0   # m/s away from a disturbance
	const CLIMB := 4.5         # m/s extra vertical while fleeing
	const FLEE_TIME := 2.2     # s of pure flight before circling back
	const SETTLE_R := 0.4      # m from the perch that counts as landed
	const HOP_MIN := 7.0       # s between voluntary relocations…
	const HOP_MAX := 22.0      # …drawn per landing
	const JITTER := 0.35       # m of per-bird offset around a perch point
	const WIND_DRIFT := 0.35   # fraction of the wind an airborne bird rides

	var birds: Array = []      # {pos, vel, state, target, timer}
	var perches: Array = []    # Vector3 landing points (roof tops, branches)
	var wind := Vector3.ZERO   # airborne birds drift with it; perched ignore it

	var _rng := RandomNumberGenerator.new()
	var _threat := Vector3.INF # last disturbance; fleers resettle away from it

	func _init(seed_v: int) -> void:
		_rng.seed = seed_v

	func set_perches(points: Array) -> void:
		perches = points.duplicate()

	func spawn(count: int) -> void:
		for i in count:
			var perch := _pick_perch(Vector3.INF)
			birds.append({
				"pos": perch, "vel": Vector3.ZERO, "state": PERCHED,
				"target": perch, "timer": _rng.randf_range(HOP_MIN, HOP_MAX),
			})

	func update(dt: float) -> void:
		for b in birds:
			match b["state"]:
				PERCHED:
					b["timer"] -= dt
					if b["timer"] <= 0.0:
						_take_off(b, _pick_perch(b["pos"]))
				FLYING:
					var want: Vector3 = (b["target"] - b["pos"]).normalized() * CRUISE
					b["vel"] = (b["vel"] as Vector3).lerp(want, clampf(TURN * dt, 0.0, 1.0))
					b["pos"] += (b["vel"] + wind * WIND_DRIFT) * dt
					if b["pos"].distance_to(b["target"]) < SETTLE_R:
						b["pos"] = b["target"]
						b["vel"] = Vector3.ZERO
						b["state"] = PERCHED
						b["timer"] = _rng.randf_range(HOP_MIN, HOP_MAX)
				FLEEING:
					b["pos"] += (b["vel"] + wind * WIND_DRIFT) * dt
					b["timer"] -= dt
					if b["timer"] <= 0.0:
						_take_off(b, _pick_perch(_threat))

	## Scare everything inside the radius: straight away from the blast,
	## climbing. The visual layer calls this with ~2-3x the damage radius --
	## birds are the "you rattled the neighbourhood" tell, like glass.
	func disturb(at: Vector3, radius: float) -> void:
		_threat = at
		for b in birds:
			if (b["pos"] as Vector3).distance_to(at) > radius:
				continue
			var away: Vector3 = b["pos"] - at
			away.y = 0.0
			if away.length() < 0.01:
				away = Vector3(_rng.randf() * 2.0 - 1.0, 0.0, _rng.randf() * 2.0 - 1.0)
			var jig := (_rng.randf() - 0.5) * 0.8
			away = away.normalized().rotated(Vector3.UP, jig)
			b["vel"] = away * FLEE_SPEED + Vector3.UP * CLIMB
			b["state"] = FLEEING
			b["timer"] = FLEE_TIME * _rng.randf_range(0.8, 1.3)

	func perched_count() -> int:
		var n := 0
		for b in birds:
			if b["state"] == PERCHED:
				n += 1
		return n

	func state(i: int) -> int:
		return birds[i]["state"]

	func position(i: int) -> Vector3:
		return birds[i]["pos"]

	func velocity(i: int) -> Vector3:
		return birds[i]["vel"]

	func _take_off(b: Dictionary, target: Vector3) -> void:
		b["target"] = target
		b["state"] = FLYING
		var dir: Vector3 = (target - b["pos"]).normalized()
		b["vel"] = (dir if dir.is_finite() else Vector3.UP) * CRUISE * 0.5

	## A perch away from `avoid` when one exists: fleers regroup on the far
	## side of the site instead of diving back over the rubble.
	func _pick_perch(avoid: Vector3) -> Vector3:
		if perches.is_empty():
			return Vector3.ZERO
		var i := _rng.randi_range(0, perches.size() - 1)
		if avoid.is_finite():
			var j := _rng.randi_range(0, perches.size() - 1)
			if (perches[j] as Vector3).distance_to(avoid) \
					> (perches[i] as Vector3).distance_to(avoid):
				i = j
		var p: Vector3 = perches[i]
		return p + Vector3(_rng.randf_range(-JITTER, JITTER), 0.0,
				_rng.randf_range(-JITTER, JITTER))


## Habitation ledger: which windows glow. Lit state is drawn once per window
## at registration (deterministic in insertion order), and only ever goes
## dark afterwards -- a broken pane or a building losing power reads as a
## consequence, never as noise.
class Windows:
	var lit_fraction := 0.4

	var _rng := RandomNumberGenerator.new()
	var _windows := {}   # id -> {building, lit}

	func _init(seed_v: int, fraction: float) -> void:
		_rng.seed = seed_v
		lit_fraction = clampf(fraction, 0.0, 1.0)

	## Returns whether this window glows. `building` groups windows for
	## power-loss darkening.
	func add_window(id: int, building := 0) -> bool:
		var lit := _rng.randf() < lit_fraction
		_windows[id] = {"building": building, "lit": lit}
		return lit

	func has_window(id: int) -> bool:
		return _windows.has(id)

	func is_lit(id: int) -> bool:
		return _windows.has(id) and _windows[id]["lit"]

	func darken(id: int) -> void:
		if _windows.has(id):
			_windows[id]["lit"] = false

	func darken_building(building: int) -> void:
		for id in _windows:
			if _windows[id]["building"] == building:
				_windows[id]["lit"] = false

	func lit_count() -> int:
		var n := 0
		for id in _windows:
			if _windows[id]["lit"]:
				n += 1
		return n

	func count() -> int:
		return _windows.size()


## Seeded one-shot scheduler for ambience spot sounds (birdsong, a dog, cafe
## chatter) over a bed loop. A disturbance freezes every voice and opens a
## quiet window; duck01() gives the bed volume through it -- 0 right after
## the blast, recovering linearly to 1. Silence, then the world resumes
## changed: that is the whole trick.
class OneShots:
	var _rng := RandomNumberGenerator.new()
	var _voices := {}        # name -> {gap_min, gap_max, t}
	var _quiet := 0.0        # seconds of quiet left
	var _quiet_total := 0.0  # length of the current quiet window

	func _init(seed_v: int) -> void:
		_rng.seed = seed_v

	func add_voice(name: String, gap_min: float, gap_max: float) -> void:
		_voices[name] = {"gap_min": gap_min, "gap_max": gap_max,
				"t": _rng.randf_range(gap_min, gap_max)}

	## Advance and return the voice names that fire this step.
	func step(dt: float) -> Array:
		if _quiet > 0.0:
			_quiet = maxf(_quiet - dt, 0.0)
			return []
		var fired: Array = []
		for name in _voices:
			var v: Dictionary = _voices[name]
			v["t"] -= dt
			if v["t"] <= 0.0:
				fired.append(name)
				v["t"] = _rng.randf_range(v["gap_min"], v["gap_max"])
		return fired

	func disturb(quiet_sec := 8.0) -> void:
		_quiet = maxf(_quiet, quiet_sec)
		_quiet_total = maxf(_quiet_total, quiet_sec)

	## Bed volume factor: 0 at the moment of the blast, 1 once quiet passes.
	func duck01() -> float:
		if _quiet <= 0.0 or _quiet_total <= 0.0:
			return 1.0
		return 1.0 - _quiet / _quiet_total

	func quiet() -> bool:
		return _quiet > 0.0
