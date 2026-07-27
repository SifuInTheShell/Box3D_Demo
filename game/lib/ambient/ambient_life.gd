extends Node3D

## The ambient-life coordinator: one node per site that owns the cosmetic
## "this place is alive" layer — birds, lit windows, ambience audio — and
## relays disturbances into it. Sibling of fire_system/glass_system in
## spirit, but STRICTLY COSMETIC: nothing here touches physics or the
## determinism hash. All randomness is seeded (scene seed + salt) so a scene
## looks the same on every run.
##
##   AmbientLife.attach(world, {
##       "birds": 12, "perches": [Vector3...],   # roof lines, branches
##       "windows_lit": 0.4,                      # fraction of panes aglow
##       "ambience": "street",                    # ambience_audio.gd set
##   }, seed)
##
## Explosions reach it the same way they reach fire/glass:
##   call_group("ambient_life", "disturb", at, radius, impulse)
## Birds scare to ~3x the blast radius (the glass lesson: the neighbourhood
## reacting far beyond the damage is the tell that the world noticed).

const _Self = preload("res://lib/ambient/ambient_life.gd")
const BirdFlock = preload("res://lib/ambient/bird_flock.gd")
const WindowLife = preload("res://lib/ambient/window_life.gd")
const AmbienceAudio = preload("res://lib/ambient/ambience_audio.gd")

const SCARE_MULT := 3.0  # birds flee this far beyond the blast radius

var _flock: Node3D
var _windows: Node3D
var _audio: Node


static func attach(world: Node3D, spec: Dictionary, seed_v: int) -> Node3D:
	var al := _Self.new()
	world.add_child(al)
	var birds: int = spec.get("birds", 0)
	var perches: Array = spec.get("perches", [])
	if birds > 0 and not perches.is_empty():
		al._flock = BirdFlock.attach(al, perches, birds, seed_v ^ 0xB19D)
	var lit: float = spec.get("windows_lit", 0.0)
	if lit > 0.0:
		al._windows = WindowLife.attach(al, lit, seed_v ^ 0x11F3)
	var ambience: String = spec.get("ambience", "")
	if ambience != "":
		al._audio = AmbienceAudio.attach(al, ambience, seed_v ^ 0xA0D1)
	return al


func _ready() -> void:
	add_to_group("ambient_life")


## Blast coupling (ExplosionFX.blast broadcasts to the group).
func disturb(at: Vector3, radius: float, impulse := 0.0) -> void:
	if _flock != null:
		_flock.disturb(at, radius * SCARE_MULT)
	if _audio != null:
		_audio.disturb(at, radius, impulse)
	# Windows need no relay: broken panes take their glow with them, and
	# power loss is the site's call (darken_building) — not the blast's.


func darken_building(building: int) -> void:
	if _windows != null:
		_windows.darken_building(building)


## HUD/debug readout, same spirit as fire_system's counters.
func stats() -> Dictionary:
	return {
		"birds_perched": _flock.perched_count() if _flock != null else 0,
		"windows_lit": _windows.lit_count() if _windows != null else 0,
	}
