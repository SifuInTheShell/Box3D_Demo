## Headless test runner for StructuralIntegrity:
##   godot --headless -s systems/demolition/structural_integrity_test.gd --path game
## Expected values from the validated Python reference (docs/destructible-construction.md §5).
extends SceneTree

const SPAN := 3

var failures := 0


func check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[PASS] %s %s" % [name, detail])
	else:
		failures += 1
		printerr("[FAIL] %s %s" % [name, detail])


func wall_with_hole(width: int) -> BrickLattice:
	var lat := BrickLattice.new()
	lat.fill_box(Vector3i(0, 0, 0), Vector3i(24, 12, 1))
	@warning_ignore("integer_division")
	var x0 := (24 - width) / 2
	for x in range(x0, x0 + width):
		for y in range(4, 7):
			lat.remove_cell(Vector3i(x, y, 0))
	return lat


func _init() -> void:
	# Intact wall: stable
	var full := wall_with_hole(0)
	check("intact wall: no failures",
			StructuralIntegrity.cascade(full, SPAN).is_empty())

	# Narrow hole: lintel holds
	var narrow := wall_with_hole(4)
	var before := narrow.size()
	check("narrow hole: lintel holds",
			StructuralIntegrity.cascade(narrow, SPAN).is_empty()
			and narrow.size() == before)

	# Wide hole: mid-span above the hole collapses, flanks stand
	var wide := wall_with_hole(10)
	var rounds := StructuralIntegrity.cascade(wide, SPAN)
	check("wide hole: collapse happened (20 cells)", not rounds.is_empty(),
			str(rounds.map(func(r): return r.size())))
	var lost := 0
	for r in rounds:
		lost += (r as Array).size()
	check("wide hole: lost exactly 20 cells", lost == 20, str(lost))
	var flanks_ok := true
	for x in [0, 1, 2, 3, 4, 19, 20, 21, 22, 23]:
		for y in 12:
			if not wide.has_cell(Vector3i(x, y, 0)):
				flanks_ok = false
	check("wide hole: flanks stand", flanks_ok)
	var mid_gone := true
	for x in [11, 12]:
		for y in range(7, 12):
			if wide.has_cell(Vector3i(x, y, 0)):
				mid_gone = false
	check("wide hole: mid-span above hole gone", mid_gone)

	# Table: 8-wide deck on two legs is stable; cutting one leg drops the
	# cantilever beyond SPAN while the supported end stands.
	var table := BrickLattice.new()
	for x in 8:
		table.add_cell(Vector3i(x, 4, 0))
	for y in 4:
		table.add_cell(Vector3i(0, y, 0))
		table.add_cell(Vector3i(7, y, 0))
	var t_before := table.size()
	check("two-legged table stable",
			StructuralIntegrity.cascade(table, SPAN).is_empty()
			and table.size() == t_before)

	for y in 4:
		table.remove_cell(Vector3i(7, y, 0))
	StructuralIntegrity.cascade(table, SPAN)
	var stand: Array = []
	for x in 8:
		if table.has_cell(Vector3i(x, 4, 0)):
			stand.append(x)
	check("one-legged table: deck stands only within span (x 0..3)",
			stand == [0, 1, 2, 3], str(stand))
	check("one-legged table: leg intact", table.has_cell(Vector3i(0, 0, 0)))

	# Determinism: same input -> same survivor set
	var w1 := wall_with_hole(10)
	var w2 := wall_with_hole(10)
	StructuralIntegrity.cascade(w1, SPAN)
	StructuralIntegrity.cascade(w2, SPAN)
	var same := w1.size() == w2.size()
	if same:
		for c in w1.cells:
			if not w2.has_cell(c):
				same = false
				break
	check("cascade deterministic", same)

	print("")
	if failures == 0:
		print("ALL PASS")
	else:
		printerr("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
