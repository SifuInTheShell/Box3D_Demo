## Headless test runner for BrickLattice. Pure GDScript:
##   godot --headless -s systems/demolition/brick_lattice_test.gd --path game
## Expected values from the validated Python reference (docs/destructible-construction.md).
extends SceneTree

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func _init() -> void:
	# Occupancy + mass
	var lat := BrickLattice.new()
	lat.fill_box(Vector3i(0, 0, 0), Vector3i(20, 12, 1))
	check("wall cell count = 240", lat.size() == 240, str(lat.size()))
	check("brick mass ~115 kg", absf(lat.brick_mass() - 115.2) < 0.5,
			str(lat.brick_mass()))

	# Full grounding on intact wall
	check("intact wall fully grounded", lat.grounded_set().size() == 240)

	# Full band cut at y=6 -> top 5 rows detach as one cluster
	var removed: Array[Vector3i] = []
	for x in 20:
		var c := Vector3i(x, 6, 0)
		lat.remove_cell(c)
		removed.append(c)
	var clusters := lat.detached_clusters_after(removed)
	check("band cut -> one detached cluster", clusters.size() == 1, str(clusters.size()))
	if clusters.size() == 1:
		check("cluster is top 5 rows (100 cells)", clusters[0].size() == 100,
				str(clusters[0].size()))

	# Blast hole mid-wall -> nothing detaches (still connected around the hole)
	var lat2 := BrickLattice.new()
	lat2.fill_box(Vector3i(0, 0, 0), Vector3i(20, 12, 1))
	var rm2 := lat2.carve_sphere(lat2.cell_to_world(Vector3i(10, 6, 0)), 3.2 * lat2.cell_size)
	check("carve removed ~37 cells", rm2.size() >= 30 and rm2.size() <= 45, str(rm2.size()))
	check("hole detaches nothing", lat2.detached_clusters_after(rm2).size() == 0)

	# L-cut: sever the right corner -> exactly the 4x5 corner detaches
	var lat3 := BrickLattice.new()
	lat3.fill_box(Vector3i(0, 0, 0), Vector3i(20, 12, 1))
	var rm3: Array[Vector3i] = []
	for x in range(15, 20):
		var c := Vector3i(x, 6, 0)
		lat3.remove_cell(c)
		rm3.append(c)
	for y in range(7, 12):
		var c2 := Vector3i(15, y, 0)
		lat3.remove_cell(c2)
		rm3.append(c2)
	var clusters3 := lat3.detached_clusters_after(rm3)
	check("corner cut -> one cluster of 20 cells",
			clusters3.size() == 1 and clusters3[0].size() == 20,
			str(clusters3.map(func(cl): return cl.size())))

	# Chunk keys
	check("chunk_key positive", BrickLattice.chunk_key(Vector3i(9, 0, 15)) == Vector3i(1, 0, 1))
	check("chunk_key negative", BrickLattice.chunk_key(Vector3i(-1, 0, 0)) == Vector3i(-1, 0, 0))

	# World/cell round trip
	var lat4 := BrickLattice.new()
	var cell := Vector3i(3, 5, -2)
	check("world<->cell round trip", lat4.world_to_cell(lat4.cell_to_world(cell)) == cell)

	# Greedy box decomposition
	var wall: Dictionary = {}
	for x in 20:
		for y in 12:
			wall[Vector3i(x, y, 0)] = true
	var wb := BrickLattice.greedy_boxes(wall)
	check("solid wall -> 1 box", wb.size() == 1, str(wb.size()))
	if wb.size() == 1:
		check("wall box size 20x12x1", wb[0]["size"] == Vector3i(20, 12, 1),
				str(wb[0]["size"]))

	var lshape: Dictionary = {}
	for x in 10:
		lshape[Vector3i(x, 0, 0)] = true
	for y in range(1, 6):
		lshape[Vector3i(0, y, 0)] = true
	check("L-shape -> 2 boxes", BrickLattice.greedy_boxes(lshape).size() == 2)

	var hole_wall: Dictionary = {}
	for x in 20:
		for y in 12:
			if (x - 10) * (x - 10) + (y - 6) * (y - 6) > 10:
				hole_wall[Vector3i(x, y, 0)] = true
	var hb := BrickLattice.greedy_boxes(hole_wall)
	var covered := 0
	for bx in hb:
		var s: Vector3i = bx["size"]
		covered += s.x * s.y * s.z
	check("hole wall: exact coverage, no overlap", covered == hole_wall.size(),
			"%d cells in %d boxes" % [covered, hb.size()])
	check("hole wall -> ~12 boxes", hb.size() >= 5 and hb.size() <= 25, str(hb.size()))

	print("")
	if failures == 0:
		print("ALL PASS")
	else:
		printerr("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
