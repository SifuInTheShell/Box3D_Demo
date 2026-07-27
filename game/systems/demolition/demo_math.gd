## Pure math for the demolition model. No engine nodes, no Box3D —
## usable headless on any platform. Models and constants: docs/core-math.md.
## Expected values asserted by demo_math_test.gd come from the validated Python
## reference described there; keep the two in sync when tuning.
class_name DemoMath


# ---- Tunables (docs/core-math.md §8) ----------------------------------------
const GRAVITY := 9.81
const K_R := 2.0            # blast radius per kg^(1/3), meters
const K_J := 60.0           # impulse/area per kg^(1/3), N*s/m^2
const K_PPV := 1140.0       # PPV site constant, mm/s
const B_PPV := 1.6          # PPV attenuation exponent
const PPV_WINDOW_MS := 8.0  # charges within this window count as one
const SIGMA_DEFAULT := 2.0e6  # weld strength, Pa (weak mortar)
const WELD_HERTZ := 30.0    # soft-weld frequency
const V_BREAK := 4.0        # shear-velocity break threshold, m/s
const SETTLE_SPEED := 0.05  # m/s
const SETTLE_TIME := 2.0    # s
const FELL_MARGIN := 0.15   # fell-strip length margin


# ---- 1. Charge model (cube-root scaling) ------------------------------------

static func charge_radius(w_kg: float) -> float:
	return K_R * pow(w_kg, 1.0 / 3.0)


static func charge_impulse_per_area(w_kg: float) -> float:
	return K_J * pow(w_kg, 1.0 / 3.0)


static func charge_falloff(w_kg: float) -> float:
	return charge_radius(w_kg)


# ---- 2. Vibration model ------------------------------------------------------

## Peak particle velocity in mm/s at distance_m from an effective charge w_kg.
static func ppv(distance_m: float, w_kg: float) -> float:
	var sd := distance_m / sqrt(maxf(w_kg, 1e-9))
	return K_PPV * pow(sd, -B_PPV)


## Groups charges by the 8 ms rule. charges: Array of Dictionaries with keys
## "time_ms" (float), "mass_kg" (float), "position" (Vector3). Returns an Array
## of groups: { "time_ms": first detonation, "mass_kg": summed, "positions": [] }.
static func group_charges(charges: Array) -> Array:
	var sorted := charges.duplicate()
	sorted.sort_custom(func(a, b): return a["time_ms"] < b["time_ms"])
	var groups: Array = []
	var group_start := -INF
	for c in sorted:
		var t: float = c["time_ms"]
		if groups.is_empty() or t - group_start > PPV_WINDOW_MS:
			groups.append({"time_ms": t, "mass_kg": 0.0, "positions": []})
			group_start = t
		var g: Dictionary = groups[-1]
		g["mass_kg"] += c["mass_kg"]
		g["positions"].append(c["position"])
	return groups


## Worst-case PPV over all sensors for a full blast plan. Conservative: each
## group is evaluated at the group's nearest charge to the sensor.
static func max_ppv(charges: Array, sensor_positions: Array) -> float:
	var worst := 0.0
	for g in group_charges(charges):
		for s in sensor_positions:
			var d_min := INF
			for p in g["positions"]:
				d_min = minf(d_min, (p as Vector3).distance_to(s))
			worst = maxf(worst, ppv(maxf(d_min, 0.1), g["mass_kg"]))
	return worst


# ---- 3. Structure model ------------------------------------------------------

static func weld_capacity(area_m2: float, sigma_pa: float = SIGMA_DEFAULT) -> float:
	return sigma_pa * area_m2


static func weld_utilization(load_kg: float, area_m2: float,
		sigma_pa: float = SIGMA_DEFAULT) -> float:
	return load_kg * GRAVITY / weld_capacity(area_m2, sigma_pa)


## Load propagation with area-weighted distribution: a body's carried load
## splits over its supporting welds proportionally to contact area (equalizing
## stress across supports), instead of equally. edge_areas keys are "a->b"
## strings matching support edges; missing entries fall back to equal split.
static func support_loads_weighted(masses: Dictionary, supports: Dictionary,
		edge_areas: Dictionary) -> Dictionary:
	var dependents: Dictionary = {}
	for b in masses:
		dependents[b] = []
	for b in supports:
		for s in supports[b]:
			if s != "ground":
				dependents[s].append(b)
	var carried: Dictionary = {}
	var weld_load: Dictionary = {}
	var resolved: Dictionary = {}
	while resolved.size() < masses.size():
		var progressed := false
		for b in masses:
			if resolved.has(b):
				continue
			var ready := true
			for d in dependents[b]:
				if not resolved.has(d):
					ready = false
					break
			if not ready:
				continue
			var load_kg: float = masses[b]
			for d in dependents[b]:
				load_kg += weld_load["%s->%s" % [d, b]]
			carried[b] = load_kg
			var sups: Array = supports[b]
			var area_total := 0.0
			for s in sups:
				area_total += float(edge_areas.get("%s->%s" % [b, s], 1.0))
			for s in sups:
				var key := "%s->%s" % [b, s]
				var a := float(edge_areas.get(key, 1.0))
				weld_load[key] = load_kg * a / area_total if area_total > 0.0 \
						else load_kg / sups.size()
			resolved[b] = true
			progressed = true
		if not progressed:
			push_error("support_loads_weighted: cycle in support graph")
			break
	# Surface what a cycle left unsolved: callers (PanelGraph.certify) must
	# fail the bake, not just miss the entries -- a console warning alone is
	# how a physically wrong structure certifies clean.
	var unresolved: Array = []
	for b in masses:
		if not resolved.has(b):
			unresolved.append(b)
	return {"carried": carried, "weld_load": weld_load, "unresolved": unresolved}


# ---- 3b. Bending / cantilever moment (Rule A', mass-aware) ------------------

const SIGMA_BEND := 0.2e6   # masonry bending/tensile strength, Pa (<< compressive)


## Section modulus of a rectangular joint cross-section (width b, depth d).
static func section_modulus(b: float, d: float) -> float:
	return b * d * d / 6.0


## Root bending moment of a cantilever: self-weight (linear density mu kg/m
## over length l) plus an optional point load at the tip.
static func cantilever_moment(mu: float, l: float, tip_mass: float = 0.0) -> float:
	return mu * GRAVITY * l * l / 2.0 + tip_mass * GRAVITY * l


## True if a joint of section (b, d) survives the given moment.
static func bending_ok(moment: float, b: float, d: float,
		sigma_bend: float = SIGMA_BEND) -> bool:
	return moment <= sigma_bend * section_modulus(b, d)


## Max self-supporting cantilever length for a member of linear density mu and
## section (b, d). With masonry defaults this derives Rule A's span_max
## (0.2 MPa, 0.4 m brick -> ~1.23 m ~= 3 bricks). docs/core-math.md §3.4.
static func max_cantilever(mu: float, b: float, d: float,
		sigma_bend: float = SIGMA_BEND) -> float:
	return sqrt(2.0 * sigma_bend * section_modulus(b, d) / (mu * GRAVITY))


## Displacement threshold for breaking a soft weld of frequency f_w holding an
## effective (reduced) mass m_eff against a force cap. docs/core-math.md §3.3.
static func break_displacement(f_cap_n: float, m_eff_kg: float,
		f_w: float = WELD_HERTZ) -> float:
	var k := m_eff_kg * pow(TAU * f_w, 2.0)
	return f_cap_n / k


## Quasi-static load propagation over the support graph.
## masses: Dictionary body_id -> mass_kg.
## supports: Dictionary body_id -> Array of supporting body_ids ("ground" = sink).
## Returns { "carried": {body: kg}, "weld_load": {"a->b": kg} }.
static func support_loads(masses: Dictionary, supports: Dictionary) -> Dictionary:
	var dependents: Dictionary = {}
	for b in masses:
		dependents[b] = []
	for b in supports:
		for s in supports[b]:
			if s != "ground":
				dependents[s].append(b)
	var carried: Dictionary = {}
	var weld_load: Dictionary = {}
	var resolved: Dictionary = {}
	while resolved.size() < masses.size():
		var progressed := false
		for b in masses:
			if resolved.has(b):
				continue
			var ready := true
			for d in dependents[b]:
				if not resolved.has(d):
					ready = false
					break
			if not ready:
				continue
			var load_kg: float = masses[b]
			for d in dependents[b]:
				load_kg += weld_load["%s->%s" % [d, b]]
			carried[b] = load_kg
			var sups: Array = supports[b]
			for s in sups:
				weld_load["%s->%s" % [b, s]] = load_kg / sups.size()
			resolved[b] = true
			progressed = true
		if not progressed:
			push_error("support_loads: cycle in support graph")
			break
	var unresolved: Array = []
	for b in masses:
		if not resolved.has(b):
			unresolved.append(b)
	return {"carried": carried, "weld_load": weld_load, "unresolved": unresolved}


# ---- 4. Toppling & felling ---------------------------------------------------

static func free_fall_time(h: float) -> float:
	return sqrt(2.0 * h / GRAVITY)


## Tip speed of a uniform member of height h felled about its base (> free fall).
static func tip_speed(h: float) -> float:
	return sqrt(3.0 * GRAVITY * h)


## Time for a uniform member of height h to fall from lean theta0 to theta_end
## about its base hinge (inverted pendulum, RK2 midpoint integration).
static func tip_time(h: float, theta0_rad: float,
		theta_end_rad: float = PI / 2.0, dt: float = 1e-4) -> float:
	var a := 1.5 * GRAVITY / h
	var th := theta0_rad
	var w := 0.0
	var t := 0.0
	while th < theta_end_rad:
		var w_mid := w + 0.5 * dt * a * sin(th)
		var th_mid := th + 0.5 * dt * w
		w += dt * a * sin(th_mid)
		th += dt * w_mid
		t += dt
		if t > 60.0:
			return INF
	return t


## Length of the debris strip swept by felling a structure of height h.
static func fell_strip_length(h: float) -> float:
	return h * (1.0 + FELL_MARGIN)


# ---- 5. Determinism hash -------------------------------------------------------

const _FNV_OFFSET := -3750763034362895579  # 0xCBF29CE484222325 as signed 64-bit
const _FNV_PRIME := 1099511628211          # 0x100000001B3


static func quantize(x: float, q: float = 1e-4) -> int:
	return int(roundf(x / q))


## FNV-1a 64 over quantized floats; order matters — feed values in stable body-id
## order (pos.x, pos.y, pos.z, quat.x, quat.y, quat.z, quat.w per body).
static func state_hash(values: PackedFloat64Array, q: float = 1e-4) -> int:
	var h := _FNV_OFFSET
	for x in values:
		var v := quantize(x, q)
		for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
			h = (h ^ ((v >> shift) & 0xFF)) * _FNV_PRIME
	return h


## Determinism-harness hook: hash a body snapshot. entries: Array of
## {"pos": Vector3, "quat": Quaternion} in stable body order. A CI run replays
## a BlastPlan and compares this hash at a fixed tick.
static func hash_snapshot(entries: Array, q: float = 1e-4) -> int:
	var values := PackedFloat64Array()
	for e in entries:
		var p: Vector3 = e["pos"]
		var r: Quaternion = e["quat"]
		for x in [p.x, p.y, p.z, r.x, r.y, r.z, r.w]:
			values.append(x)
	return state_hash(values, q)
