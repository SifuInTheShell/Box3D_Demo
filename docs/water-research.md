# Realistic, Interactive Water — Research & Design

**Scope:** the river/channel strip in the demo scenes (landmark park: a
128 × 17 m water strip under the suspension bridge, `Scenery.water()` +
`WaterFX.zone()`), Godot 4.7 Forward+, Windows target, camera 10–60 m away at
30–60° pitch. Debris rains into the water after demolitions — potentially
dozens of bodies in a second.

Direct fetches of most cited sites are gateway-blocked from this project's
sessions; findings rest on search excerpts, reachable GitHub repos and
established knowledge of the cited sources. URLs are listed at the end so
anything load-bearing can be re-verified.

### What the Box3D binding gives us (verified in `extern/box3d-godot/godot/src`)

- `Box3DBody`: `apply_central_force`, `apply_central_impulse`, `apply_torque`,
  `get_mass`, `get/set_linear_damping`, `get/set_angular_damping`,
  `get_linear_velocity`, `get_angular_velocity`, `get_box_size`,
  `get_shape_type`, `gravity_scale`, sensor flag.
- `Box3DWorld`: `overlap_sphere`, `shape_cast_sphere`, `raycast`, `explode`.
- **No force-at-point call.** Point-sampled buoyancy must therefore sum
  per-point forces and torques itself and apply the totals:
  `apply_central_force(ΣF)` + `apply_torque(Σ rᵢ × Fᵢ)` — mathematically
  identical to per-point application for a rigid body, so nothing is lost.
- `velocity_at_point` also doesn't exist; compute it as `v + ω × r` from
  `get_linear_velocity` / `get_angular_velocity`.

---

## 1. Surface rendering

### 1.1 Godot 4 fundamentals (the API idioms)

Godot 4 removed the implicit Godot-3 built-ins; declare screen/depth textures
as uniforms — the *hint* does the binding:

```glsl
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D DEPTH_TEXTURE  : hint_depth_texture,  filter_linear_mipmap, repeat_disable;
```

Declaring `hint_screen_texture` triggers one screen copy before the
transparent pass (shared by all materials that request it; fractions of a ms
at 1080p). Both textures contain **opaque geometry only** — exactly what the
depth tricks below want.

Linear water-column thickness under each pixel (works with 4.3+ reversed-Z
because `INV_PROJECTION_MATRIX` accounts for it):

```glsl
float depth_raw = texture(DEPTH_TEXTURE, SCREEN_UV).x;
vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
view.xyz /= view.w;
float water_depth = -view.z - (-VERTEX.z);   // scene depth minus surface depth
```

That one value drives the three biggest realism wins:

1. **Beer–Lambert absorption** — `exp(-beers_law * water_depth)` mixes
   shallow→deep tint and modulates how much refracted background survives. Do
   the tint by multiplying the screen sample, not via alpha, and keep `ALPHA`
   near 1.0 (fewer sorting artifacts, correct exponential falloff).
2. **Refraction** — offset `SCREEN_UV` by the wave normal's xy (attenuated by
   distance). Guard: re-sample depth at the offset UV and fall back to the
   straight UV if the refracted sample is *closer* than the water surface —
   the standard fix for above-water objects bleeding into the refraction.
3. **Shore/edge foam from the depth delta** — `1 - clamp(water_depth /
   foam_distance, 0, 1)` masked by animated noise, `edge_fade` over ~0.2 m for
   a soft waterline. Free win: every opaque debris chunk sitting in the river
   automatically gets a foam ring, with no gameplay code involved. Foam should
   force `ROUGHNESS` toward 0.9 (foam kills glints).

PBR settings for believable sun glints at these camera angles: `METALLIC 0.0`
(water is not metallic), `SPECULAR 0.5`, `ROUGHNESS 0.02–0.1` modulated by
Schlick fresnel `pow(1 - dot(N, V), 5)` and raised slightly with distance
(which kills far-end specular sparkle). The sun glint then comes free from the
DirectionalLight3D once the normal map animates.

### 1.2 Waves for a calm river: keep it simple

Ranked by cost — tiers 1–2 carry ~90 % of the look at 10–60 m, and the rest is
overkill for a 17 m-wide channel:

1. **Dual scrolling normal maps** (two scales/speeds, both drifting along the
   flow axis with slight divergence) → `NORMAL_MAP`. Zero vertex cost.
2. **Small sum-of-sines vertex displacement** (3–4 waves, amplitude
   0.03–0.10 m, wavelengths 1–8 m, directions within ±20° of flow). Moves the
   silhouette at the banks and — critically — is **CPU-evaluable in GDScript,
   giving `water_height(x, z)` for buoyancy and splash triggering**.
3. Gerstner waves — choppy open-sea crests; wrong register for a channel. Skip.
4. FFT ocean (godot4-oceanfft, GodotOceanWaves) — compute-shader wave spectra
   for open oceans. Clearly overkill. Skip.
5. Flow maps (Waterways' trick) — only pay off when the river bends; a
   straight strip's uniform flow direction is equivalent and free.

Mesh: one `PlaneMesh` at ~0.5 m grid (256 × 34 ≈ 8.7 k verts — trivial; no LOD
needed at this size), with `custom_aabb` padded by the wave amplitude so
displacement never causes culling pop.

### 1.3 Reflections, ranked for a flat river plane

| Option | Verdict |
|---|---|
| Sky/environment + fresnel | Free, already reads as water at these angles — the baseline. |
| WorldEnvironment SSR | **Doesn't work on transparent materials** (opaque-only). Skip. |
| In-shader SSR raymarch | Works on transparent water (reference: Marcel B's MIT "Transparent Water Shader supporting SSR", Asset Library #2152). Moderate cost; classic SSR gaps (off-screen/occluded objects vanish). The sensible middle tier. |
| Planar reflection (mirrored camera → half-res SubViewport) | Best quality on a flat plane; costs a second scene render — real money in a scene full of debris. Mitigate: half res, cull mask without particles/debris, no shadows. Only if mirrored landmarks matter. |
| ReflectionProbe | Wrong tool (cubemap parallax on a 128 m strip, dynamic scene). Skip. |

### 1.4 Reference implementations worth studying

- StayAtHomeDev "Single Plane Water Shader" series — the canonical Godot 4
  walkthrough (sines, normal maps, Beer's law, fresnel, foam).
- godotshaders.com: "Stylized Water for Godot 4.x" (cleanest Godot-4 API
  idioms), "Water Shader", "Absorption Based Stylized Water" (per-post
  licenses: CC0/MIT/GPLv3 — check the post footer before copying).
- Marcel B "Transparent Water Shader supporting SSR and Refraction" (MIT).
- Arnklit/**Waterways** and Tshmofen/**waterways-net** (MIT; river-specific:
  flow maps, steepness foam, `GetWaterHeight` API — the .NET rewrite is the
  maintained one but requires C#; useful as a *concept* reference).
- 2Retr0/GodotOceanWaves — overkill sim, but the *shading* (spray, glint
  handling) is worth reading.

---

## 2. Interactive ripples — the surface reacting to objects

### 2.1 The technique that fits: GPU heightfield wave simulation

Discretized 2D wave equation on a height texture, integrated over two history
buffers — the kernel below is verified against the **official Godot demo**
(`godot-demo-projects/compute/texture`, Asset Library #2764), whose
`water_compute.glsl` does exactly this:

```glsl
float new_h = 2.0 * current - previous
            + 0.25 * (up + down + left + right - 4.0 * current);
new_h -= damp * new_h * 0.001;          // energy loss so ripples die out
```

`0.25` is the largest stable Laplacian coefficient for the 4-neighbor stencil
(CFL condition); the canonical games reference is Müller's GDC 2008 *Fast
Water Simulation for Games Using Height Fields*. After the sim step the water
material samples the height texture in `vertex()` and reconstructs normals from
finite differences: `normalize(vec3(hL - hR, 2·texel_world, hD - hU))`.

Why this beats the alternatives here: overlapping impacts **interfere** (real
superposition), moving bodies get wakes for free (a splat trail outruns its own
ripples into a V), waves reflect plausibly off the banks, and cost is
independent of impact count.

Two implementation routes in Godot 4:

- **Compute shader via RenderingDevice (chosen).** The official demo is ~80 %
  of the work: three RD textures cycled as a ring (no copies), dispatch on the
  *main* RenderingDevice (runs before render passes, no sync headaches), and —
  the key modern piece — **`Texture2DRD`** (4.2+) makes the material's
  `sampler2D` literally the RD texture, zero readback. The demo injects one
  disturbance per frame via push constant; that has to be extended (§2.2).
- **SubViewport ping-pong (no RD code).** Reference: Namey5's
  `godot-interactive-water` (Godot 4.3). A ViewportTexture can't reference its
  own viewport, so double-buffering needs two interlinked SubViewports
  sampling each other; height packed as R = current, G = previous. Same math,
  same visuals, but frame-rate-coupled timestep and fiddly nested-viewport
  setup.
- CPU sim (Image + `ImageTexture.update()`): only viable to ~128² at 60 Hz.
  Poor trade on desktop. Skip.

### 2.2 Injecting disturbances — batching dozens of impacts per frame

- World→sim mapping for the axis-aligned strip: `uv = (pos.xz - origin) /
  size`; the water material must use the identical mapping when sampling.
- Splat = radial falloff (`strength · (1 - smoothstep(0, r, d))` or a
  Gaussian), radius ≈ body bounding radius (**minimum 2–3 texels** or the
  splat vanishes), sign negative (the body pushes the surface down), strength
  scaled by downward momentum — `k · |v_y| · m^⅓` — and **hard-clamped**: the
  wave equation is linear, so one huge splat makes a domain-wide tsunami.
- **Compute route:** replace the demo's single push-constant point with a
  `StorageBuffer` of `vec4 splats[N]` (xy texel pos, z radius, w strength) plus
  a count, looped inside the kernel — fine for N ≤ ~64 per frame. Coalesce to
  one splat per body per frame.
- **SubViewport route:** batching is free — a pool of additive-blend Sprite2D
  splats drawn into the sim viewport for one frame; 50 impacts = 50 sprites in
  one 2D batch.
- Moving/bobbing bodies: inject a small continuous splat each sim step,
  strength ∝ horizontal speed, slightly trailing and elongated along velocity
  → wakes emerge from the sim itself.

### 2.3 Domain strategy for the 128 × 17 m strip

Fixed texture over the whole strip (debris falls everywhere at once; a
camera-following window would lose off-window ripples). Resolution 4–8
texels/m → **1024 × 144** at 8 px/m, RG float ≈ 1.2 MB, and a full-strip pass
over ~140 k texels is far below a millisecond on any desktop GPU. Ripple speed
is set by texel size and the Laplacian coefficient, not physics — for slower,
heavier-looking waves run the sim at a fixed 30 Hz and sample every render
frame (which also decouples it from frame rate).

Edges: clamped borders act as walls, so waves **reflect** — plausible for the
two long banks, wrong for the short open ends. Add an absorbing band there
(multiply state by a falloff mask over the last ~16 texels each step). Raw
clamp on visible edges leaves standing waves after big explosions.

### 2.4 The cheaper fallbacks (and when they'd win)

- **Analytic impact ripples in the vertex shader** — a uniform array of
  `vec4(world_xz, start_time, strength)`, each vertex summing
  `sin(k·d − ω·t) · exp(−a_d·d) · exp(−a_t·t)` behind an expanding front.
  16–32 slots comfortable, 64 fine on desktop. No interference, no wakes, and
  at 50+ impacts/sec the slot-eviction churn thrashes — oldest ripples visibly
  pop. Right choice only when impacts are sparse or the RD plumbing is
  unwanted; kept as a low-spec fallback toggle.
- **Ripple decals/quads** — expanding-ring quads floating just above the
  surface. No displacement; `Decal` nodes don't project well onto transparent
  water. Fine as a *foam overlay* on top of a real sim, not as the sim.
- **Foam accumulation texture** — a second low-res texture where splats only
  fade (no propagation), sampled additively in the water albedo. Cheap, and
  per the shipped-game evidence it sells wakes and impact sites *more than the
  height ripple itself*.

### 2.5 How shipped games do it (pattern check)

- **Atlas** (GDC 2019, WildCard/NVIDIA): dynamic displacement layer for ship
  wakes **and explosions** blended over a spectral ocean — the direct
  blueprint for "explosions disturb water".
- **Sea of Thieves** (GDC 2018): FFT ocean, but interaction (wakes, oar hits)
  is **layered VFX** — foam textures and particles, not a global sim.
- **Uncharted 3**: Wave Particles (Yuksel, SIGGRAPH 2007) — analytic particles
  splatted into a displacement texture; the midpoint between §2.1 and §2.4.
- **Zelda BotW**: expanding ring decals + particles on stylized water — proof
  decal rings ship at high polish when the art style allows.

The consistent industry pattern: **base water + a localized dynamic layer for
interaction + heavy particle/foam dressing on top — nobody ships the raw
height ripple alone.** Foam and spray carry most of the perceived impact.

---

## 3. Splashes — the entry event

A convincing water entry is a composite of staggered short-lived elements
(mesh for the coherent sheet, particles for everything airborne, flat quads for
everything on the surface):

| Element | Life | Implementation |
|---|---|---|
| Crown/column splash | 0.3–0.8 s | Pooled crown mesh (radially scaled, alpha-eroded) *or* 8–16 stretched vertical billboards; skip below ~3 m/s entry |
| Ballistic spray droplets | 0.5–1.2 s | GPUParticles3D one-shot burst; count ≈ `clamp(20·v·r, 16, 300)`; speed 0.3–0.7·v in a 20–45° cone; gravity ≈ −12 (slightly super-gravity reads punchier) |
| Mist puff | 0.6–1.5 s | 6–15 big soft billboards (white, alpha 0.1–0.25), high damping (2–4) — the "hits an air wall" water-mist look |
| Expanding foam ring | 1–3 s | One flat quad on the surface with an expanding-ring shader — cheapest, most readable element |
| Lingering foam patch | 3–8 s | Flat noisy quad, slow rotation, alpha fade; marks the spot, persists while a body bobs |

Scaling rules of thumb: crown height ≈ `clamp(0.4·v, 0.3, 3.0)` m, radius ≈
1.5·r; foam-ring final radius ≈ 2–4·r easing out over ~2 s. Below ~2 m/s: foam
ring plus a few droplets only ("plop"). Above ~9 m/s: full stack plus a second
delayed foam ring for the collapse rebound.

### Godot 4 particle specifics that will bite if ignored

- **One-shots must be replayed with `restart()`**, not by toggling `emitting`
  — a finished one-shot does not rewind its internal phase (godot#83909,
  #79689, #83599).
- **Pool, don't instantiate**: each GPUParticles3D allocates GPU buffers and
  can hitch on first draw. Keep ~8 droplet emitters + ~8 mist emitters + ~8
  crown meshes, round-robin: reposition, scale parameters, `restart()`. One
  emitter cannot overlap two bursts — `restart()` kills the in-flight one,
  hence the pool. Never swap `process_material` at runtime.
- **`emit_particle()`** on a single persistent emitter is the alternative
  backbone: one river-wide system injecting individual particles at arbitrary
  positions (`EMIT_FLAG_POSITION | EMIT_FLAG_VELOCITY`) — best for ambient
  foam flecks around bobbing debris; note it bypasses the material's initial
  randomization, so randomize per call.
- **Sub-emitters**: `sub_emitter_mode = AT_COLLISION` on the droplet material
  plus a thin `GPUParticlesCollisionBox3D` at the water plane = one
  micro-ringlet where each droplet lands. Keep sub-amounts tiny.
- Droplets: flare texture, scale curve 1→0.3, slight damping so the apex
  hangs. Mist: smoke texture, alpha-blend (not additive), scale 0.5→2.0. Tint
  droplets toward the water albedo at end of life so they "dissolve".

### Audio (brief)

Layered (impact thump + slap + droplet-patter/gurgle tail), bucketed into 3
tiers by impact energy `E = ½mv²` with 3–4 round-robin variations per tier,
volume/pitch mapped from log E. Cap concurrent splash voices (~6, steal
oldest) and coalesce same-frame mass-debris events into one "large" event —
that last rule is essential for the barrage case.

---

## 4. Buoyancy & drag — debris that floats, bobs, tips and sinks

The standard game-grade model (Unreal's pontoon buoyancy, classic Unity float
scripts, Kerner's boat-water article as the high-fidelity reference):
discretize the body into sample points, and per physics tick per submerged
point apply Archimedes + drag. Per-point forces are what make bobbing, tipping
and righting **emerge** — asymmetric submersion produces torque.

```
ρ_w = 1000, g = 9.81
per body: points = 8 AABB corners (local), V_i = V_total / 8
effective density per debris type chosen for readability:
  wood 400–600 (floats), hollow slab 800–950 (barely floats), rubble 2400 (sinks)

each tick:
  F_total = 0; T_total = 0
  for p in points:
    x = body_transform * p
    d = water_height(x.xz) - x.y            # sine sum, CPU side
    if d <= 0: continue
    k = clamp(d / point_radius, 0, 1)       # smooth submerged fraction
    F = UP * ρ_w * g * V_i * k              # Archimedes
    vr = v + ω.cross(x - com) - river_flow  # velocity at point, minus current
    cq = c_quad * (2.0 if vr.y < 0 else 1.0)   # downward drag asymmetry
    F += -(c_lin * vr + cq * vr.length() * vr) * k * A_i
    F_total += F;  T_total += (x - com).cross(F)
  F_total = F_total.limit_length(F_max)     # cap: no water ejection (F_max ≈ 3·m·g)
  body.apply_central_force(F_total)
  body.apply_torque(T_total - c_ang * (1 + 2*depth_c) * ω * submerged_frac)
```

Starting constants: `c_lin ≈ 1.0`, `c_quad ≈ 0.8`, `c_ang ≈ 1.5`,
`point_radius ≈ 0.25 × AABB height`. Drag is mandatory — pure Archimedes is an
undamped spring and oscillates forever.

**Entry slam** (once, on first downward surface crossing): impulse
`J = c_slam · m · v_down` upward with `c_slam ≈ 0.2–0.5`. Kills the
knife-through-water look for heavy debris, and the event doubles as the
splash/audio/ripple trigger with energy already in hand.

**Sinking endgame** (readability cheats): 2–4× drag once fully submerged and
clamp sink speed to ~0.5–1.5 m/s ("heavy but graceful"); ramp angular damping
with depth so debris does one lazy half-tumble then stabilizes; at kill depth
(or a timeout) freeze, dissolve/fade ~1 s, emit 3–6 rising bubble particles to
mask the removal, free. The downward-drag asymmetry (`c_down ≈ 2·c_up`) makes
bodies hesitate at the surface for a beat before committing — very readable.

Box3D integration: all of this maps onto `apply_central_force` /
`apply_torque` / `apply_central_impulse` (see the binding facts above).
Candidate discovery is an `overlap_sphere` sweep, but the force loop must run
**every physics tick** for bodies registered as in-water (a periodic sweep only
handles enter/exit bookkeeping). Per-body damping via
`set_linear_damping`/`set_angular_damping` while submerged is simpler but
uniform; the explicit force model is what produces floating wood vs sinking
rubble, so damping-boosting is reserved for cheap far-away debris.

---

## 5. What ships

The three threads converge on the same industry pattern: **a good base shader
+ a localized dynamic heightfield for interaction + heavy particle/foam
dressing + honest force-based physics.** All four layers are implemented:

- **Shader** — `lib/fx/water.gdshader`: depth-aware, Beer–Lambert
  shallow→deep tint, refraction with the depth guard, Schlick fresnel,
  `METALLIC 0` / `ROUGHNESS 0.02–0.1`, depth-delta shore foam with animated
  noise and soft `edge_fade`, sine displacement plus dual scrolling normal
  maps. `Scenery.water()` generates the detail-normal and foam noise textures
  procedurally, uses a finer grid, and pads the cull AABB.
- **Buoyancy** — `lib/water/water_fx.gd`: the §4 force loop with 8-corner
  sampling, per-type effective density, quadratic drag with downward
  asymmetry, entry-slam impulse, depth-ramped damping, clamped sink speed and
  a dissolve at kill depth. `RHO_WATER = 1.0` in the project's g/cm³-like
  density scale, so wood/props (0.5/0.35) float, panels (1.2) sink slowly and
  the wrecking ball (10) plummets. `water_height()` mirrors the shader's wave
  table — **keep the two in lockstep when tuning**.
- **Splashes** — `lib/water/water_splash.gd` + `lib/fx/foam_ring.gdshader`:
  pooled composite splashes per §3, tiered by entry speed, with same-frame
  impacts coalesced per 4 m cell.
- **Ripples** — `lib/water/water_sim.gd` + `lib/fx/water_sim.glsl`: the §2.1
  compute heightfield at 1024 × ~140, absorbing bands on the short ends, fixed
  30 Hz step, sampled by the water shader through `Texture2DRD`; entry and
  trail splats come from `water_fx.gd`. The shader's `ripple_*` uniforms
  default to inert (`hint_default_black`) so the shader works without the sim.

Deliberately deferred: in-shader SSR raymarch and half-res planar reflections
(both are look-and-profile calls that need a running renderer), and a foam
accumulation texture. The river current (`WaterFX.FLOW`) shipped with the
buoyancy work.

Tuning knobs, all in one place per layer: `WaterFX` constants (drag, slam,
sink cap), `water.gdshader` uniforms (`beers_law`, `foam_distance`,
`ripple_height`), `WaterSim.DAMP` (ripple decay) and `TEXELS_PER_M`. If the
water is ever the frame-time problem it will be the transparent fragment
shader, not the 30 Hz compute dispatch — lower the plane subdivision or
`TEXELS_PER_M` first.

---

## Sources

**Rendering:** godotshaders.com (Water Shader; Stylized Water for Godot 4.x;
Absorption Based Stylized Water; Transparent Water Shader supporting SSR —
https://godotshaders.com/shader/transparent-water-shader-supporting-ssr/;
license policy https://godotshaders.com/license/) · StayAtHomeDev
https://stayathomedev.com/tutorials/single-plane-water-shader/ ·
https://github.com/Arnklit/Waterways ·
https://github.com/Tshmofen/waterways-net ·
https://github.com/tessarakkt/godot4-oceanfft ·
https://github.com/2Retr0/GodotOceanWaves ·
https://github.com/SIsilicon/Godot-Planar-Reflection-Plugin ·
https://godotengine.org/asset-library/asset/2152 (SSR water) ·
https://godotengine.org/asset-library/asset/4102 (PlanarReflector-CPP) ·
https://godotengine.org/asset-library/asset/2070 (Boujie Water)

**Interactive ripples:** Godot official compute demo
https://github.com/godotengine/godot-demo-projects/tree/master/compute/texture
(Asset Library #2764; `water_plane/water_compute.glsl`) ·
https://github.com/Namey5/godot-interactive-water · Müller, GDC 2008 "Fast
Water Simulation for Games Using Height Fields" (summary:
https://github.com/layshua/skunami.js/blob/master/README.md) · Paper Kitty
Games "Godot 4 Dynamic Ripples"
https://paper-kitty-games.itch.io/godot-4-dynamic-ripples · Bramwell ripple
tutorial
https://www.gamesinprogress.com/indie-game-developers/bramwell/tutorial-adding-ripples-to-3d-water-in-godot-4
· GDC 2019 Atlas water talk https://www.youtube.com/watch?v=Dqld965-Vv0 ·
GDC 2018 Sea of Thieves https://www.youtube.com/watch?v=BzppoQTG3m0 · Wave
Particles (Yuksel, SIGGRAPH 2007) · godotshaders "Water Ripples"
https://godotshaders.com/shader/water-ripples/

**Splash & buoyancy:** Kerner, "Water interaction model for boats in video
games" https://www.gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games
· "Buoyancy for Dummies" https://www.vertexfragment.com/ramblings/buoyancy-for-dummies/
· Unreal Water Buoyancy Component
https://dev.epicgames.com/documentation/en-us/unreal-engine/water-buoyancy-component-in-unreal-engine
· https://github.com/dbrizov/Unity-WaterBuoyancy ·
https://github.com/Jay2645/BuoyancySystem · Pirate Sea Jam buoyancy devlog
https://claudijo.itch.io/pirate-sea-jam/devlog/580422/part-2-buoyancy-and-water-dynamics
· Godot sub-emitters
https://docs.godotengine.org/en/stable/tutorials/3d/particles/subemitters.html
· godot#83909 / #79689 / #83599 (one-shot restart) · Trifox splash breakdown
https://www.trifox-game.com/splash/ · SFX Engine splash sound design
https://sfxengine.com/blog/water-splash-sound-effect
