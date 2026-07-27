extends Node3D

## A demolition charge: an olive C4 brick with straps and a blinking
## detonator LED, built from primitives so it matches the gym's look.
## Parent it to the body it was placed on so it rides along (and dies with
## it if the wall is destroyed first). detonate() sets off ExplosionFX at
## the charge's position; `armed` switches the LED to a rapid blink while
## the detonation ripple is pending.

const ExplosionFX := preload("res://lib/fx/explosion_fx.gd")
# "C4" by J-Toastie (poly.pizza/m/sDrFzJlbxy), CC-BY 3.0 -- see fx/textures/CREDITS.md
const C4Scene := preload("res://lib/fx/models/c4.glb")

var blast_radius := 6.0
var blast_impulse := 7.0
var armed := false
var is_ghost := false  # placement preview: translucent, no group, never fires

var _led_mat: StandardMaterial3D
var _t := 0.0
var _falling := false


func _ready() -> void:
	if not is_ghost:
		add_to_group("charge")
		var host := get_parent()
		if host is Box3DBody:
			host.tree_exiting.connect(_on_host_dying)
	_build_visual()


func _process(delta: float) -> void:
	_t += delta
	var period := 0.12 if armed else 0.7
	_led_mat.emission_energy_multiplier = 6.0 if fmod(_t, period) < period * 0.5 else 0.15
	if _falling:
		var world := _find_world()
		if world != null:
			var hit: Dictionary = world.raycast(
					global_position, global_position + Vector3(0.0, -0.3, 0.0))
			if hit.get("hit", false):
				global_position = hit["position"] + Vector3(0.0, 0.03, 0.0)
				_falling = false
				return
		global_position.y -= 6.0 * delta


## The wall this charge is stuck to is being destroyed (queue_free from a
## fracture). Armed: the collapse sets the charge off right now, so every
## charge the player primed still delivers its explosion even when an earlier
## blast in the ripple eats its host wall. Unarmed: detach, survive, and drop
## onto the rubble, still blinking and still detonatable.
func _on_host_dying() -> void:
	var host := get_parent()
	if is_ghost or not is_inside_tree() or host == null:
		return
	# Only react to the host's own demolition -- during a scene reload the
	# whole tree exits without queue_free and the charge should just die.
	if not host.is_queued_for_deletion():
		return
	if armed:
		detonate()
		return
	var world := _find_world()
	if world == null:
		return
	var xf := global_transform
	host.remove_child(self)
	world.add_child(self)
	global_transform = xf
	_falling = true


func detonate() -> void:
	if is_ghost:
		return
	var world := _find_world()
	if world != null:
		ExplosionFX.blast(world, global_position, blast_radius, blast_impulse)
	queue_free()


func _find_world() -> Box3DWorld:
	var n: Node = self
	while n != null:
		if n is Box3DWorld:
			return n
		n = n.get_parent()
	return null


## Built extending +Z from the mount plane at z=0, so a basis whose Z column
## is the surface normal lays it flat against the wall. Ghost and placed
## charge share the same CC-BY C4 model; the ghost is faded via per-instance
## transparency so the preview shows exactly what will be placed.
func _build_visual() -> void:
	var model := C4Scene.instantiate()
	model.rotation.x = PI / 2.0  # model lies flat (+Y up); stand it on the wall
	model.scale = Vector3.ONE * 0.7
	add_child(model)
	if is_ghost:
		var stack: Array[Node] = [model]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is GeometryInstance3D:
				n.transparency = 0.55
				n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var led := _add_box(Vector3(0.05, 0.05, 0.035), Vector3(0.1, 0.12, 0.16),
			Color(1.0, 0.1, 0.08, 0.45 if is_ghost else 1.0))
	_led_mat = led
	_led_mat.emission_enabled = true
	_led_mat.emission = Color(1.0, 0.12, 0.08)
	_led_mat.emission_energy_multiplier = 4.0


func _add_box(size: Vector3, at: Vector3, color: Color) -> StandardMaterial3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mat
