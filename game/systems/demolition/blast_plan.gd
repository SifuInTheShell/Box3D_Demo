## The demolition plan as data: an ordered list of charges with TNT-equivalent
## mass, position, and detonation delay. One artifact drives the detonation
## sequence, the PPV prediction and deterministic replay/CI. Pure GDScript —
## no engine classes.
##
## Charge calibration: the gym's hand-tuned CHARGE_SPECS (radius 3.5/6.5/10,
## impulse 5/7/9) are treated as calibration points. Radius keeps DemoMath's
## cube-root law exactly (R = K_R * W^(1/3), so W = (R/K_R)^3 -> 5.36 / 34.3 /
## 125 kg); impulse fits an affine cube-root law J = A + B * W^(1/3), which
## reproduces the gym values to ~2% — physics scaling preserved, tuned feel
## preserved, and every charge carries a real W for the vibration model.
class_name BlastPlan

const DM = preload("res://systems/demolition/demo_math.gd")

const IMPULSE_BASE := 2.84615   # affine cube-root fit through the gym specs
const IMPULSE_SLOPE := 1.23077

## Charge types. w_ppv scales the mass the vibration model sees — cutters are
## tiny shaped charges, near-silent on the seismograph.
const TYPES := {
	"blast": {"w_ppv": 1.0},
	"cutter": {"w_ppv": 0.12},
	"kicker": {"w_ppv": 0.55},
	"borehole": {"w_ppv": 0.8},
}

## Recognised gear kinds: blast mat / shoring prop.
const GEAR_KINDS := ["mat", "prop"]

var charges: Array[Dictionary] = []   # {id, w_kg, pos: Vector3, delay_ms, type}
var cuts: Array = []                  # [Vector3] pre-weakening cut sites
var cables: Array = []                # [{a: Vector3, b: Vector3}]
var gear: Array = []                  # [{kind: "mat"|"prop", pos: Vector3}]
var _next_id := 1


# ---- Charge scaling ----------------------------------------------------------

static func radius_for(w_kg: float) -> float:
	return DM.charge_radius(w_kg)


static func impulse_for(w_kg: float) -> float:
	return IMPULSE_BASE + IMPULSE_SLOPE * pow(w_kg, 1.0 / 3.0)


static func falloff_for(w_kg: float) -> float:
	return DM.charge_falloff(w_kg)


## Inverse of radius_for: recover W from a legacy radius-tuned charge.
static func w_for_radius(radius: float) -> float:
	return pow(radius / DM.K_R, 3.0)


# ---- Plan editing ------------------------------------------------------------

func add_charge(w_kg: float, pos: Vector3, delay_ms: float = 0.0,
		type := "blast") -> int:
	var id := _next_id
	_next_id += 1
	charges.append({"id": id, "w_kg": w_kg, "pos": pos, "delay_ms": delay_ms,
			"type": type if TYPES.has(type) else "blast"})
	return id


## Pre-weakening cut — a torch cut recorded as part of the replayable plan.
func add_cut(pos: Vector3) -> void:
	cuts.append(pos)


func add_cable(a: Vector3, b: Vector3) -> void:
	cables.append({"a": a, "b": b})


func add_gear(kind: String, pos: Vector3) -> void:
	if kind in GEAR_KINDS:
		gear.append({"kind": kind, "pos": pos})


func set_delay(id: int, delay_ms: float) -> void:
	for c in charges:
		if c["id"] == id:
			c["delay_ms"] = delay_ms
			return


func engine_params(index: int) -> Dictionary:
	var w: float = charges[index]["w_kg"]
	return {
		"radius": radius_for(w),
		"impulse": impulse_for(w),
		"falloff": falloff_for(w),
	}


# ---- Vibration prediction ----------------------------------------------------

func _demomath_charges() -> Array:
	var out: Array = []
	for c in charges:
		out.append({"time_ms": c["delay_ms"],
				"mass_kg": c["w_kg"] * TYPES[c.get("type", "blast")]["w_ppv"],
				"position": c["pos"]})
	return out


## Peak PPV (mm/s) at one monitor position, 8 ms grouping applied.
func ppv_at(sensor_pos: Vector3) -> float:
	if charges.is_empty():
		return 0.0
	return DM.max_ppv(_demomath_charges(), [sensor_pos])


## Per-sensor report. sensors: Array of {pos: Vector3, cap_mm_s: float,
## label: String}. Returns rows {label, ppv, cap_mm_s, ok}.
func ppv_report(sensors: Array) -> Array:
	var rows: Array = []
	for s in sensors:
		var v := ppv_at(s["pos"])
		rows.append({"label": s.get("label", "sensor"), "ppv": v,
				"cap_mm_s": s["cap_mm_s"], "ok": v <= s["cap_mm_s"]})
	return rows


## Overall vibration check. Returns {ok, worst: row or {}}.
func check(sensors: Array) -> Dictionary:
	var worst: Dictionary = {}
	var ok := true
	for row in ppv_report(sensors):
		if not row["ok"]:
			ok = false
		if worst.is_empty() or row["ppv"] / row["cap_mm_s"] \
				> worst["ppv"] / worst["cap_mm_s"]:
			worst = row
	return {"ok": ok, "worst": worst}


# ---- Serialization (replay / CI artifact) ------------------------------------

func to_dict() -> Dictionary:
	var out: Array = []
	for c in charges:
		var p: Vector3 = c["pos"]
		out.append({"id": c["id"], "w_kg": c["w_kg"],
				"pos": [p.x, p.y, p.z], "delay_ms": c["delay_ms"],
				"type": c.get("type", "blast")})
	var cut_out: Array = []
	for p in cuts:
		cut_out.append([p.x, p.y, p.z])
	var cable_out: Array = []
	for c in cables:
		cable_out.append([c["a"].x, c["a"].y, c["a"].z, c["b"].x, c["b"].y, c["b"].z])
	var gear_out: Array = []
	for g in gear:
		gear_out.append([g["kind"], g["pos"].x, g["pos"].y, g["pos"].z])
	return {"charges": out, "cuts": cut_out, "cables": cable_out, "gear": gear_out}


static func from_dict(data: Dictionary) -> BlastPlan:
	var plan := BlastPlan.new()
	var max_id := 0
	for c in data.get("charges", []):
		var p: Array = c["pos"]
		# Same fallback as add_charge: a deserialized plan with an unknown
		# type must degrade to "blast", not crash every TYPES[...] lookup.
		var t := str(c.get("type", "blast"))
		plan.charges.append({"id": int(c["id"]), "w_kg": float(c["w_kg"]),
				"pos": Vector3(p[0], p[1], p[2]),
				"delay_ms": float(c["delay_ms"]),
				"type": t if TYPES.has(t) else "blast"})
		max_id = maxi(max_id, int(c["id"]))
	plan._next_id = max_id + 1
	for p in data.get("cuts", []):
		plan.cuts.append(Vector3(p[0], p[1], p[2]))
	for c in data.get("cables", []):
		plan.cables.append({"a": Vector3(c[0], c[1], c[2]),
				"b": Vector3(c[3], c[4], c[5])})
	for g in data.get("gear", []):
		plan.gear.append({"kind": str(g[0]), "pos": Vector3(g[1], g[2], g[3])})
	return plan
