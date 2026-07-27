# Smoke test: verifies the Box3D extension is wired up. A crate drops onto a
# floor. Replace with the real game entry point as systems/ grows.
extends Node3D


func _ready() -> void:
	var world := Box3DWorld.new()
	add_child(world)

	var ground := Box3DBody.new()
	ground.body_type = Box3DBody.STATIC
	ground.box_size = Vector3(20, 1, 20)
	ground.position = Vector3(0, -0.5, 0)
	ground.auto_visual = true
	world.add_child(ground)

	var crate := Box3DBody.new()
	crate.position = Vector3(0, 5, 0)
	crate.rotation_degrees = Vector3(15, 25, 0)
	crate.auto_visual = true
	world.add_child(crate)

	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0, 4, 10)
	camera.look_at(Vector3(0, 1, 0))

	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.shadow_enabled = true
