## Structural-integrity solver over a BrickLattice: after any carve, decides
## which remaining bricks can no longer be supported and must fail — so a blast
## hole leads to physically correct secondary collapse, not a floating wall.
## Pure GDScript; validated against the Python reference (docs/destructible-construction.md §5).
##
## Two-rule model:
##   Rule A (span/bending, here): a cell is COLUMNED if a continuous vertical
##     chain of cells connects it to ground. Every cell must lie within
##     `span_max` horizontal hops (through the structure) of a columned cell.
##   Rule B (load/compression): DemoMath.support_loads utilization > 1 breaks
##     connections — evaluated on the coarse graph by the caller.
##
## Runtime use: after a carve, call integrity_failures() once per tick round;
## returned cells detach as falling clusters (BrickLattice.detached_clusters_
## after handles pure disconnection; this adds overload failures). Bake use:
## cascade() must return zero rounds for every generated structure.
class_name StructuralIntegrity

const H_NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const V_NEIGHBORS: Array[Vector3i] = [Vector3i(0, 1, 0), Vector3i(0, -1, 0)]

const UNREACHED := 2147483647


## Cells with a continuous vertical chain to the ground row.
static func columned_cells(lat: BrickLattice) -> Dictionary:
	var col: Dictionary = {}
	var ys: Array = []
	var by_y: Dictionary = {}
	for c in lat.cells:
		var v := c as Vector3i
		if not by_y.has(v.y):
			by_y[v.y] = []
			ys.append(v.y)
		by_y[v.y].append(v)
	ys.sort()
	for y in ys:
		for v in by_y[y]:
			var cell := v as Vector3i
			if cell.y == lat.ground_y:
				col[cell] = true
			elif col.has(cell + Vector3i(0, -1, 0)):
				col[cell] = true
	return col


## Horizontal support distance of every cell: hops from the nearest columned
## cell, moving through occupied cells (horizontal hop costs 1, vertical 0).
static func support_distances(lat: BrickLattice) -> Dictionary:
	var dist: Dictionary = {}
	var queue: Array[Vector3i] = []
	for c in columned_cells(lat):
		dist[c] = 0
		queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var d: int = dist[c]
		for o in H_NEIGHBORS:
			var n: Vector3i = c + o
			if lat.cells.has(n) and int(dist.get(n, UNREACHED)) > d + 1:
				dist[n] = d + 1
				queue.append(n)
		for o in V_NEIGHBORS:
			var n2: Vector3i = c + o
			if lat.cells.has(n2) and int(dist.get(n2, UNREACHED)) > d:
				dist[n2] = d
				queue.append(n2)
	return dist


## Cells violating Rule A for the given span (material property, in bricks).
static func span_failures(lat: BrickLattice, span_max: int) -> Array[Vector3i]:
	var dist := support_distances(lat)
	var failed: Array[Vector3i] = []
	for c in lat.cells:
		if int(dist.get(c, UNREACHED)) > span_max:
			failed.append(c as Vector3i)
	return failed


## One integrity round: detached-from-ground clusters plus span failures.
## Does NOT mutate the lattice — the caller carves the returned cells when
## materializing them as falling clusters, then may run another round.
static func integrity_failures(lat: BrickLattice, span_max: int) -> Array[Vector3i]:
	var grounded := lat.grounded_set()
	var failed: Dictionary = {}
	for c in lat.cells:
		if not grounded.has(c):
			failed[c] = true
	for c in span_failures(lat, span_max):
		failed[c] = true
	var out: Array[Vector3i] = []
	for c in failed:
		out.append(c as Vector3i)
	return out


## Full cascade to a stable state (bake-time certification / CI). MUTATES the
## lattice. Returns the Array of per-round failed-cell Arrays; an empty result
## means the structure is certified stable.
static func cascade(lat: BrickLattice, span_max: int, max_rounds: int = 50) -> Array:
	var rounds: Array = []
	for _i in max_rounds:
		var failed := integrity_failures(lat, span_max)
		if failed.is_empty():
			return rounds
		for c in failed:
			lat.remove_cell(c)
		rounds.append(failed)
	push_error("StructuralIntegrity.cascade: no fixpoint within %d rounds" % max_rounds)
	return rounds
