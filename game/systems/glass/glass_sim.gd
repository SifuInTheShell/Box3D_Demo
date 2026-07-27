## Glass breakage core (docs/glass-research.md): a pure-GDScript registry of
## window panes and the physics that breaks them. Glass is the readable
## blast-radius indicator: blast overpressure shatters windows at far
## greater range than masonry cracks, so a careless charge announces itself
## by raining glass off every building around the site.
##
## Break causes, each with its own tally in the ledger:
##   blast    side-on overpressure from a charge, Hopkinson-scaled:
##            Z = R / W^(1/3), P(Z) kPa via the Newmark-Hansen style fit
##            P = A/Z^3 + B/Z^2 + C/Z. Panes break where P >= their limit.
##   impact   debris/projectile contact past a small relative speed
##            (annealed glass is fragile; the engine layer detects contact)
##   heat     fires near a pane heat it; past the thermal-shock limit the
##            glazing cracks and falls out (compartment-fire fallout)
##
## Panes carry a tag ("target" / "protected" / "neutral"): the ledger counts
## broken panes and area per tag, so "the target shattered, the surroundings
## intact" is a single lookup.
##
## Deterministic and engine-free like FireSim: no RNG, no nodes; the engine
## layer mirrors pane positions in and turns returned ids into shard FX.
class_name GlassSim

# ---- Tunables (docs/glass-research.md constants table) ------------------------
const OP_A := 1772.0        # overpressure fit, kPa terms over scaled distance
const OP_B := -114.0
const OP_C := 108.0
const BREAK_KPA := 11.0     # pane failure threshold. Real annealed windows
                            # fail at 0.7-7 kPa, but at those figures every
                            # charge shatters the whole scene; 11 kPa keeps
                            # the ratio (glass radius ~3-5x structural) at
                            # our compact scene scale: small/medium/large
                            # charges reach ~18/34/52 m vs 3.5/6.5/10 m.
const IMPACT_SPEED := 2.2   # m/s relative contact speed that shatters a pane
const CRACK_SPEED := 1.1    # m/s: a softer knock only crazes the glass (cosmetic)
const HEAT_LIMIT := 150.0   # degrees above ambient: thermal shock fallout
const T_AMBIENT := 20.0
const HEAT_COOL_TAU := 20.0 # seconds for pane heat to decay by ~63%

var panes: Dictionary = {}  # id -> {pos, area, tag, temp}
## Broken tallies per tag: tag -> {"count": int, "area": float,
## "by_cause": {cause: count}}.
var ledger: Dictionary = {}


func add_pane(id: int, pos: Vector3, area: float, tag := "neutral") -> void:
	panes[id] = {"pos": pos, "area": maxf(area, 0.01), "tag": tag,
			"temp": T_AMBIENT}


func remove_pane(id: int) -> void:
	panes.erase(id)


func has_pane(id: int) -> bool:
	return panes.has(id)


func update_pos(id: int, pos: Vector3) -> void:
	if panes.has(id):
		panes[id]["pos"] = pos


func pane_count() -> int:
	return panes.size()


# ---- Overpressure model ------------------------------------------------------

## Side-on overpressure in kPa at distance `dist` from `w_kg` TNT-equivalent.
static func overpressure_kpa(w_kg: float, dist: float) -> float:
	if w_kg <= 0.0:
		return 0.0
	var z := maxf(dist, 0.3) / pow(w_kg, 1.0 / 3.0)
	return maxf(OP_A / (z * z * z) + OP_B / (z * z) + OP_C / z, 0.0)


## Range out to which a charge breaks standard panes (bisection on the
## monotonic far-field of P; the glass-warning circle a planner UI can draw).
static func break_distance(w_kg: float, threshold := BREAK_KPA) -> float:
	if w_kg <= 0.0:
		return 0.0
	var lo := 0.3
	var hi := 2000.0
	if overpressure_kpa(w_kg, hi) >= threshold:
		return hi
	for i in 60:
		var mid := (lo + hi) * 0.5
		if overpressure_kpa(w_kg, mid) >= threshold:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


# ---- Break causes ------------------------------------------------------------

## A charge went off: break every pane inside its overpressure radius.
## Returns the broken ids (already removed and tallied), nearest first --
## the engine layer shatters them with a radial stagger for the wave look.
func blast(at: Vector3, w_kg: float) -> Array:
	var broken_ids: Array = []
	for id in panes.keys():
		var p: Dictionary = panes[id]
		if overpressure_kpa(w_kg, at.distance_to(p["pos"])) >= BREAK_KPA:
			broken_ids.append(id)
	broken_ids.sort_custom(func(a, b) -> bool:
		return at.distance_squared_to(panes[a]["pos"]) \
				< at.distance_squared_to(panes[b]["pos"]))
	for id in broken_ids:
		_tally(id, "blast")
		panes.erase(id)
	return broken_ids


## Contact break, decided by the engine layer's collision event.
## Returns true when the speed is enough (the pane is then gone from the sim).
func impact(id: int, rel_speed: float) -> bool:
	if not panes.has(id) or rel_speed < IMPACT_SPEED:
		return false
	_tally(id, "impact")
	panes.erase(id)
	return true


## Pour fire heat onto panes near a burning source (same falloff idea as
## FireSim.add_heat). Returns ids that just failed thermally.
func add_heat(at: Vector3, radius: float, energy: float) -> Array:
	var broken_ids: Array = []
	for id in panes.keys():
		var p: Dictionary = panes[id]
		var d: float = at.distance_to(p["pos"])
		if d > radius:
			continue
		var k := 1.0 - d / radius
		p["temp"] += energy * k * k
		if p["temp"] - T_AMBIENT >= HEAT_LIMIT:
			_tally(id, "heat")
			panes.erase(id)
			broken_ids.append(id)
	return broken_ids


## Passive cooling between heat pulses; call at the engine layer's cadence.
func cool(dt: float) -> void:
	for id in panes:
		var p: Dictionary = panes[id]
		p["temp"] = T_AMBIENT + (p["temp"] - T_AMBIENT) * exp(-dt / HEAT_COOL_TAU)


# ---- Ledger ------------------------------------------------------------------

func broken(tag: String) -> Dictionary:
	return ledger.get(tag, {"count": 0, "area": 0.0, "by_cause": {}})


func total_broken() -> int:
	var n := 0
	for tag in ledger:
		n += ledger[tag]["count"]
	return n


func _tally(id: int, cause: String) -> void:
	var p: Dictionary = panes[id]
	var tag: String = p["tag"]
	if not ledger.has(tag):
		ledger[tag] = {"count": 0, "area": 0.0, "by_cause": {}}
	ledger[tag]["count"] += 1
	ledger[tag]["area"] += p["area"]
	var bc: Dictionary = ledger[tag]["by_cause"]
	bc[cause] = int(bc.get(cause, 0)) + 1


# ---- Shatter pattern ---------------------------------------------------------

## Split a pane face (local 2D, centred rect `size`) into shard rects, finer
## near the impact point -- non-uniform grid whose columns/rows crowd toward
## the hit, which the engine layer jitters into glass wedges. `energy01`
## scales shard count. Deterministic for fixed inputs.
## Returns Array of {"off": Vector2 centre offset, "size": Vector2}.
static func shatter_pattern(size: Vector2, hit: Vector2,
		energy01: float) -> Array:
	var cols := clampi(2 + int(energy01 * 4.0), 2, 6)
	var rows := clampi(2 + int(energy01 * 3.0), 2, 5)
	var xs := _crowded_axis(size.x, hit.x, cols)
	var ys := _crowded_axis(size.y, hit.y, rows)
	var out: Array = []
	for i in cols:
		for j in rows:
			var w: float = xs[i + 1] - xs[i]
			var h: float = ys[j + 1] - ys[j]
			out.append({
				"off": Vector2(xs[i] + w * 0.5, ys[j] + h * 0.5),
				"size": Vector2(w, h),
			})
	return out


## Cut points along one axis (`length`, centred): uniform spacing warped
## toward `focus` so cells shrink near the impact and grow away from it.
static func _crowded_axis(length: float, focus: float, cells: int) -> Array:
	var f := clampf(focus / maxf(length, 0.001) + 0.5, 0.0, 1.0)
	var pts: Array = []
	for i in cells + 1:
		var t := float(i) / cells
		# Pull sample points toward f: blend t with a curve bent around f.
		var bent := f + (t - f) * (0.55 + 0.45 * absf(t - f))
		pts.append((clampf(bent, 0.0, 1.0) - 0.5) * length)
	pts.sort()
	pts[0] = -length * 0.5
	pts[cells] = length * 0.5
	return pts
