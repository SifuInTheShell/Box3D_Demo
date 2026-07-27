## Global wind core — the weather the fire model was built to receive
## (fire_sim.wind / WIND_K, docs/fire-research.md: wildfire forward rate is
## ~10% of wind speed). One horizontal base vector per site plus a seeded
## TWO-LAYER gust model:
##
##   breathing  a small spectrum of seeded sines — the smooth swell and
##              flutter that never quite repeats;
##   squalls    discrete seeded events on a fixed window grid — sharp
##              erratic bursts with a fast rise and a long tail that also
##              VEER the heading while they blow, the way real gust fronts
##              do. Between squalls the wind can sag into near-lulls.
##
## Deterministic by construction: sines have seeded phases and the squall
## schedule is integer-hashed from (seed, window index), so the wind at
## time t is a PURE FUNCTION of (seed, base, gust, t) — no RNG at runtime,
## no state beyond accumulated time. Callers on a fixed physics tick get
## bit-identical weather every run.
##
## Consumers (via lib/wind/wind_system.gd): FireSim spread skew, the
## cloth-sway shader, the windsock. Wind deliberately applies NO force to
## rigid bodies — real demolition weather moves fire, dust and laundry,
## not concrete (and body forces would touch every determinism hash).
class_name WindSim

const MEANDER_RAD := 0.22   # max heading wobble from the breathing layer
# Breathing spectrum: a slow swell, a mid surge, a fast flutter (Hz ranges).
const SPEED_BANDS := [[0.03, 0.07], [0.12, 0.25], [0.5, 0.9]]
const SPEED_AMPS := [0.55, 0.3, 0.15]   # sums to 1.0
const HEAD_BANDS := [[0.015, 0.04], [0.09, 0.2]]
const HEAD_AMPS := [0.65, 0.35]
# Squalls: at most one per window, present with SQUALL_CHANCE, blowing for
# 2-6 s with a fast rise (first fifth) and a long tail.
const SQUALL_WINDOW := 22.0
const SQUALL_CHANCE := 0.6
const SQUALL_BOOST := 1.1   # peak extra speed, as a fraction of gust
const SQUALL_VEER := 0.5    # rad of sudden heading swing at full strength
const LULL_FLOOR := 0.05    # deepest lull, as a fraction of base speed

var base := Vector3.ZERO   # horizontal, m/s; zero = dead calm
var gust := 0.0            # 0..1 gustiness

var _t := 0.0
var _seed := 0
var _sw: Array = []   # breathing speed frequencies / phases
var _sp: Array = []
var _hw: Array = []   # breathing heading frequencies / phases
var _hp: Array = []


func _init(seed_v: int, base_v := Vector3.ZERO, gust_v := 0.0) -> void:
	_seed = seed_v
	base = Vector3(base_v.x, 0.0, base_v.z)
	gust = clampf(gust_v, 0.0, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for band in SPEED_BANDS:
		_sw.append(TAU * rng.randf_range(band[0], band[1]))
		_sp.append(rng.randf() * TAU)
	for band in HEAD_BANDS:
		_hw.append(TAU * rng.randf_range(band[0], band[1]))
		_hp.append(rng.randf() * TAU)


func update(dt: float) -> void:
	_t += dt


## The wind vector at time t: breathing + squalls, heading wobbled by the
## meander and veered by whatever squall is blowing.
func sample(t: float) -> Vector3:
	if base.is_zero_approx():
		return Vector3.ZERO
	var squall := _squall(t)
	var mult := 1.0 + gust * (_spectrum(t, _sw, _sp, SPEED_AMPS)
			+ SQUALL_BOOST * squall.x)
	var yaw := MEANDER_RAD * _spectrum(t, _hw, _hp, HEAD_AMPS) + gust * squall.y
	return base.rotated(Vector3.UP, yaw) * maxf(mult, LULL_FLOOR)


func current() -> Vector3:
	return sample(_t)


## Gust intensity now, normalized 0 (deep lull) .. 1 (squall peak) — for
## FX layers (windsock flutter, audio ducking, particle lean).
func gust01() -> float:
	if base.is_zero_approx() or gust <= 0.0:
		return 0.0
	var raw := _spectrum(_t, _sw, _sp, SPEED_AMPS) + SQUALL_BOOST * _squall(_t).x
	return clampf((raw + 1.0) / (1.0 + 2.0 * SQUALL_BOOST), 0.0, 1.0)


## Hard ceiling on |sample()| — two squall tails can overlap, never more.
func speed_bound() -> float:
	return base.length() * (1.0 + gust * (1.0 + 2.0 * SQUALL_BOOST))


## Hard ceiling on heading deviation from base, radians.
func veer_bound() -> float:
	return MEANDER_RAD + gust * 2.0 * SQUALL_VEER


func _spectrum(t: float, ws: Array, ps: Array, amps: Array) -> float:
	var s := 0.0
	for i in ws.size():
		s += amps[i] * sin(ws[i] * t + ps[i])
	return s


## Squall contribution at time t: x = strength 0..~2 (overlapping tails),
## y = heading veer in radians. A window's squall is fully determined by
## integer hashing, so this is stateless and replay-exact.
func _squall(t: float) -> Vector2:
	var out := Vector2.ZERO
	var idx := int(floor(t / SQUALL_WINDOW))
	for i in [idx - 1, idx]:  # a tail can spill into the next window
		if _rand01(i, 0xA) > SQUALL_CHANCE:
			continue
		var start := (float(i) + _rand01(i, 0xB) * 0.55) * SQUALL_WINDOW
		var dur := 2.0 + _rand01(i, 0xC) * 4.0
		var x := (t - start) / dur
		if x < 0.0 or x > 1.0:
			continue
		var env := pow(x / 0.2, 2.0) if x < 0.2 \
				else pow(1.0 - (x - 0.2) / 0.8, 1.5)
		var strength := 0.4 + 0.6 * _rand01(i, 0xD)
		out.x += env * strength
		out.y += env * strength * SQUALL_VEER * (2.0 * _rand01(i, 0xE) - 1.0)
	return out


## Deterministic integer hash -> [0,1): splitmix-style mixing on wrapping
## 64-bit ints. Deliberately NOT GDScript's hash() (whose value is an
## engine implementation detail) — this must replay identically forever.
func _rand01(idx: int, salt: int) -> float:
	var x := _seed ^ (idx * 2654435761) ^ (salt * 973467) ^ 0x5DEECE66D
	x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
	x = ((x ^ (x >> 29)) * 3935559000370003845) & 0x7FFFFFFFFFFFFFFF
	x = x ^ (x >> 32)
	return float((x >> 16) & 0xFFFFFF) / 16777216.0
