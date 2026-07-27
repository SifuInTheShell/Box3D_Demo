# Box3D Physics Demo — Godot 4.7

A [Godot 4.7](https://godotengine.org) demo built around
**[Box3D](https://github.com/erincatto/box3d)** — Erin Catto's 3D rigid-body
physics engine (the 3D successor to Box2D) — wired into Godot through the
**[box3d-godot](https://github.com/Stink-O/box3d-godot)** GDExtension.

**The point of the repo is Box3D.** The full engine and the GDExtension binding
are vendored as source, so you can **build the physics DLLs yourself** on
Windows and Linux and see exactly how a native C physics engine gets embedded
into Godot. We also **extended the binding to expose nearly the entire Box3D C
API** (see below). A fresh clone already runs on Windows — the prebuilt DLLs are
committed — so you can press play first and build later.

On top of the engine sits a set of physics systems — fracturing structures,
explosions, propagating fire, breaking glass, and interactive water — that show
what the engine can drive at scale (tens of thousands of bodies, deterministic
across machines).

## Features

### Box3D engine — with a near-complete binding

We extended this fork's GDExtension to cover **nearly the whole Box3D C API** —
from roughly a third of Box3D's ~420 core functions to almost all of them, added
purely additively so existing scripts keep working. The rebuilt Windows DLLs
committed here already contain it. Newly reachable from GDScript:

- **World** — live diagnostics (`get_counters`, `get_profile`,
  `get_awake_body_count`, `get_bounds`), `overlap_aabb`, an all-hits
  `cast_ray_all`, deterministic **recording → replay**
  (`start_recording`/`stop_recording` → `PackedByteArray`, `validate_replay`),
  and solver knobs (speculative contacts, restitution / hit-event thresholds,
  contact recycling).
- **Bodies** — force / impulse **at a point**, angular impulse, point velocity,
  center of mass and full **mass-data get/set/reset**, sleep threshold,
  enable / wake / is-awake, closest point, **live contact data**, body-space
  transforms, and a real **`body_hit` signal** (impact point, normal, approach
  speed).
- **Live per-shape materials** — change friction / restitution / density /
  collision filter / surface material on a *running* body with no rebuild, plus
  per-shape AABB / closest-point / raycast and contact-event toggles.
- **Joints** (all eight subclasses) — joint type, local frames, constraint
  tuning (hertz / damping), and readouts for **constraint force / torque**,
  linear / angular separation, and break thresholds.

The exact additions vs. the base fork (every extended World / Body / Joint
method, categorized): [`docs/box3d-binding-extensions.md`](docs/box3d-binding-extensions.md).
Build and API tour: [`docs/box3d-build-and-use.md`](docs/box3d-build-and-use.md).
(A few self-contained pieces are deliberately deferred: solver callbacks,
replay *playback*, and the heightfield / baked-compound / filter-joint
constructors.)

The base engine capabilities the binding surfaces: static / kinematic / dynamic
bodies; box, sphere, capsule, cylinder, cone, convex-hull and triangle-mesh
colliders (compound bodies from multiple shapes); the full joint set (hinge,
slider, distance, ball, fixed, motor, wheel, parallel); a kinematic character
controller; continuous collision; contact & sensor events; ray / shape / overlap
queries; and a multithreaded SIMD solver with island sleep that is **bit-exact
across platforms** (scalar, SSE2 and NEON paths agree).

### Destruction & fracture

- Walls and blocks are solid at rest, then **split into irregular convex-hull
  shards** when struck above a speed threshold — recursive uneven cuts, biased so
  debris is **finest at the impact point** and coarser away from it, so rubble
  reads as broken material rather than boxes dissolving into boxes.
- Pieces fracture again on further hits, down through generations to inert
  fragments; global caps (thousands of bricks / fragments) bound the totals so
  the sim stays bounded no matter how much you level.
- **Cylinders and drums** (silos, tanks, chimney sections) fracture into masonry
  shards the same way.
- **Trees** are real GLB models on compound colliders that topple and **shatter
  their own geometry** into trunk sections and canopy clumps.
- A global **fracture queue** paces the shard spawns across frames, so a
  scene-wide blast avalanches over ~a second instead of spiking one frame.

### Explosions

- `Box3DWorld.explode` delivers a radial impulse and fractures every body in
  range; charge size scales radius and force.
- Layered cinematic FX: a shader **fireball**, an expanding **ground shockwave
  ring**, **heat-haze** screen refraction, spark / smoke / dust GPU particles,
  an omni flash, decaying **camera-shake trauma**, and slow-motion on the big
  detonations.
- **Placeable charges** stick to the wall they're set on (riding or dropping
  with it) and fire in a timed sequence.

### Fire & propagation

- A **deterministic, RNG-free** fuel simulation: every flammable body carries
  temperature, moisture and char, moving through COLD → BURNING → SMOLDERING →
  BURNT-OUT.
- Heat radiates with quadratic **distance falloff**, an **upward bias**, a
  **wind** skew, and a bonus for touching bodies — so fire visibly **walks**
  along a fence, **jumps between structures only when close enough** (firebreaks
  hold), and leans downwind.
- Moisture boils off before a fuel can ignite; ignite by **torch**, blast heat,
  or a lingering **ground pyre**, and **douse** with water to pull temperature
  back down.
- Burning **weakens** structures until they collapse under their own weight,
  **carries onto wood debris** (a collapsing burning wall seeds fires below it),
  and finally consumes a body to an ember puff.
- Ticks at ~5 Hz so the spread reads at a watchable pace; per-body flame / smoke
  visuals plus persistent ground pyres feed heat back into the sim.

### Glass

- A pane breakage model driven by three causes: **blast overpressure**
  (Hopkinson-scaled distance — glass shatters at several times the structural
  blast radius, so it doubles as a collateral indicator), **fast impact**, and
  **thermal shock** from nearby fire.
- Breaks resolve into a **non-uniform shatter pattern** whose shards crowd toward
  the impact point; shards are cosmetic flat wedges, globally budgeted and
  lifetime-capped.
- A single blast pops a whole street of windows in a **travelling shatter wave**,
  and a tagged ledger records what broke and why.

### Water & effects

- **Force-based buoyancy** — eight sample points per body run Archimedes lift +
  quadratic drag every tick, so wood **floats and bobs**, dense bodies **sink**,
  and objects **waterlog and scuttle** over time.
- A **GPU interactive ripple heightfield** (a RenderingDevice compute shader)
  reacts to anything striking the surface and drives the water material.
- **Pooled splash VFX** — crown strands, droplets, mist, and an **expanding foam
  ring** — tiered by entry speed, coalesced per grid cell (no per-splash node
  spawning), and **clipped to the water surface** so ripples never bleed onto
  land.

### Structures, props & rigs

- Buildings are assembled from **mutually-supported wall panels** (piers, sills,
  glazed windows, lintel bands, floor slabs, roofs, chimneys) — every panel rests
  on something, so a building stands rigid until part of it is hit, then goes
  locally destructible.
- An **industrial district**: factory halls, brick smokestacks, steel water
  towers, silo groups, and multi-span concrete viaducts.
- A working **slewing tower crane** built on real **cable physics** — a chain of
  capsule links pinned by ball joints that sags into a catenary and **snaps when
  overstretched** — carrying a wrecking ball; destroy a mast piece and the whole
  boom drops dynamically.
- **Suspension-bridge cables** (a Golden Gate build) use the same jointed-cable
  physics with real suspenders.
- **Articulated human ragdolls** — eleven Box3D bodies (pelvis, torso, head,
  paired arm/leg segments) ball-jointed along a rigged CC0 character's
  skeleton; pedestrians stand frozen until the chaos reaches them, then the
  joints take over and the skinned mesh flops as one continuous body.
- **A living backdrop** — a low **bird swarm** wheels over the city and
  **scatters when a blast reaches it** before folding back into formation
  (procedural MultiMesh, reactive/pooled — no per-agent AI, no downloaded asset).
- **Realistic set dressing** — a Poly Haven HDRI sky with image-based lighting,
  photoscanned CC0 street props (wooden crates and fire hydrants) fetched by
  `tools/fetch_polyhaven_assets.py`, and procedural primitives (barriers, cones,
  dumpsters, pallets, tape) so a fresh clone still runs without downloads.

### Rendering & scale

- **GPU MultiMesh instancing** (`Box3DMultiMeshRenderer`) draws tens of thousands
  of bodies in a single draw call, with per-frame transforms synced in C++
  straight from the solver's tick snapshots (interpolated to render time).
- Shared, cached meshes and materials plus a triplanar facade shader keep
  thousands of debris pieces sharing a handful of GPU resources.
- **Adaptive substep / quality throttling** halves solver substeps when a frame
  overruns its budget, so a heavy collapse slows down gracefully instead of
  stalling.

### Determinism & tooling

- The simulation is **bit-exact across machines** — verified by identical contact
  counts from a 12-core i5 and a 24-core Ultra 9 running the same scene.
- A dual **CPU-solver / GPU-render stress benchmark** rains 2k → 96k bodies and
  reports each machine's ceiling (headless = pure solver, windowed = fps under
  the instanced render load), auto-escalating until saturation.
- The engine-free sim cores (fire, glass, demolition math) ship with **headless
  unit tests**.

## Quick start

Requires **Godot 4.7.1** — download it from
[godotengine.org](https://godotengine.org/download) (a standalone binary, no
installer). This repo ships only the project and the prebuilt Box3D libraries,
not the editor.

```sh
git clone https://github.com/SifuInTheShell/Box3D_Demo
```

**Windows & Linux** — open `game/project.godot` in Godot 4.7 and press
**F5**. Prebuilt Box3D libraries for both platforms are committed to
`game/bin/`, so there's no build step (Linux headless works too:
`godot --headless --path game res://scenes/test/settle_test.tscn`).

**macOS** — build the extension first (see
[Building the physics DLLs](#building-the-physics-dlls-yourself)), drop the
library into `game/bin/`, and add your platform's entries to
`game/bin/box3d.gdextension`.

Number keys switch scenes:

- `1` — a block tower to knock down (the baseline)
- `2` — a landmarks park (suspension bridge, tower, pyramid) over an interactive-water river
- `3` — a city grid (buildings, industrial district, crane, trees, ragdoll
  pedestrians, scattered street props, and a bird swarm wheeling overhead);
  re-press to toggle size (medium ↔ large), from hundreds to thousands of bodies
- `4` — a fire range: timber cabins, a board fence, a lumber yard and a glass rack to watch fire spread across
- `5` — a demolition derby: six all-physics cars in a walled bowl — wheel-joint
  suspension you can retune live, rear-drive motors with traction control, and
  jointed bodywork (bumpers, doors, hood, trunk, roof) that fatigues and tears
  off from real solver impact speeds. Five AI hunt their nearest living rival.
  Doubles as a suspension proving ground: rumble strip, crossover ramp, tire
  stacks, and a live spring-load telemetry readout

## Controls

| Input | Action |
|---|---|
| **LMB** | shoot a cannonball at the cursor (in charge mode: place a charge) |
| **RMB** | explosion at the cursor (in charge mode: undo last charge) |
| **B** | cannonball barrage from random directions |
| **N** | big blast at screen centre |
| **C** | clear rubble fragments |
| **F** | ignite / torch the surface under the cursor |
| **T** | toggle charge-placement mode · **SPACE** detonate placed charges |
| **R** | reset / reload the scene |
| **Mouse** | free-fly look · **WASD** fly where you're aiming · **E/Q** up/down |
| **Shift** | fly fast · **wheel** fly speed · **Esc** free the cursor · **F11** fullscreen |

**Crane** (city scene): `G/H` slew boom · `J/K` trolley in/out · `PgUp/PgDn`
hoist · arrows pump the ball's swing. **Fire scene:** `G` douse with water,
`V` toggle wind.

**Derby scene:** arrows drive (`Up/Down` throttle + brake, `Left/Right` steer;
`WASD` drives too while the chase cam is on) · `X` handbrake · `V` chase camera
on/off · `Y` a fresh car (the old one stays in the bowl as scrap) · `U/J`
suspension stiffer/softer · `I/K` damper firmer/softer.

## Building the physics DLLs yourself

### One command: the updater scripts

`tools/` ships an updater per platform that does the whole cycle — **pull the
latest engine from Erin Catto's repo, rebuild the GDExtension (including our
extended binding), and deploy into `game/bin/`**:

```sh
tools/update_box3d.sh              # Linux: pull + rebuild + deploy (.so)
tools/update_box3d.sh --no-pull    #        rebuild + deploy only
```
```bat
tools\update_box3d.bat             rem Windows (from an MSVC prompt): pull + rebuild + deploy DLLs
tools\update_box3d.bat nopull      rem        rebuild + deploy only
```

The sync only replaces upstream-owned paths (`src/`, `include/`, tests,
samples, root build files) — `godot/`, which carries the extended wrapper, is
never touched, so pulling upstream can't lose the binding. The pulled commit
is recorded in `extern/box3d-godot/UPSTREAM_COMMIT`. If the build breaks
right after a pull, upstream changed its C API and the wrapper needs a
matching patch. Each platform's script deploys that platform's libraries;
run both (or grab a teammate's DLLs) for a cross-platform commit.

### By hand

The engine and binding live under `extern/box3d-godot/` — a vendored fork of
`erincatto/box3d` whose only additions are in `godot/`, with the `godot-cpp`
submodule materialized so it builds fully offline. The GDExtension build
**compiles Box3D from source itself**; you don't need a separate engine build
or any prebuilt Godot binary.

**Requirements:** Python 3 + [SCons](https://scons.org) (`pip install scons`)
and a C/C++ toolchain (MSVC on Windows; GCC/Clang on Linux; MinGW cross-builds
work too).

```sh
cd extern/box3d-godot/godot

# Windows (from an MSVC / "x64 Native Tools" prompt):
scons                             # debug (editor) build
scons target=template_release     # release build

# Linux (produces a .so):
scons platform=linux
scons platform=linux target=template_release
```

> **`scons` not found?** On Windows `pip` often drops `scons.exe` in a
> `Scripts\` folder that isn't on `PATH`. Run it as a module instead — same
> tool: `python -m SCons` (or `py -m pip install scons` then `py -m SCons`).

Output lands in `extern/box3d-godot/godot/demo/bin/` as
`libbox3d_godot.<platform>.<target>.<arch>.<dll|so>`. The first build also
compiles `godot-cpp` (a few minutes); rebuilds are incremental. The SConstruct
already sets C17, the SSE2/NEON SIMD solver, and the **determinism flags**
(`-ffp-contract=off`) that keep Box3D bit-exact — don't add fast-math here.

### Deploy into the project

```sh
# Windows
cp extern/box3d-godot/godot/demo/bin/libbox3d_godot.windows.*.dll game/bin/
# Linux
cp extern/box3d-godot/godot/demo/bin/libbox3d_godot.linux.*.so   game/bin/
```

`game/bin/box3d.gdextension` ships **Windows-only** (both debug and release DLL
entries). To run on another platform, copy its library into `game/bin/` and
restore that platform's lines from the full reference manifest at
`extern/box3d-godot/godot/demo/bin/box3d.gdextension`.

### Optional: the native engine (no Godot)

Only needed to run upstream's own samples, unit/determinism tests, or the
raw-solver benchmark — the GDExtension build above doesn't depend on it.

```sh
cd extern/box3d-godot
build_vs2022.bat                                   # Windows (VS project files)
cmake --preset linux-release && cmake --build build   # Linux/macOS
```

**Full build & deployment guide** (both paths, update procedure, the API tour):
[`docs/box3d-build-and-use.md`](docs/box3d-build-and-use.md).

## The engine: Box3D

Box3D is a data-oriented C17 rigid-body engine with a soft-step solver, graph-
coloured multithreaded contacts, island sleep, continuous collision, and
cross-platform determinism. The GDExtension exposes it as ordinary Godot nodes:

| Node | Role |
|---|---|
| `Box3DWorld` | Owns a simulation; steps each physics frame. `substep_count`, `worker_count`, `gravity`, `continuous_collision`; `raycast` / `overlap_sphere` / `explode`; the diagnostics & recording API above |
| `Box3DBody` | Rigid body under the nearest `Box3DWorld`. `body_type`, `shape_type` (BOX/SPHERE/CAPSULE/CYLINDER/CONE/HULL/MESH), forces/impulses, live shape materials, `contact_monitor` + `body_entered` / `body_hit` |
| `Box3DCollisionShape` | Extra child shape → compound body |
| `Box3DCharacterBody` | Kinematic capsule with `move_and_slide` |
| `Box3D{Hinge,Slider,Distance,Ball,Fixed,Motor,Wheel,Parallel}Joint` | Constraints between two bodies, with force/tuning readouts |

```gdscript
var world := Box3DWorld.new()
add_child(world)

var ground := Box3DBody.new()
ground.body_type = Box3DBody.STATIC
ground.box_size = Vector3(20, 1, 20)
world.add_child(ground)

var crate := Box3DBody.new()      # DYNAMIC by default
crate.position = Vector3(0, 5, 0)
world.add_child(crate)            # set shape/size/density BEFORE add_child
```

Full binding reference (every node, property, method):
[`extern/box3d-godot/godot/README.md`](extern/box3d-godot/godot/README.md). The
binding also ships its own **sample browser** (~28 physics scenes — stacks,
pyramids, joints, a drivable car, ragdolls, queries) that opens standalone at
`extern/box3d-godot/godot/demo/project.godot`.

## Repo layout

```
game/                      the Godot project (open game/project.godot in 4.7)
  bin/                     Box3D GDExtension: .gdextension + prebuilt Windows/Linux libs
  systems/                 engine-free sim cores (fire, glass, wind, ambient, demolition) + tests
  lib/                     shared engine layer: bodies, generators, FX + assets,
                           water, fire/glass bridges, ambient life
  scenes/demo/             the demo scenes (city, fire, destruction, derby) — thin, on top of lib/
  scenes/test/             headless settle-test + the stress benchmark
  gyms/destruction/        the shared base gym the demo scenes extend
extern/box3d-godot/        vendored engine + GDExtension source (build the DLLs here)
tools/                     update_box3d.sh / .bat (upstream pull + rebuild + deploy),
                           Poly Haven asset fetcher
docs/                      build guide, engine techniques, sim research, perf
```

## Tests & benchmark

Every suite exits nonzero on failure — the exit code is the verdict, and CI
(`.github/workflows/tests.yml`) runs all of them on every push. The pure sim
cores run headless as `SceneTree` scripts:

```sh
# One per sim core (fire, glass, wind, ambient, and five demolition suites):
godot --headless --path game -s systems/fire/fire_sim_test.gd
godot --headless --path game -s systems/glass/glass_sim_test.gd
godot --headless --path game -s systems/wind/wind_sim_test.gd
godot --headless --path game -s systems/ambient/ambient_sim_test.gd
godot --headless --path game -s systems/demolition/demo_math_test.gd
#   ... plus structural_integrity / panel_graph / brick_lattice /
#       blast_plan_types under systems/demolition/.
```

A full-physics harness proves the generated demo city settles without
self-destructing under its own weight — its exit code is the verdict:

```sh
godot --headless --path game res://scenes/test/settle_test.tscn
```

A second full-physics harness runs the derby for 40 s with every car on
autopilot, and checks the whole crash stack end to end — that the pack traded
real hits, that welds gave and bodywork tore off, that the arena wall contained
every chassis, and that all positions stayed finite:

```sh
godot --headless --fixed-fps 60 --path game res://scenes/test/derby_test.tscn
```

`res://scenes/test/bench_stress.tscn` is the dual CPU-solver / GPU-render
benchmark — it rains 2k→96k cubes and reports the per-machine ceiling, choosing
its mode from whether a window is present:

```sh
# headless → pure CPU-solver ceiling (per-stage step timings)
godot --headless --path game res://scenes/test/bench_stress.tscn
# windowed → CPU solver + GPU instanced render, fps under load
godot --path game res://scenes/test/bench_stress.tscn
```

Cross-machine results and the full profiling protocol are in
[`docs/perf-igpu-vs-rtx.md`](docs/perf-igpu-vs-rtx.md).

## Documentation

- [`docs/box3d-build-and-use.md`](docs/box3d-build-and-use.md) — the build guide
  (repos, both build paths, the updater scripts, deployment, API tour).
- [`docs/box3d-binding-extensions.md`](docs/box3d-binding-extensions.md) — what
  the binding adds on top of the base fork to reach near-complete Box3D API
  coverage (every extended World / Body / Joint method, categorized).
- [`docs/box3d-techniques.md`](docs/box3d-techniques.md) — how the solver works
  internally and how tuning follows from it.
- [`docs/perf-igpu-vs-rtx.md`](docs/perf-igpu-vs-rtx.md) — profiling protocol and
  the automated benchmark.
- Sim design notes: [`docs/fire-research.md`](docs/fire-research.md),
  [`docs/glass-research.md`](docs/glass-research.md),
  [`docs/water-research.md`](docs/water-research.md).

## Credits & license

- **Box3D** — © Erin Catto, [MIT](https://opensource.org/license/mit); the
  engine that does the real work. ⭐ [erincatto/box3d](https://github.com/erincatto/box3d).
- **box3d-godot** — the Godot 4.7 GDExtension fork
  ([Stink-O/box3d-godot](https://github.com/Stink-O/box3d-godot)), MIT
  (`extern/box3d-godot/LICENSE`).
- **godot-cpp** and **Godot Engine** — MIT (download the engine from
  [godotengine.org](https://godotengine.org/download); license notices at
  [godotengine.org/license](https://godotengine.org/license)).
- **Assets** — Kenney, Poly Haven, Quaternius, ambientCG (all CC0), itemized
  per file in `game/lib/fx/models/CREDITS.md`, `game/lib/fx/textures/CREDITS.md`
  and `game/lib/ambient/audio/CREDITS.md`. The one exception: the
  demolition-charge model is **CC-BY 3.0** ("C4" by J-Toastie), credited in
  those files.

This repo's own code is **MIT** — see [`LICENSE`](LICENSE). Vendored
third-party code keeps its own licenses as above.
