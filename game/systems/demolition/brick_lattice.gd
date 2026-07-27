## Sparse brick lattice for destructible structures. Pure GDScript, no engine
## nodes — the data layer under docs/destructible-construction.md. Cells are
## Vector3i grid coordinates (1 cell = 1 brick, edge = cell_size meters);
## 6-connectivity; ground plane is every cell with y == ground_y.
##
## Responsibilities: occupancy, carving, ground-connectivity, and finding
## clusters detached by a carve (incremental — only components touching the
## damage frontier are visited). Body/weld materialization lives elsewhere.
class_name BrickLattice

const NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var cell_size := 0.4        # meters per brick edge
var ground_y := 0           # cells at this y count as grounded
var cells: Dictionary = {}  # Vector3i -> true (occupancy set)


func size() -> int:
	return cells.size()


func has_cell(c: Vector3i) -> bool:
	return cells.has(c)


func add_cell(c: Vector3i) -> void:
	cells[c] = true


func remove_cell(c: Vector3i) -> void:
	cells.erase(c)


## Fills [from, to) with bricks.
func fill_box(from: Vector3i, to: Vector3i) -> void:
	for x in range(from.x, to.x):
		for y in range(from.y, to.y):
			for z in range(from.z, to.z):
				cells[Vector3i(x, y, z)] = true


## Removes all bricks whose cell center lies within radius_m of center_m
## (world space). Returns the removed cells.
func carve_sphere(center_m: Vector3, radius_m: float) -> Array[Vector3i]:
	var removed: Array[Vector3i] = []
	var c0 := world_to_cell(center_m - Vector3.ONE * radius_m)
	var c1 := world_to_cell(center_m + Vector3.ONE * radius_m) + Vector3i.ONE
	var rr := radius_m * radius_m
	for x in range(c0.x, c1.x):
		for y in range(c0.y, c1.y):
			for z in range(c0.z, c1.z):
				var c := Vector3i(x, y, z)
				if cells.has(c) and cell_to_world(c).distance_squared_to(center_m) <= rr:
					cells.erase(c)
					removed.append(c)
	return removed


func cell_to_world(c: Vector3i) -> Vector3:
	return (Vector3(c) + Vector3.ONE * 0.5) * cell_size


func world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i((p / cell_size).floor())


## Chunk key for tiered storage/collision (chunk = chunk_size^3 bricks).
static func chunk_key(c: Vector3i, chunk_size: int = 8) -> Vector3i:
	@warning_ignore("integer_division")
	return Vector3i(
			floori(float(c.x) / chunk_size),
			floori(float(c.y) / chunk_size),
			floori(float(c.z) / chunk_size))


## Full flood fill from the ground row. Returns the set (Dictionary) of
## grounded cells. O(structure); use only on load — runtime uses the
## incremental form below.
func grounded_set() -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array[Vector3i] = []
	for c in cells:
		if (c as Vector3i).y == ground_y:
			seen[c] = true
			queue.append(c)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		for o in NEIGHBORS:
			var n: Vector3i = c + o
			if cells.has(n) and not seen.has(n):
				seen[n] = true
				queue.append(n)
	return seen


## After carving `removed`, finds connected components that lost ground
## contact. Incremental: BFS only from cells adjacent to the removed set, so
## cost scales with the damaged components, not the whole structure. Returns
## an Array of clusters, each an Array[Vector3i], for materialization as a
## welded dynamic body cluster.
func detached_clusters_after(removed: Array[Vector3i]) -> Array:
	var frontier: Dictionary = {}
	for c in removed:
		for o in NEIGHBORS:
			var n: Vector3i = c + o
			if cells.has(n):
				frontier[n] = true
	var visited: Dictionary = {}
	var detached: Array = []
	for f in frontier:
		if visited.has(f):
			continue
		var comp: Dictionary = {f: true}
		var queue: Array[Vector3i] = [f]
		var grounded: bool = (f as Vector3i).y == ground_y
		var head := 0
		while head < queue.size():
			var c := queue[head]
			head += 1
			for o in NEIGHBORS:
				var n: Vector3i = c + o
				if cells.has(n) and not comp.has(n):
					comp[n] = true
					queue.append(n)
					if n.y == ground_y:
						grounded = true
		for c in comp:
			visited[c] = true
		if not grounded:
			var cluster: Array[Vector3i] = []
			for c in comp:
				cluster.append(c)
			detached.append(cluster)
	return detached


## Mass of one brick for a material density (kg/m^3).
func brick_mass(density: float = 1800.0) -> float:
	return density * cell_size * cell_size * cell_size


## Greedy decomposition of a cell set into maximal axis-aligned boxes, for
## materializing merged collision bodies (static chunks and detached clusters)
## as a handful of BOX shapes instead of per-brick bodies. Deterministic:
## seeds from the lexicographically smallest remaining cell. Returns an Array
## of { "min": Vector3i, "size": Vector3i } (size in cells).
static func greedy_boxes(cell_set: Dictionary) -> Array:
	var remaining := cell_set.duplicate()
	var boxes: Array = []
	while not remaining.is_empty():
		var seed_cell := Vector3i(2147483647, 2147483647, 2147483647)
		for c in remaining:
			var v := c as Vector3i
			if v.x < seed_cell.x or (v.x == seed_cell.x and (v.y < seed_cell.y
					or (v.y == seed_cell.y and v.z < seed_cell.z))):
				seed_cell = v
		var sx := 1
		while remaining.has(seed_cell + Vector3i(sx, 0, 0)):
			sx += 1
		var sz := 1
		while _slab_filled(remaining, seed_cell, sx, 1, sz, Vector3i(0, 0, 1)):
			sz += 1
		var sy := 1
		while _slab_filled(remaining, seed_cell, sx, sy, sz, Vector3i(0, 1, 0)):
			sy += 1
		for i in sx:
			for j in sy:
				for k in sz:
					remaining.erase(seed_cell + Vector3i(i, j, k))
		boxes.append({"min": seed_cell, "size": Vector3i(sx, sy, sz)})
	return boxes


## True if the next slab of a growing box (offset by `dir` beyond the current
## sx*sy*sz extent) is fully present in `remaining`.
static func _slab_filled(remaining: Dictionary, origin: Vector3i,
		sx: int, sy: int, sz: int, dir: Vector3i) -> bool:
	var base := origin + Vector3i(sx * dir.x, sy * dir.y, sz * dir.z)
	var ext_x := 1 if dir.x == 1 else sx
	var ext_y := 1 if dir.y == 1 else sy
	var ext_z := 1 if dir.z == 1 else sz
	for i in ext_x:
		for j in ext_y:
			for k in ext_z:
				if not remaining.has(base + Vector3i(i, j, k)):
					return false
	return true
