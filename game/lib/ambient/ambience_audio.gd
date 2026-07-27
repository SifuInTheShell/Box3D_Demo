extends Node

## Ambience: a bed loop plus AmbientSim.OneShots-scheduled spot sounds — the
## Tsushima "fake birds" model (research §1): no simulated sources, just a
## seeded scheduler and a handful of CC0 recordings. A blast opens a quiet
## window: the bed ducks to silence and every voice freezes, then the world
## resumes changed. The silence after the charge is the point.
##
##   AmbienceAudio.attach(world, "street", seed)
##
## Asset-agnostic on purpose: streams load from AUDIO_DIR when the Stage-D
## fetch round lands them (bed: <set>.ogg; voices: <voice>_1.ogg …); until
## then every player just stays empty and the scheduler still runs, so the
## wiring and the tests never depend on fetched files.

const _Self = preload("res://lib/ambient/ambience_audio.gd")

const AUDIO_DIR := "res://lib/ambient/audio/"
const VOICE_VARIANTS := 4   # <voice>_1.ogg .. <voice>_4.ogg, whichever exist
const BED_DB := -8.0        # bed loop target volume
const QUIET_BASE := 5.0     # seconds of quiet for an impulse-0 disturbance
const QUIET_PER_IMPULSE := 0.45

const SETS := {
	"street": {"voices": {
		"birdsong": [5.0, 13.0], "dog": [20.0, 55.0],
		"chatter": [9.0, 24.0], "car_pass": [14.0, 40.0]}},
	"rural": {"voices": {
		"birdsong": [3.0, 9.0], "rooster": [25.0, 70.0],
		"dog": [18.0, 50.0], "wind_gust": [10.0, 26.0]}},
}

var ambience_set := "street"

var _shots  # AmbientSim.OneShots
var _rng := RandomNumberGenerator.new()
var _bed: AudioStreamPlayer
var _voice_streams := {}   # voice -> Array[AudioStream]
var _pool: Array = []      # one-shot AudioStreamPlayers, round-robin
var _pool_i := 0


static func attach(world: Node, which: String, seed_v: int) -> Node:
	var aa := _Self.new()
	aa.setup(which, seed_v)
	world.add_child(aa)
	return aa


func setup(which: String, seed_v: int) -> void:
	ambience_set = which if SETS.has(which) else "street"
	_rng.seed = seed_v
	_shots = AmbientSim.OneShots.new(seed_v)
	for voice in SETS[ambience_set]["voices"]:
		var gap: Array = SETS[ambience_set]["voices"][voice]
		_shots.add_voice(voice, gap[0], gap[1])


func disturb(_at: Vector3, _radius: float, impulse := 0.0) -> void:
	_shots.disturb(clampf(QUIET_BASE + impulse * QUIET_PER_IMPULSE, 4.0, 14.0))


func _ready() -> void:
	_bed = AudioStreamPlayer.new()
	_bed.stream = _load_stream(AUDIO_DIR + ambience_set + ".ogg")
	if _bed.stream is AudioStreamOggVorbis:
		_bed.stream.loop = true  # beds loop; one-shots keep the default
	_bed.volume_db = BED_DB
	_bed.bus = "Master"
	add_child(_bed)
	if _bed.stream != null:
		_bed.play()
	for voice in SETS[ambience_set]["voices"]:
		var streams: Array = []
		for v in VOICE_VARIANTS:
			var s := _load_stream(AUDIO_DIR + "%s_%d.ogg" % [voice, v + 1])
			if s != null:
				streams.append(s)
		_voice_streams[voice] = streams
	for i in 3:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)


func _process(delta: float) -> void:
	for voice in _shots.step(delta):
		_play_voice(voice)
	var duck: float = _shots.duck01()
	_bed.volume_db = BED_DB + linear_to_db(maxf(duck, 0.001))


func _play_voice(voice: String) -> void:
	var streams: Array = _voice_streams.get(voice, [])
	if streams.is_empty():
		return  # asset not fetched yet — the schedule still advanced
	var p: AudioStreamPlayer = _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = streams[_rng.randi_range(0, streams.size() - 1)]
	p.volume_db = _rng.randf_range(-4.0, 0.0)
	p.play()


static func _load_stream(path: String) -> AudioStream:
	return load(path) if ResourceLoader.exists(path) else null
