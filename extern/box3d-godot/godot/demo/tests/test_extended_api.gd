extends Node3D

## Runtime checks for the "Extended core access III" binding: the near-complete
## Box3D C API surface (world queries/rules/events, body + shape access, new
## joint types and live readouts, replay playback, standalone geometry).
## Run with:  godot --headless --path . res://tests/test_extended_api.tscn -- --selftest

var _all_ok := true
var _joint_events := 0


func _ready() -> void:
	await _test_world_queries()
	await _test_collision_rules()
	await _test_body_access()
	await _test_heightfield()
	await _test_joint_readouts()
	await _test_new_joints()
	await _test_joint_events()
	await _test_replay()
	_test_geometry()
	print("[ext] ALL -> ", "PASS" if _all_ok else "FAIL")
	get_tree().quit(0 if _all_ok else 1)


func _check(name: String, ok: bool) -> void:
	if not ok:
		_all_ok = false
	print("[ext] %s -> %s" % [name, "PASS" if ok else "FAIL"])


func _steps(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _world() -> Box3DWorld:
	var w := Box3DWorld.new()
	add_child(w)
	return w


func _floor(w: Box3DWorld) -> Box3DBody:
	var f := Box3DBody.new()
	f.body_type = Box3DBody.STATIC
	f.box_size = Vector3(40, 1, 40)
	f.position = Vector3(0, -0.5, 0)
	w.add_child(f)
	return f


func _box(w: Box3DWorld, pos: Vector3) -> Box3DBody:
	var b := Box3DBody.new()
	b.position = pos
	w.add_child(b)
	return b


func _test_world_queries() -> void:
	var w := _world()
	var fl := _floor(w)
	var b := _box(w, Vector3(0, 0.5, 0))
	await _steps(5)
	var hit: Dictionary = w.cast_ray_static(Vector3(5, 5, 5), Vector3(5, -5, 5))
	_check("cast_ray_static hits the static floor only", hit.get("hit", false) and hit.get("collider") == fl)
	var miss: Dictionary = w.cast_ray_static(Vector3(0, 5, 0), Vector3(0, 0.6, 0))
	_check("cast_ray_static ignores the dynamic box", not miss.get("hit", true))
	var over: Array = w.overlap_shape({"type": "sphere", "radius": 0.3}, Transform3D(Basis(), Vector3(0, 0.5, 0)))
	_check("overlap_shape finds the box", over.has(b))
	var stat: Array = w.overlap_aabb_static(AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)))
	_check("overlap_aabb_static returns only static", stat.has(fl) and not stat.has(b))
	var cast: Dictionary = w.cast_shape({"type": "box", "size": Vector3(0.5, 0.5, 0.5)}, Transform3D(Basis(), Vector3(0, 5, 0)), Vector3(0, -10, 0))
	_check("cast_shape box hits the box top", cast.get("hit", false) and cast.get("collider") == b)
	var frac: float = w.cast_mover(Vector3(-5, 0.8, 0), Vector3(10, 0, 0), 0.3, 1.0)
	_check("cast_mover stops at the box (fraction %.2f)" % frac, frac > 0.2 and frac < 0.6)
	var draw: Dictionary = w.get_debug_draw_data()
	_check("get_debug_draw_data reports shapes", draw.has("shapes") and (draw["shapes"] as Array).size() >= 2)
	_check("world count / live reads", Box3DWorld.get_world_count() >= 1 and w.is_sleeping_enabled() and w.get_live_gravity().is_equal_approx(w.gravity))
	w.restitution_iterations = 2
	w.friction_mix = Box3DWorld.MIX_MAX
	await _steps(2)
	_check("restitution_iterations / friction_mix accepted", w.restitution_iterations == 2 and w.friction_mix == Box3DWorld.MIX_MAX)
	w.queue_free()
	await _steps(1)


func _test_collision_rules() -> void:
	var w := _world()
	var fl := _floor(w)
	fl.custom_filtering = true
	var b := _box(w, Vector3(0, 2, 0))
	b.custom_filtering = true
	await _steps(1)
	w.set_body_pair_collision_enabled(b, fl, false)
	_check("pair rule stored", not w.is_body_pair_collision_enabled(b, fl))
	await _steps(90)
	_check("pair rule lets the box fall through the floor (y %.2f)" % b.global_position.y, b.global_position.y < -2.0)
	w.queue_free()
	await _steps(1)


func _test_body_access() -> void:
	var w := _world()
	_floor(w)
	var s := Box3DBody.new()
	s.shape_type = Box3DBody.SPHERE
	s.sphere_radius = 0.5
	s.position = Vector3(0, 3, 0)
	s.safety_factor = 0.4
	s.body_name = "ball"
	w.add_child(s)
	await _steps(2)
	var sph: Dictionary = s.get_shape_sphere()
	_check("get_shape_sphere radius", is_equal_approx(sph.get("radius", 0.0), 0.5))
	_check("extents", is_equal_approx(s.get_min_extent(), 0.5) and s.get_max_extent().length() > 0.0)
	_check("safety_factor / body_name live", is_equal_approx(s.safety_factor, 0.4) and s.body_name == "ball")
	s.gravity_scale = 0.0
	s.set_linear_velocity(Vector3.ZERO)
	await _steps(1)
	var y0 := s.global_position.y
	await _steps(20)
	_check("live gravity_scale 0 freezes fall", absf(s.global_position.y - y0) < 0.05 and is_equal_approx(s.get_gravity_scale(), 0.0))
	s.gravity_scale = 1.0
	var r: Dictionary = s.cast_ray(Vector3(0, 10, 0), Vector3(0, -10, 0))
	_check("body cast_ray hits sphere", r.get("hit", false))
	var hull := Box3DBody.new()
	hull.position = Vector3(3, 0.5, 0)
	w.add_child(hull)
	await _steps(2)
	var hd: Dictionary = hull.get_shape_hull()
	_check("get_shape_hull of box has 8 points", (hd.get("points", PackedVector3Array()) as PackedVector3Array).size() == 8)
	var md: Dictionary = hull.compute_shape_mass_data()
	_check("compute_shape_mass_data mass ~1", is_equal_approx(snappedf(md.get("mass", 0.0), 0.01), 1.0))
	await _steps(60)
	var contacts: Array = hull.get_shape_contact_data()
	_check("shape contact data on resting box", contacts.size() >= 1)
	w.queue_free()
	await _steps(1)


func _test_heightfield() -> void:
	var w := _world()
	var hf := Box3DBody.new()
	hf.body_type = Box3DBody.STATIC
	hf.shape_type = Box3DBody.HEIGHTFIELD
	var n := 9
	var h := PackedFloat32Array()
	h.resize(n * n)
	h.fill(0.0)
	hf.heightfield_heights = h
	hf.heightfield_count_x = n
	hf.heightfield_count_z = n
	hf.heightfield_scale = Vector3(1, 1, 1)
	hf.position = Vector3(-4, 0, -4)
	w.add_child(hf)
	var b := _box(w, Vector3(0, 2, 0))
	await _steps(120)
	_check("box rests on height field (y %.2f)" % b.global_position.y, absf(b.global_position.y - 0.5) < 0.1)
	_check("get_shape_height_field returns data", not hf.get_shape_height_field().is_empty())
	w.queue_free()
	await _steps(1)


func _test_joint_readouts() -> void:
	var w := _world()
	var a := _box(w, Vector3(0, 5, 0))
	a.body_type = Box3DBody.STATIC
	var b := _box(w, Vector3(0, 3, 0))
	var j := Box3DDistanceJoint.new()
	j.position = Vector3(0, 5, 0)
	w.add_child(j)
	j.body_a = j.get_path_to(a)
	j.body_b = j.get_path_to(b)
	await _steps(30)
	_check("distance get_current_length ~2 (%.2f)" % j.get_current_length(), absf(j.get_current_length() - 2.0) < 0.1)
	_check("joint get_live_settings non-empty", not j.get_live_settings().is_empty())
	_check("joint body nodes", j.get_body_a_node() == a and j.get_body_b_node() == b)
	var links: Array = b.get_joints()
	_check("body.get_joints maps to the joint node", links.size() == 1 and links[0].get("joint") == j)
	var s := Box3DSliderJoint.new()
	var c := _box(w, Vector3(3, 5, 0))
	w.add_child(s)
	s.position = Vector3(3, 5, 0)
	s.rotation = Vector3(0, 0, PI / 2) # slide along world Y
	s.body_a = s.get_path_to(c)
	await _steps(30)
	_check("slider get_current_translation moves (%.2f)" % s.get_current_translation(), absf(s.get_current_translation()) > 0.5)
	w.queue_free()
	await _steps(1)


func _test_new_joints() -> void:
	var w := _world()
	var fl := _floor(w)
	var b := _box(w, Vector3(0, 0.5, 0))
	var f := Box3DFilterJoint.new()
	w.add_child(f)
	f.body_a = f.get_path_to(b)
	f.body_b = f.get_path_to(fl)
	await _steps(60)
	_check("filter joint disables box/floor collision (y %.2f)" % b.global_position.y, b.global_position.y < -1.0)
	var m := Box3DMoverJoint.new()
	var c := _box(w, Vector3(5, 3, 0))
	c.gravity_scale = 0.0
	w.add_child(m)
	m.body_a = m.get_path_to(c)
	m.linear_velocity = Vector3(2, 0, 0)
	await _steps(60)
	_check("mover joint drives the body (vx %.2f)" % c.get_linear_velocity().x, c.get_linear_velocity().x > 1.0)
	var p := Box3DPogoJoint.new()
	_check("pogo joint instantiates", p != null and p.rest_length > 0.0)
	p.free()
	w.queue_free()
	await _steps(1)


func _test_joint_events() -> void:
	var w := _world()
	w.joint_event.connect(func(_j, _id): _joint_events += 1)
	var a := _box(w, Vector3(0, 5, 0))
	a.body_type = Box3DBody.STATIC
	var b := _box(w, Vector3(0, 4, 0))
	b.density = 50.0
	var j := Box3DFixedJoint.new()
	j.position = Vector3(0, 4.5, 0)
	w.add_child(j)
	j.body_a = j.get_path_to(a)
	j.body_b = j.get_path_to(b)
	await _steps(2)
	j.set_force_threshold(1.0)
	await _steps(10)
	_check("joint_event fires past force threshold (%d)" % _joint_events, _joint_events > 0)
	w.queue_free()
	await _steps(1)


func _test_replay() -> void:
	var w := _world()
	w.auto_step = false
	_floor(w)
	var b := _box(w, Vector3(0, 3, 0))
	await _steps(1)
	_check("start_recording", w.start_recording())
	for i in 60:
		w.step(1.0 / 60.0)
	var final_y := b.global_position.y
	var data: PackedByteArray = w.stop_recording()
	var player: Box3DReplayPlayer = Box3DReplayPlayer.create(data, 1)
	_check("replay player opens (%d frames)" % (player.get_frame_count() if player else -1), player != null and player.get_frame_count() >= 60)
	if player:
		while not player.is_at_end():
			player.step_frame()
		var ys: Array = []
		for i in player.get_body_count():
			ys.append(player.get_body_transform(i).origin.y)
		var match_found := false
		for y in ys:
			if absf(y - final_y) < 0.001:
				match_found = true
		_check("replay reproduces the box pose (%.3f)" % final_y, match_found and not player.has_diverged())
		player.seek_frame(0)
		_check("seek_frame(0)", player.get_frame() == 0)
	w.queue_free()
	await _steps(1)


func _test_geometry() -> void:
	if not ClassDB.class_exists("Box3DGeometry"):
		_check("Box3DGeometry registered", false)
		return
	var v: Dictionary = ClassDB.class_call_static("Box3DGeometry", "get_version")
	_check("Box3DGeometry.get_version", v.has("major"))
	var f: Dictionary = ClassDB.class_call_static("Box3DGeometry", "get_default_filter")
	_check("get_default_filter", f.get("category_bits", 0) != 0)
	var r: Dictionary = ClassDB.class_call_static("Box3DGeometry", "ray_cast", {"type": "sphere", "radius": 1.0}, Vector3(0, 5, 0), Vector3(0, -10, 0), 1.0, Transform3D())
	_check("Box3DGeometry.ray_cast vs sphere (%s)" % str(r.get("point", "")), r.get("hit", false))
	var methods := ClassDB.class_get_method_list("Box3DGeometry", true)
	_check("Box3DGeometry exposes many static methods (%d)" % methods.size(), methods.size() > 40)
