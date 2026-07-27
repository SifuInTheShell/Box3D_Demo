## Fire propagation core (docs/fire-research.md): a pure-GDScript simulation
## of heating, ignition, flaming, charring, smoldering and burnout over a set
## of axis-aligned fuel items (wooden panels, beams, debris, canopies).
##
## The model is the research doc's minimal state machine: per item
##   temp      scalar "surface temperature" (ambient 20, ignition ~300)
##   moisture  0..1, boils off before the temperature can climb (wet wood)
##   char      0..1 charred fraction of the thickness; grows linearly while
##             burning (Eurocode-style constant char rate), never shrinks
##   state     COLD -> BURNING -> SMOLDERING <-> BURNING -> BURNT_OUT
## Heat moves from burners to neighbours with quadratic distance falloff, a
## strong upward bias (flames preheat what is above them), a wind skew, and a
## contact bonus for touching items. Strength follows the residual
## cross-section: strength = (1 - char)^2 -- the caller maps that onto its
## fracture thresholds / load model.
##
## Deterministic by construction: no RNG anywhere, iteration in insertion
## order, all state in `items`. The engine layer (gyms) mirrors body positions
## in and reads states/events out; nothing here references Box3D or nodes.
class_name FireSim

enum { COLD, BURNING, SMOLDERING, BURNT_OUT }

# ---- Tunables (docs/fire-research.md constants table) -------------------------
const T_AMBIENT := 20.0
const T_BOIL := 100.0        # moisture must boil off above this before heating
const T_IGNITE := 300.0      # piloted ignition temperature
const T_SMOLDER_DIE := 140.0 # a smolderer cooled below this goes cold
const HEAT_CAPACITY := 95.0  # flux units per degree per metre of thickness
const BOIL_COST := 6000.0    # flux units to boil one full moisture unit per m
const COOL_TAU := 14.0       # seconds for excess temperature to fall by ~63%
const OUTPUT_K := 340.0      # flame heat output per m^2 of burning area
const SMOLDER_OUTPUT := 0.12 # smolder output fraction of flaming output
const RAMP_TIME := 3.0       # seconds for a fresh flame to reach full output
const CHAR_RATE := 0.0011    # metres of char per second (game-time scaled:
                             # real wood chars ~0.65 mm/min; ~100x for play)
const SMOLDER_CHAR := 0.25   # smolder chars at this fraction of the burn rate
const REKINDLE_RATE := 9.0   # deg/s a smolderer self-heats toward reignition
const UP_MULT := 7.0         # flux multiplier straight above a burner
const DOWN_MULT := 0.3       # flux multiplier straight below
const WIND_K := 0.09         # wind skew per m/s of wind along the direction
const CONTACT_GAP := 0.18    # metres; closer than this counts as touching
const CONTACT_MULT := 2.6    # conduction bonus for touching items
const FALLOFF := 0.55        # quadratic distance falloff steepness
const REACH_BASE := 1.6      # metres of spread reach at zero intensity
const REACH_K := 2.6         # extra reach per unit of flame intensity
const WATER_COOL := 260.0    # degrees removed per unit of douse amount
const MOISTURE_KILL := 0.5   # moisture above this puts smoldering out too

var wind := Vector3.ZERO     # horizontal, m/s
var items: Dictionary = {}   # id -> item Dictionary
## Events emitted by the last step(): {"id": int, "event": "ignited" |
## "smolder" | "rekindled" | "burnout" | "cold"}. The engine layer turns
## these into FX attach/detach; the sim only records them.
var events: Array = []

var _cell := 4.0             # spatial hash cell size (max reach, kept in sync)


## Register a fuel item. `half` is the AABB half-extent; thickness (the item's
## smallest dimension) sets both how hard it is to ignite and how long it
## burns. fuel_scale > 1 for rich fuels (dry brush, canopies), < 1 for lean.
## `thickness_override` (> 0) decouples fuel thickness from the AABB -- a tree
## canopy is a big box of thin fuel (boughs), not a solid timber block.
func add_item(id: int, pos: Vector3, half: Vector3,
		moisture := 0.0, fuel_scale := 1.0, thickness_override := 0.0) -> void:
	var thickness := 2.0 * minf(half.x, minf(half.y, half.z))
	if thickness_override > 0.0:
		thickness = thickness_override
	var area := 8.0 * (half.x * half.y + half.y * half.z + half.x * half.z)
	items[id] = {
		"pos": pos,
		"half": half,
		"r": half.length(),
		"thickness": maxf(thickness, 0.02),
		"area": area,
		"fuel_scale": maxf(fuel_scale, 0.05),
		"moisture": clampf(moisture, 0.0, 1.0),
		"temp": T_AMBIENT,
		"char": 0.0,
		"state": COLD,
		"burn_t": 0.0,   # seconds aflame (drives the output ramp)
		"flux_in": 0.0,  # last step's incoming flux (engine reads for FX)
	}


func remove_item(id: int) -> void:
	items.erase(id)


func update_pos(id: int, pos: Vector3) -> void:
	if items.has(id):
		items[id]["pos"] = pos


func has_item(id: int) -> bool:
	return items.has(id)


func state(id: int) -> int:
	return items[id]["state"] if items.has(id) else COLD


## 0..1 flame size: the output ramp times the remaining fuel, zero unless
## flaming. The engine layer scales its flame FX with this.
func intensity(id: int) -> float:
	if not items.has(id):
		return 0.0
	var it: Dictionary = items[id]
	if it["state"] != BURNING:
		return 0.0
	return clampf(it["burn_t"] / RAMP_TIME, 0.15, 1.0) * (1.0 - it["char"])


## Residual structural strength 0..1: the uncharred cross-section squared
## (a member charring from all sides keeps (1-c)^2 of its area).
func strength(id: int) -> float:
	if not items.has(id):
		return 1.0
	var c: float = items[id]["char"]
	return (1.0 - c) * (1.0 - c)


func charring(id: int) -> float:
	return items[id]["char"] if items.has(id) else 0.0


## Force-ignite (incendiary tools, tests). Skips the heating phase.
func ignite(id: int) -> void:
	if not items.has(id):
		return
	var it: Dictionary = items[id]
	if it["state"] == BURNT_OUT or it["state"] == BURNING:
		return
	it["moisture"] = 0.0
	it["temp"] = maxf(it["temp"], T_IGNITE)
	_set_state(it, id, BURNING, "ignited")


## Radial heat splash (explosions, ground fires): temperature jump with
## quadratic falloff. Big enough pulses ignite outright.
func add_heat(at: Vector3, radius: float, energy: float) -> void:
	for id in items:
		var it: Dictionary = items[id]
		if it["state"] == BURNT_OUT:
			continue
		var d: float = maxf(at.distance_to(it["pos"]) - it["r"], 0.0)
		if d > radius:
			continue
		var k := 1.0 - d / radius
		_absorb(it, id, energy * k * k, 1.0)


## Water hit (splash zones, hoses): cools hard and wets. Flaming items drop
## to smoldering (hot char) or cold; heavily wetted smolderers die.
func douse(id: int, amount: float) -> void:
	if not items.has(id):
		return
	var it: Dictionary = items[id]
	it["temp"] = maxf(it["temp"] - WATER_COOL * amount, T_AMBIENT)
	it["moisture"] = clampf(it["moisture"] + amount * 0.5, 0.0, 1.0)
	if it["state"] == BURNING and it["temp"] < T_IGNITE:
		if it["char"] > 0.04 and it["moisture"] < MOISTURE_KILL:
			_set_state(it, id, SMOLDERING, "smolder")
		else:
			_set_state(it, id, COLD, "cold")
	elif it["state"] == SMOLDERING \
			and (it["moisture"] >= MOISTURE_KILL or it["temp"] < T_SMOLDER_DIE):
		_set_state(it, id, COLD, "cold")


## Advance the whole sim. Call at a fixed cadence (the gym uses 5 Hz); the
## model is rate-based, so dt just scales it.
func step(dt: float) -> void:
	events = []
	if items.is_empty():
		return
	var max_reach := REACH_BASE + REACH_K + 1.0
	_cell = max_reach
	# Collect burners once, hash all items for the neighbour queries.
	var burners: Array = []
	var hash_: Dictionary = {}
	for id in items:
		var it: Dictionary = items[id]
		it["flux_in"] = 0.0
		var key := _hash_key(it["pos"])
		if not hash_.has(key):
			hash_[key] = []
		hash_[key].append(id)
		if it["state"] == BURNING or it["state"] == SMOLDERING:
			burners.append(id)

	# 1. Radiate: burners push flux onto neighbours.
	for bid in burners:
		var b: Dictionary = items[bid]
		var out_frac := 1.0
		if b["state"] == SMOLDERING:
			out_frac = SMOLDER_OUTPUT
		else:
			out_frac = clampf(b["burn_t"] / RAMP_TIME, 0.15, 1.0) * (1.0 - b["char"])
		var output: float = OUTPUT_K * b["area"] * b["fuel_scale"] * out_frac
		if output <= 0.0:
			continue
		var reach: float = REACH_BASE + REACH_K * out_frac + b["r"]
		for nid in _near(hash_, b["pos"], reach):
			if nid == bid:
				continue
			var t: Dictionary = items[nid]
			if t["state"] != COLD:
				continue
			var to: Vector3 = t["pos"] - b["pos"]
			var gap: float = maxf(to.length() - b["r"] - t["r"], 0.0)
			if gap > reach:
				continue
			var geom: float = 1.0 / (1.0 + FALLOFF * gap * gap)
			var dir := to.normalized() if to.length() > 0.001 else Vector3.UP
			var vertical: float = pow(UP_MULT, clampf(dir.y, 0.0, 1.0)) \
					* pow(DOWN_MULT, clampf(-dir.y, 0.0, 1.0))
			var windward: float = 1.0 + WIND_K * maxf(
					wind.dot(Vector3(dir.x, 0.0, dir.z)), -0.5 / maxf(WIND_K, 0.001))
			var contact: float = CONTACT_MULT if gap <= CONTACT_GAP else 1.0
			t["flux_in"] += output * geom * vertical * windward * contact \
					/ maxf(t["area"], 0.5)

	# 2. Integrate every item's own thermodynamics.
	for id in items:
		var it: Dictionary = items[id]
		match it["state"]:
			COLD:
				_absorb(it, id, it["flux_in"] * dt, dt)
			BURNING:
				it["burn_t"] += dt
				it["char"] = minf(
						it["char"] + CHAR_RATE * dt / (it["thickness"] * 0.5), 1.0)
				if it["char"] >= 1.0:
					it["temp"] = T_AMBIENT + 80.0
					_set_state(it, id, BURNT_OUT, "burnout")
			SMOLDERING:
				# Hot char creeps back toward reignition unless it stays wet.
				it["char"] = minf(it["char"] + SMOLDER_CHAR * CHAR_RATE * dt \
						/ (it["thickness"] * 0.5), 1.0)
				if it["char"] >= 1.0:
					_set_state(it, id, BURNT_OUT, "burnout")
				elif it["moisture"] > 0.0:
					it["moisture"] = maxf(it["moisture"] - 0.01 * dt, 0.0)
				else:
					it["temp"] += REKINDLE_RATE * dt
					if it["temp"] >= T_IGNITE:
						_set_state(it, id, BURNING, "rekindled")
			BURNT_OUT:
				pass
		# Newton cooling toward ambient for everything not aflame.
		if it["state"] == COLD:
			it["temp"] = T_AMBIENT \
					+ (it["temp"] - T_AMBIENT) * exp(-dt / COOL_TAU)


## FNV-style order-independent digest of the full sim state, for determinism
## tests and replay checks.
func state_hash() -> int:
	var h := 2166136261
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var it: Dictionary = items[id]
		for v in [id, it["state"], int(it["temp"] * 64.0),
				int(it["char"] * 4096.0), int(it["moisture"] * 4096.0),
				int(it["burn_t"] * 64.0)]:
			h = int((h ^ (v & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
	return h


# ---- internals ---------------------------------------------------------------

## Pour absorbed energy into an item: boils moisture first (plateau at
## T_BOIL), then raises temperature against thickness; ignites at T_IGNITE.
func _absorb(it: Dictionary, id: int, energy: float, _dt: float) -> void:
	if it["state"] != COLD or energy <= 0.0:
		return
	if it["moisture"] > 0.0 and it["temp"] >= T_BOIL:
		var boiled: float = energy / (BOIL_COST * it["thickness"])
		if boiled < it["moisture"]:
			it["moisture"] -= boiled
			return
		energy -= it["moisture"] * BOIL_COST * it["thickness"]
		it["moisture"] = 0.0
	it["temp"] += energy / (HEAT_CAPACITY * it["thickness"])
	if it["temp"] >= T_IGNITE:
		_set_state(it, id, BURNING, "ignited")


func _set_state(it: Dictionary, id: int, to: int, event: String) -> void:
	it["state"] = to
	if to == BURNING:
		it["burn_t"] = 0.0
		it["temp"] = maxf(it["temp"], T_IGNITE)
	events.append({"id": id, "event": event})


func _hash_key(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / _cell), floori(p.y / _cell), floori(p.z / _cell))


func _near(hash_: Dictionary, p: Vector3, reach: float) -> Array:
	var out: Array = []
	var cells := ceili(reach / _cell)
	var base := _hash_key(p)
	for dx in range(-cells, cells + 1):
		for dy in range(-cells, cells + 1):
			for dz in range(-cells, cells + 1):
				var key := base + Vector3i(dx, dy, dz)
				if hash_.has(key):
					out.append_array(hash_[key])
	return out
