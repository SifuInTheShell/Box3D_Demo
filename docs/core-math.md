# Demolition physics — core math

The mathematical models behind the demolition systems: blast scaling, ground
vibration, structural load flow, toppling, settling and determinism.
Implementation: `game/systems/demolition/demo_math.gd`; every formula here is
asserted numerically by `demo_math_test.gd` against an independent reference
implementation. Engine constraints cited below were verified against the
vendored extension source (`extern/box3d-godot/godot/src/`).

Conventions: SI units (m, kg, s, N), `g = 9.81 m/s²`, world up = +Y, ground
plane = XZ. All tunables are named `K_*` and live in one place in
`demo_math.gd` (§8).

---

## 1. Charge model

### 1.1 Engine primitive

`Box3DWorld.explode(center, radius, impulse_per_area, falloff, collision_mask)`
applies an outward impulse to exposed shape area within `radius`; `falloff`
widens the region over which the impulse decays (box3d's `b3ExplosionDef`).
That is the only blast primitive needed — one call per detonating charge.

### 1.2 Charge mass → engine parameters

Real blast effects scale with the **cube root of charge mass**
(Hopkinson–Cranz scaling). A charge is defined by its TNT-equivalent mass `W`
(kg), and the engine parameters derive from it:

```
radius:           R(W)  = K_R · W^(1/3)        (default K_R = 2.0 m·kg^-1/3)
impulse per area: J(W)  = K_J · W^(1/3)        (default K_J = 60 N·s·m^-2·kg^-1/3)
falloff:          F(W)  = R(W)                  (decay over one extra radius)
```

Validated: `R(8W) = 2·R(W)` exactly. The constants are tunable; the *scaling
law* is the load-bearing part — it makes "double the charge" sub-linear,
exactly as real blasting is.

Charge *types* are presets over this: borehole (small R, high J — column
cutting), cutter (directional, a small-R explode offset toward the member),
kicker (large R, low J — pushes mass rather than shattering it).

## 2. Ground vibration

### 2.1 Peak particle velocity

Ground vibration at a monitor point follows the square-root scaled-distance
attenuation law (USBM RI 8507 form):

```
PPV(D, W) = K_ppv · (D / √W)^(-b)      [mm/s]
K_ppv = 1140,  b = 1.6  (site constants, tunable)
```

Validated magnitude: `PPV(50 m, 10 kg) = 13.8 mm/s` — inside the real
regulatory band (typical structure limits run 5–50 mm/s), so the model can be
driven with real-world-plausible numbers.

### 2.2 The 8 ms rule

Real blasting practice: charges detonating **within 8 ms count as one charge**
for vibration purposes. Adopted verbatim:

```
group charges by detonation time (greedy, new group when gap > 8 ms)
W_eff(group) = Σ W_i in group
PPV_sensor   = max over groups of PPV(D_min(group, sensor), W_eff(group))
```

`D_min` (nearest charge of the group to the sensor) keeps the estimate
conservative. Validated: splitting a 20 kg shot into three >8 ms-separated
groups cuts peak PPV from 54.2 to 26.1 mm/s at 30 m — sequencing measurably
attenuates vibration, as it does in practice.

This is a **predictive model evaluated before detonation**, not a readout from
the physics sim. Deterministic by construction.

## 3. Structure model: the weld graph

### 3.1 Representation

A structure is a graph: **nodes** = `Box3DBody` pieces (columns, beams, slabs,
wall panels), **edges** = `Box3DFixedJoint` welds between touching pieces.
Each weld stores contact area `A` (m²) and material strength `σ` (Pa), giving
capacity

```
F_cap = σ · A     [N]
```

Concrete-ish default: `σ = 2 MPa` (weak mortar — deliberately low so
structures are demolishable); a 0.3 m × 0.3 m column joint then holds
`180 kN` ≈ 18 t.

### 3.2 Static load estimate

The engine does not expose per-joint reaction forces to GDScript (verified:
`b3Joint_GetConstraintForce` exists in the C API at
`include/box3d/box3d.h:1080` but is not bound in `box3d_joint.cpp`). Load
flow is therefore estimated with our own quasi-static pass, which is
deterministic and cheap enough to run on demand:

```
Build support graph: weld (a,b) is a "down-edge" from a to b if b supports a
(contact normal within 45° of vertical, b below a; ground is a sink).

Process bodies top-down (a body resolves when everything resting on it resolved):
  carried(b)      = m(b) + Σ transferred loads from bodies resting on b
  each down-edge  gets carried(b) / (number of down-edges of b)

utilization(weld) = carried_through(weld) · g / F_cap(weld)
```

Load distribution over a body's supporting welds is **area-weighted**
(`support_loads_weighted`): each down-edge receives `load · A_edge / ΣA`,
which equalizes *stress* rather than load — validated: a 1000 kg roof on a
0.09 m² and a 0.03 m² column splits 750/250 kg with identical stress on both
(81.75 kPa). Equal splitting (`support_loads`) remains the fallback when areas
are unknown and is exact for symmetric frames — validated on a portal frame
(600/600 kg, conservation holds). `u > 1` means the connection fails on its
own.

Provenance: the area-weighted distribution and the §3.4 moment check follow
the load-flow framework of Eric Arnold's GDC 2011 Red Faction talk as
reconstructed second-hand (the talk is paywalled). Adopted because it matches
the shape of the systems read first-hand (NVIDIA Blast `ExtStress`, Space
Engineers' integrity sims), and every piece was re-validated numerically
before adoption.

### 3.3 Runtime weld breaking (our layer, not the engine's)

With no reaction force exposed, breakage runs in GDScript on top of **soft
welds**: set weld `linear_hertz = f_w` (e.g. 30 Hz) instead of perfectly
rigid. A soft constraint under load `F` deflects approximately

```
k ≈ m_eff · (2π f_w)²        (constraint stiffness; m_eff = reduced mass of the pair)
x = F / k                     (quasi-static deflection)
```

so a force cap maps to a **displacement threshold**:

```
d_break = F_cap / k
break weld when |relative joint-frame displacement| > d_break
             or |relative velocity across the joint| > v_break  (impact shear)
```

Each physics tick (fixed timestep, §6) a weld monitor walks live welds,
compares the two bodies' joint-frame transforms, and `queue_free()`s the joint
node past threshold (joint destruction on tree-exit is the supported path in
the vendored binding). Break events are tick-stamped.

Upgrade path: binding `b3Joint_GetConstraintForce` would replace the
displacement proxy with exact forces. Until then the proxy is fully
deterministic and tunable.

### 3.4 Bending / cantilever moment

Masonry fails in bending long before compression (`σ_bend ≈ 0.2 MPa` vs
`σ ≈ 2 MPa`). For a connection with rectangular section `b×d`:

```
Z      = b·d²/6                          (section modulus)
M      = μ·g·L²/2 + m_tip·g·L            (cantilever root moment: self-weight + tip load)
fails when M > σ_bend · Z
max self-supporting cantilever: L_max = √(2·σ_bend·Z / (μ·g))
```

This **derives the integrity layer's span limit from material constants**: for
0.4 m masonry bricks (μ = 288 kg/m), `L_max = 1.23 m ≈ 3.1 bricks` — exactly
the `span_max = 3` used by Rule A in `structural_integrity.gd` (0.5 MPa would
give ~5 bricks, so per-material spans are principled rather than tuned). The
moment check also catches what the span rule cannot: a *bare* 3-brick arm
holds (M = 2,034 < 2,133 N·m capacity), but the same arm under a 500 kg tip
load fails (7,920 N·m).

## 4. Toppling & directional felling

Predictions computed from geometry, with the sim remaining ground truth:

- **Tipping condition:** a body (or welded cluster) topples when its center of
  mass moves horizontally outside its support polygon (convex hull of ground
  contacts in XZ).
- **Fall arc:** a structure of height `H` felled about a base hinge sweeps a
  strip of length `≈ H` beyond the hinge line; the drawn strip is
  `H · (1 + K_margin)`, default margin 15 %.
- **Tip-over time** from a small initial lean `θ₀` (inverted pendulum,
  uniform member about its base, `θ'' = (3g/2H)·sin θ`): numerically
  integrated (RK2). Validated: a 30 m tower topples in 7.5 s from a 1° lean,
  5.2 s from 5°.
- **Impact energy sanity:** tip speed of a felled member is `√(3gH)` — faster
  than free fall (`√(2gH)`), the classic falling-chimney result; used to scale
  debris-throw estimates and camera shake.
- **Directional steering by delay:** firing near-side supports at `t=0` and
  far-side at `t=Δt` gives the cluster angular momentum toward the near side
  before full release; Δt of 100–500 ms (well above the 8 ms vibration
  window) steers the fall. Predicted direction is the vector from the
  last-standing support centroid to the first-removed support centroid.

## 5. Settling

### 5.1 Settle detection

A body is *settled* when `|v| < ε_v` for `T_settle` consecutive seconds
(defaults `ε_v = 0.05 m/s`, `T_settle = 2 s`); any spike restarts the hold.
`settle_detector.gd` implements this over a caller-supplied max debris speed, so
it stays engine-free and headless-testable. A timeout bounds the wait when
something never fully comes to rest.

## 6. Determinism & the state hash

- Fixed tick: `Box3DWorld.auto_step = false`; the sim loop calls `step(1/60)`
  itself; `substep_count` fixed; `worker_count = 1` where determinism outranks
  throughput (debris cost is handled by body caps, §7).
- Actions are data (charges with delays, cuts, cables). A run = spawn from the
  serialized scene + apply the action list + step N ticks, which makes replay
  and CI regression the same artifact.
- State hash: per body, quantize COM position and rotation quaternion to
  `1e-4` and fold into FNV-1a 64-bit in stable body-id order. Validated:
  stable under sub-quantum jitter, sensitive to real divergence.
  Same-machine/same-build determinism is what is tested; the engine is
  additionally bit-exact across platforms (see `box3d-techniques.md` §5).

## 7. Performance budget (design constraint, not polish)

- Cap live dynamic bodies per scene; measured ceilings per machine are in
  `perf-igpu-vs-rtx.md`.
- Settled debris (§5.1) converts to `STATIC` once at rest; clusters far from
  any charge can stay single bodies and only split when a charge or impact
  arrives near them.
- Rendering many pieces goes through `Box3DMultiMeshRenderer`, which exists
  for exactly this.

## 8. Constants table (initial values, all tunable)

| Constant | Value | Meaning |
|---|---|---|
| `K_R` | 2.0 | blast radius per kg^⅓ (m) |
| `K_J` | 60.0 | impulse/area per kg^⅓ (N·s/m²) |
| `K_ppv`, `b` | 1140, 1.6 | PPV site constants (mm/s) |
| window | 8 ms | vibration grouping rule |
| `σ` default | 2 MPa | weld strength (weak mortar) |
| `f_w` | 30 Hz | soft-weld frequency |
| `v_break` | 4 m/s | shear-velocity break threshold |
| `ε_v`, `T_settle` | 0.05 m/s, 2 s | settle detection |
| `K_margin` | 0.15 | fell-strip margin |
| tick | 1/60 s | fixed physics step |
