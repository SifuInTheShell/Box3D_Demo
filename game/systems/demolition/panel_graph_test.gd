## Headless test runner for PanelGraph:
##   godot --headless -s systems/demolition/panel_graph_test.gd --path game
## Geometry mimics building_gen.gd's platform construction (piers + band).
extends SceneTree

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func panel(id: String, pos: Vector3, size: Vector3, density := 1.2) -> Dictionary:
	return {"id": id, "pos": pos, "size": size, "density": density}


func _init() -> void:
	# Portal frame in panel form: two piers (0.35 thick walls, building_gen's T)
	# carrying one lintel band spanning both.
	var t := 0.35
	var pier_h := 2.05
	var band := [
		panel("pierL", Vector3(-1.5, pier_h * 0.5, 0.0), Vector3(1.0, pier_h, t)),
		panel("pierR", Vector3(1.5, pier_h * 0.5, 0.0), Vector3(1.0, pier_h, t)),
		panel("band", Vector3(0.0, pier_h + 0.375, 0.0), Vector3(4.0, 0.75, t)),
	]
	var g := PanelGraph.build(band)
	check("piers rest on ground", g["supports"]["pierL"] == ["ground"]
			and g["supports"]["pierR"] == ["ground"])
	check("band rests on both piers", (g["supports"]["band"] as Array).size() == 2,
			str(g["supports"]["band"]))
	check("band->pier contact area = pier_w * t",
			absf(float(g["areas"]["band->pierL"]) - 1.0 * t) < 1e-6,
			str(g["areas"].get("band->pierL")))

	var a := PanelGraph.analyze(band)
	var band_mass: float = a["masses"]["band"]
	check("band load splits evenly (equal areas)",
			absf(float(a["edge_load"]["band->pierL"]) - band_mass * 0.5) < 1e-6)
	var pier_ground: float = a["edge_load"]["pierL->ground"]
	check("pier carries own mass + half band",
			absf(pier_ground - (float(a["masses"]["pierL"]) + band_mass * 0.5)) < 1e-6)
	check("nothing unsupported", (a["unsupported"] as Array).is_empty())

	# Cut the right pier: band load all flows left; stress on the left contact
	# doubles; structure still "supported" (one path), so the analysis reports
	# doubled utilization rather than a free-fall flag.
	var cut := [band[0], band[2]]
	var a2 := PanelGraph.analyze(cut)
	check("after cut: band load all on left pier",
			absf(float(a2["edge_load"]["band->pierL"]) - band_mass) < 1e-6)
	check("after cut: contact stress doubles",
			absf(float(a2["edge_stress"]["band->pierL"])
			/ float(a["edge_stress"]["band->pierL"]) - 2.0) < 1e-6)

	# Floating slab (nothing beneath): flagged unsupported.
	var floating := [panel("slab", Vector3(0.0, 5.0, 0.0), Vector3(2.0, 0.2, 2.0))]
	var a3 := PanelGraph.analyze(floating)
	check("floating slab flagged unsupported", a3["unsupported"] == ["slab"])

	# Certification: the frame passes; the cut frame passes with a generous
	# sigma but fails when sigma_max makes the doubled stress exceed margin.
	var sigma_pass := 1.0e6
	check("intact frame certifies", PanelGraph.certify(band, sigma_pass)["ok"])
	check("floating slab fails certification",
			not PanelGraph.certify(floating, sigma_pass)["ok"])
	var s_left: float = a2["edge_stress"]["band->pierL"]
	var tight_sigma := s_left / 0.7 * 0.99   # margin 0.7 -> just over the line
	var cert := PanelGraph.certify(cut, tight_sigma)
	check("overstressed cut frame fails tight certification",
			not cert["ok"] and (cert["overstressed"] as Array).size() >= 1)

	# Stacked storeys: slab on band-level walls, wall on slab (platform style).
	var stack := [
		panel("wall1", Vector3(0.0, 1.4, 0.0), Vector3(3.0, 2.8, t)),
		panel("slab1", Vector3(0.0, 2.8 + 0.11, 0.0), Vector3(3.0, 0.22, 2.0)),
		panel("wall2", Vector3(0.0, 2.8 + 0.22 + 1.4, 0.0), Vector3(3.0, 2.8, t)),
	]
	var a4 := PanelGraph.analyze(stack)
	check("storey chain resolves: ground carries all",
			absf(float(a4["edge_load"]["wall1->ground"])
			- (float(a4["masses"]["wall1"]) + float(a4["masses"]["slab1"])
			+ float(a4["masses"]["wall2"]))) < 1e-6)

	print("")
	if failures == 0:
		print("ALL PASS")
	else:
		printerr("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
