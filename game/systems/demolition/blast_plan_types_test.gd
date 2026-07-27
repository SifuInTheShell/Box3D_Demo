## Headless test for BlastPlan charge types (blast / cutter / kicker / borehole):
##   godot --headless -s systems/demolition/blast_plan_types_test.gd --path game
extends SceneTree

const BlastPlan = preload("res://systems/demolition/blast_plan.gd")

var failures := 0


func check(name: String, cond: bool) -> void:
	if cond:
		print("[PASS] %s" % name)
	else:
		failures += 1
		printerr("[FAIL] %s" % name)


func _init() -> void:
	var plan := BlastPlan.new()
	plan.add_charge(34.3, Vector3.ZERO, 0.0, "cutter")
	plan.add_charge(34.3, Vector3.ZERO, 0.0)
	check("type stored", plan.charges[0]["type"] == "cutter")
	check("default type is blast", plan.charges[1]["type"] == "blast")
	var nuke_id := plan.add_charge(1.0, Vector3.ZERO, 0.0, "nuke")
	var nuke_type := ""
	for c in plan.charges:
		if c["id"] == nuke_id:
			nuke_type = c["type"]
	check("unknown type falls back", nuke_type == "blast")
	# The same fallback must hold through serialization: a schema-drifted
	# plan file degrades instead of crashing every TYPES[...] lookup.
	var revived := BlastPlan.from_dict({"charges": [{"id": 1, "w_kg": 5.0,
			"pos": [0, 0, 0], "delay_ms": 0.0, "type": "nuke"}]})
	check("from_dict falls back too", revived.charges[0]["type"] == "blast")
	var cut := BlastPlan.new()
	cut.add_charge(34.3, Vector3(10, 0, 0), 0.0, "cutter")
	var blast := BlastPlan.new()
	blast.add_charge(34.3, Vector3(10, 0, 0), 0.0, "blast")
	check("cutter is near-silent on the seismograph",
			cut.ppv_at(Vector3.ZERO) < blast.ppv_at(Vector3.ZERO) * 0.5)
	var bore := BlastPlan.new()
	bore.add_charge(34.3, Vector3(10, 0, 0), 0.0, "borehole")
	check("borehole is quieter than blast at the same stand-off",
			bore.ppv_at(Vector3.ZERO) < blast.ppv_at(Vector3.ZERO))
	var rt := BlastPlan.from_dict(cut.to_dict())
	check("type survives serialization", rt.charges[0]["type"] == "cutter")
	cut.add_cut(Vector3(1, 2, 3))
	var rt2 := BlastPlan.from_dict(cut.to_dict())
	check("cuts survive serialization", rt2.cuts.size() == 1
			and rt2.cuts[0].is_equal_approx(Vector3(1, 2, 3)))
	cut.add_cable(Vector3.ZERO, Vector3(0, 5, 0))
	cut.add_gear("mat", Vector3.ONE)
	cut.add_gear("prop", Vector3.ONE)
	cut.add_gear("bogus", Vector3.ONE)
	check("unknown gear kind is rejected",
			cut.cables.size() == 1 and cut.gear.size() == 2)
	var rt3 := BlastPlan.from_dict(cut.to_dict())
	check("cables and gear survive serialization",
			rt3.cables.size() == 1 and rt3.gear.size() == 2
			and rt3.gear[1]["kind"] == "prop")
	print("")
	print("ALL PASS" if failures == 0 else "%d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
