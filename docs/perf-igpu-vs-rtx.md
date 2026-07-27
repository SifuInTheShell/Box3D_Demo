# Performance — onboard Intel UHD vs discrete RTX

Measured ceilings for the two Windows GPU tiers this project targets
(integrated Intel UHD laptop graphics vs a discrete RTX card), plus the
protocol that produced them so a third machine lands in the same table. Run
everything from `game/project.godot` on Windows (the Box3D DLLs are committed
for Windows and Linux; Linux sessions can run headless but not the renderer on
a bare container).

## 1. What is CPU work vs GPU work here

Physics does **not** differ between machines of the same CPU class — Box3D is
pure CPU (SIMD solver, `worker_count 4`, adaptive 4→2 substeps). If frame rate
tanks while the `fps/bodies` stats line shows physics staying cheap, the gap is
the GPU. To measure the solver in isolation with no renderer at all, build and
run the native engine benchmark — see
[`box3d-build-and-use.md`](box3d-build-and-use.md) §2 "Building and running the
benchmark suite" (per-scene `threads,ms` CSVs with committed baselines).

**CPU-bound (identical on both machines):**
- Box3D step: awake body count, big connected rubble islands, substeps (watch
  the adaptive drop to 2 — it means the solver overran its budget)
- Fracture spawning (fracture-queue bursts during demolitions)
- FireSim (5 Hz, ~3.7 ms per tick at 400 fuels — measured headless) and
  GlassSim (event-driven, negligible between blasts)
- GDScript per-frame scene logic

**GPU-bound (where UHD and RTX diverge):**
- **Glow/bloom** (WorldEnvironment) — fullscreen post; the explosion "wow"
  lives here and iGPUs pay for it every frame
- **Screen-reading shaders** — heat-haze refraction and the fireball/shockwave
  passes copy and sample the screen; bandwidth-heavy, the classic iGPU killer
  during big detonations
- **Transparency + overdraw** — the water surface and glass: every pane and
  every live shard is alpha-blended and double-sided, so a city of glazed
  windows plus a 240-shard rain is real overdraw
- **GPU particles** — explosion sparks/smoke/dust, fire pyres (14 cap),
  per-body burn flames (26 cap), glass glints (24 cap)
- **Shadows** — one shadowed DirectionalLight over thousands of meshes (debris
  casts none, structures do)
- **Water ripple sim** — the `water_sim.glsl` compute pass (landmark scene)
- **Triplanar facade shader** on most walls (fragment cost scales with
  resolution)

## 2. Fixed conditions

1. Same build and commit, windowed 1920×1080, vsync default, same scene keys.
2. Godot 4.7 Forward+ (project default). Note driver versions.
3. Let each scene settle ~5 s before reading numbers; the stats line (top
   left) reports `fps | bodies (…) | burning | glass broken`.
4. Record idle fps → the worst dip during the blast → settled fps, plus body
   count at each point. GPU load/VRAM from Task Manager's GPU tab or GPU-Z.

## 3. Scenario script (deterministic, ~10 min per machine)

| # | Scene | Steps | What it isolates |
|---|---|---|---|
| S1 | `1` tower | idle 10 s, then `N` big blast | baseline + explosion post FX (glow, haze, particles) |
| S2 | `3` city (medium) | idle, `B` barrage, then `N` | fracture spawning (CPU) + debris draw calls |
| S3 | `3` city (large, re-press `3`) | `N` at centre, wait for settle | worst-case body count + shadowed mesh count |
| S4 | `2` landmark park | drop the crane ball into the water, 20 s | water compute sim + transparency |
| S5 | `4` fire scene | `F` on the fence end, let the row burn down | fire sim + burn-FX particle load + smoke overdraw |
| S6 | `4` fire scene | `RMB` blast at the cabin row | glass shatter wave: shard bodies + glass overdraw + glints |
| S7 | `3` city | `T`, place 3 large charges, `SPACE` | combined peak: blast FX + glass + settle |

## 4. Automated stress benchmark — CPU solver + GPU render

`res://scenes/test/bench_stress.tscn` runs itself and pushes both subsystems to
their ceiling with nobody at the keyboard. Mode is picked automatically from
whether a window exists:

```sh
# headless -> pure CPU solver ceiling
godot --headless --path game res://scenes/test/bench_stress.tscn
# windowed -> CPU solver + GPU render, fps under load
godot --path game res://scenes/test/bench_stress.tscn
```

It rains an escalating pile of cubes (2k → 96k) into a bin with sleep disabled
— every body solved every tick — and **stops early** once a stage saturates
(step > 55 ms, or fps floors), so a weak laptop finds its limit fast while a
strong one keeps climbing. Windowed, the pile draws through
`Box3DMultiMeshRenderer` (one draw call for the whole pile, transforms synced
in C++) under a shadowed sun + glow post with vsync off, so the GPU is
genuinely loaded and fps is reported alongside step time. The header logs the
detected adapter (`get_video_adapter_name/_type`). Extended DLL diagnostics
(`get_profile` / `get_counters` / `get_awake_body_count`) are used when
present, else it falls back to `TIME_PHYSICS_PROCESS`.

Fixed seed and layout, so contact counts per stage come out byte-identical on
any CPU (a determinism cross-check); only the timings move. CSV columns:
`bodies,awake,contacts,step_avg_ms,step_max_ms,fps_avg,fps_min`.

## 5. Measured — both laptops, workers 4, extended timer

Full dual-mode runs: [`bench_stress_uhd.csv`](bench_stress_uhd.csv),
[`bench_stress_gpu.csv`](bench_stress_gpu.csv). Contact counts per stage are
byte-identical across the two CPUs (2000 / 4000 / 9292 / 33055 / 50560 …) —
the solver is bit-deterministic, as designed; only the timings move. Windowed
step / fps by stage:

| bodies | UHD i5-1335U      | Ultra 9 275HX + RTX 5080 |
|-------:|------------------:|-------------------------:|
| 4000   | 8.4 ms / 140 fps  | 1.3 ms / 503 fps         |
| 8000   | 14.7 ms / 65 fps  | 2.8 ms / 394 fps         |
| 16000  | 24.9 ms / 15 fps  | 6.9 ms / 256 fps         |
| 24000  | 41.2 ms / 5 (stop)| 10.2 ms / 154 fps        |
| 32000  | —                 | 14.4 ms / 59 fps         |
| 48000  | —                 | 22.6 ms / 10 fps         |
| 64000  | —                 | 27.7 ms / 4 (stop)       |

| ceiling            | UHD i5-1335U | RTX 5080 / Ultra 9 |
|--------------------|-------------:|-------------------:|
| CPU solver @60 Hz  | 8000         | 32000              |
| CPU solver @30 Hz  | 16000        | 64000              |
| GPU render @60 fps | 8000         | 24000              |
| GPU render @30 fps | 8000         | 32000              |

The Ultra 9 is ~4× the i5 on the solver (32k vs 8k @60 Hz), and the RTX draws
~3× the pile at 60 fps (24k vs 8k) — at 16k it holds 256 fps where the UHD is
at 15. Both machines hit a real wall: the i5/UHD saturates at 24k, the Ultra
9/RTX at 64k. If a future machine sails past 96k, raise the top of `STAGES` in
`bench_stress.gd`.

## 6. Quality levers if the iGPU struggles

The iGPU dips hardest on the glow + screen-reading shader scenarios (S1/S7),
glass overdraw (S6) and particle fill rate (S5). These are the levers,
cheapest first — all constants, no redesign:

| Lever | Where | Effect on iGPU |
|---|---|---|
| Render scale < 1.0 (e.g. 0.77) | Viewport 3D scaling | biggest single win; all fragment cost scales |
| Glow off / intensity down | `destruction_gym._build_environment` | removes the fullscreen post |
| Skip heat-haze + shockwave passes | `explosion_fx.gd` | kills the screen-copy spikes |
| Particle caps | `fire_fx.MAX_ACTIVE` 14, `burn_fx.MAX_ACTIVE` 26, `glass_fx.MAX_ACTIVE` 24, `fracture_fx.MAX_ACTIVE` 32 | halve on iGPU |
| Glass shard budget | `glass_pane.MAX_SHARDS` 240, `glass_system.SHARD_LIFE_MS` 8000 | fewer live transparent bodies |
| Shadow distance / off | sun light in `_build_environment` | large scene-wide win |
| Water sim resolution | `water_sim.gd` `TEXELS_PER_M` | landmark scene only |

An automatic tier already covers the two cheapest of these:
`_build_environment` reads `RenderingServer.get_video_adapter_type()` and gives
a discrete card 4× MSAA plus 4-split shadows at 150 m, while an integrated (or
unknown/headless) adapter gets no MSAA and a single-split shadow at 70 m.
Rendering-only, so physics and the determinism hash are untouched — the
render-side mirror of the adaptive-substep pattern on the physics side.
