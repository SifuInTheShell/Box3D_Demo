## Bridge between the panel-stack construction (dynamic Box3DBody panels held
## up by real statics) and the validated load-flow math (DemoMath): builds a
## support graph from panel GEOMETRY alone — no physics queries, no running
## world — so it works in headless tests, on a paused scene, and at bake time.
##
## Input: an Array of panel Dictionaries {"id": String, "pos": Vector3 (center),
## "size": Vector3, "density": float}. Axis-aligned panels only (the generators
## emit axis-aligned boxes; rotated structures are out of scope).
##
## Output: the support-edge list (who rests on whom, with contact areas), and
## per-panel loads/utilizations via DemoMath.support_loads_weighted — the data
## behind a load overlay and the generator's stability certification.
class_name PanelGraph

const DemoMathRef = preload("res://systems/demolition/demo_math.gd")

## Vertical gap tolerance for "A rests on B" (panels touch or near-touch).
const CONTACT_EPS := 0.06


## Support edges: for each panel, the panels (or ground) directly beneath it
## with overlapping footprint. Returns { "supports": {id: [ids or "ground"]},
## "areas": {"a->b": overlap_area_m2}, "masses": {id: mass} }.
static func build(panels: Array, ground_y: float = 0.0) -> Dictionary:
	var supports: Dictionary = {}
	var areas: Dictionary = {}
	var masses: Dictionary = {}
	for p in panels:
		var id: String = p["id"]
		masses[id] = float(p["density"]) * p["size"].x * p["size"].y * p["size"].z
		supports[id] = []
		var bottom: float = p["pos"].y - p["size"].y * 0.5
		if bottom <= ground_y + CONTACT_EPS:
			supports[id].append("ground")
			areas["%s->ground" % id] = p["size"].x * p["size"].z
			continue
		for q in panels:
			if q["id"] == id:
				continue
			var top: float = q["pos"].y + q["size"].y * 0.5
			if absf(bottom - top) > CONTACT_EPS:
				continue
			var a := _footprint_overlap(p, q)
			if a > 0.0:
				supports[id].append(q["id"])
				areas["%s->%s" % [id, q["id"]]] = a
	return {"supports": supports, "areas": areas, "masses": masses}


## XZ footprint overlap area of two axis-aligned panels.
static func _footprint_overlap(p: Dictionary, q: Dictionary) -> float:
	var ox := minf(p["pos"].x + p["size"].x * 0.5, q["pos"].x + q["size"].x * 0.5) \
			- maxf(p["pos"].x - p["size"].x * 0.5, q["pos"].x - q["size"].x * 0.5)
	var oz := minf(p["pos"].z + p["size"].z * 0.5, q["pos"].z + q["size"].z * 0.5) \
			- maxf(p["pos"].z - p["size"].z * 0.5, q["pos"].z - q["size"].z * 0.5)
	return maxf(ox, 0.0) * maxf(oz, 0.0)


## Support-graph analysis over settled panels (docs/destructible-construction.md
## load-flow rules; consumed by a load overlay and bake certification).
## Full analysis: support graph + area-weighted load flow + per-edge stress.
## Returns build()'s fields plus "carried" {id: kg}, "edge_load" {"a->b": kg},
## "edge_stress" {"a->b": Pa}, "unsupported" [ids with no support at all].
static func analyze(panels: Array, ground_y: float = 0.0) -> Dictionary:
	var g := build(panels, ground_y)
	var unsupported: Array = []
	for id in g["supports"]:
		if (g["supports"][id] as Array).is_empty():
			unsupported.append(id)
			# Give the solver a sink so load flow still resolves for the rest.
			g["supports"][id] = ["ground"]
			g["areas"]["%s->ground" % id] = 1e-9
	var flow := DemoMathRef.support_loads_weighted(
			g["masses"], g["supports"], g["areas"])
	var stress: Dictionary = {}
	for key in flow["weld_load"]:
		var a: float = g["areas"].get(key, 0.0)
		stress[key] = (flow["weld_load"][key] * DemoMathRef.GRAVITY / a) \
				if a > 1e-9 else INF
	return {
		"supports": g["supports"], "areas": g["areas"], "masses": g["masses"],
		"carried": flow["carried"], "edge_load": flow["weld_load"],
		"edge_stress": stress, "unsupported": unsupported,
		"unresolved": flow.get("unresolved", []),
	}


## Bake-time certification for generated structures: every panel supported and
## no contact stressed beyond margin * sigma_max. Returns { "ok": bool,
## "unsupported": [...], "overstressed": [{"edge", "stress"}] }.
static func certify(panels: Array, sigma_max: float,
		margin: float = 0.7, ground_y: float = 0.0) -> Dictionary:
	var a := analyze(panels, ground_y)
	var over: Array = []
	for key in a["edge_stress"]:
		if a["edge_stress"][key] > sigma_max * margin:
			over.append({"edge": key, "stress": a["edge_stress"][key]})
	return {
		# A support cycle leaves panels unsolved -- that is a broken bake,
		# not a warning: certify fails on it like on anything else.
		"ok": (a["unsupported"] as Array).is_empty() and over.is_empty() \
				and (a["unresolved"] as Array).is_empty(),
		"unsupported": a["unsupported"],
		"unresolved": a["unresolved"],
		"overstressed": over,
	}
