# Box3D — building and using the engine from Erin Catto's repo

How the Box3D physics engine gets from source code to `Box3DWorld.new()` in
our gyms: the repos involved, both build paths (standalone engine and the
Godot GDExtension), deployment into `game/bin/`, and the API surface we
build on. Companion to `docs/box3d-techniques.md` (what the engine does
internally and why our tuning choices follow from it).

## 1. The three repos and what we vendor

| Repo | What it is | Our pin |
|---|---|---|
| [erincatto/box3d](https://github.com/erincatto/box3d) | Upstream: Catto's 3D rigid-body engine (C17, v0.1.x, the 3D successor to Box2D v3) | via the fork below |
| [Stink-O/box3d-godot](https://github.com/Stink-O/box3d-godot) | Fork of upstream with a Godot 4.7 GDExtension in `godot/`. Upstream sources are **unchanged**; everything Godot-specific lives in that one folder, so the fork syncs cleanly | `a42bed6` |
| [godotengine/godot-cpp](https://github.com/godotengine/godot-cpp) | The GDExtension C++ bindings, normally a submodule of `godot/` | `ba0edfed90512ec64aba51d4295a3e7e30112f86` |

All of it is vendored in `extern/box3d-godot/` with the godot-cpp submodule
**materialized**, so a fresh clone can rebuild the extension fully offline.
Treat the vendored tree as read-only third-party code: to change or update
it, sync from upstream and re-copy (updating the pins in the root README),
never patch in place.

Layout of `extern/box3d-godot/`:

```
include/  src/          the engine (public headers / C17 sources)
samples/  benchmark/    upstream's sample browser and benchmarks (native app)
test/                   upstream unit + determinism tests
CMakeLists.txt          native build (engine, samples, tests)
build.sh                CMake convenience wrapper (Linux/macOS)
build_vs2022.bat        generate Visual Studio 2022 project files into build\
build_vs2026.bat        same for VS 2026
godot/                  the GDExtension
  SConstruct            one-command build: godot-cpp + engine + wrapper
  godot-cpp/            bindings (materialized submodule)
  src/                  the C++ wrapper (box3d_body.cpp, joints, character…)
  compat/               additive Windows.h shim for MinGW cross-builds
  demo/                 sample-browser Godot project (~28 physics scenes)
  demo/bin/             build OUTPUT: .gdextension + platform libraries
  ANDROID_BUILD.md      Android toolchain walkthrough (arm64/x86_64 only)
  README.md             FULL binding reference: every node, property, method
```

## 2. Build path A — the native engine (no Godot)

Only needed for upstream's own samples/benchmarks/tests — the GDExtension
build (path B) compiles the engine from source itself and does not depend
on this.

```sh
cd extern/box3d-godot
# Windows: generate VS project files into build\ then build in the IDE
build_vs2022.bat            # or build_vs2026.bat; add "fresh" to reconfigure
# Linux/macOS: CMake presets ("windows", "linux-debug", "linux-release", "macos")
cmake --preset linux-release && cmake --build build
```

That produces the `samples` app (upstream's native sample browser) and the
unit/determinism tests — both **on by default**. The benchmark suite is
**off by default** (`BOX3D_BENCHMARKS=OFF` in `CMakeLists.txt`), so the
commands above do *not* build it; see the next subsection. Useful when
isolating "is this an engine bug or a binding bug".

### Building and running the benchmark suite

The benchmark app (`benchmark/main.c`) measures the raw solver — no Godot,
no rendering — across 11 scenes (convex_pile, joint_grid, junkyard,
large_pyramid, large_world, many_pyramids, rain, trees25/50/100, washer),
sweeping thread counts. It must be enabled at configure time.

```bat
rem --- Windows (from a "x64 Native Tools Command Prompt for VS") ---
cd extern\box3d-godot
cmake -S . -B build -G "Visual Studio 17 2022" -DBOX3D_BENCHMARKS=ON
cmake --build build --config Release --target benchmark
rem binary lands here (CMAKE_RUNTIME_OUTPUT_DIRECTORY = build\bin):
build\bin\Release\benchmark.exe --list        rem show the scene names
build\bin\Release\benchmark.exe               rem run all, sweep 1..N cores
```

```sh
# --- Linux/macOS ---
cd extern/box3d-godot
cmake --preset linux-release -DBOX3D_BENCHMARKS=ON && cmake --build build --target benchmark
./build/bin/benchmark --list
./build/bin/benchmark
```

Flags (all optional): `-b=<name>` / `--benchmark=<name>` run one scene;
`-t=<n>` / `--threads=<n>` cap the thread sweep; `-w=<n>` / `--workers=<n>`
run a single worker count instead of sweeping; `-r=<n>` / `--repeats=<n>`
runs per config (default 4, the min is kept); `-nc` / `--no-continuous`
disable continuous collision; `-s` / `--record-steps` also dump per-step
profiles; `-l` / `--list`; `-h` / `--help`.

Output: per-run milliseconds print to stdout, and each scene writes
`<name>.csv` (`threads,ms`) into the **current working directory** (with
`-s`, also `<name>_t<threads>.dat` per-step profiles). Run it from a fresh
folder so the CSVs don't mix. Committed reference baselines to diff against
live in `benchmark/amd7950x_sse2/`, `benchmark/amd7950x_scalar/`, and
`benchmark/m2air_neon/` — same CSV shape, one file per scene.

> This is the **engine** benchmark (CPU solver only). For whole-game
> GPU-tier profiling (glow, overdraw, particles under the real renderer)
> use the in-game protocol in `docs/perf-igpu-vs-rtx.md` instead.

## 3. Build path B — the Godot GDExtension (what the demo uses)

Requirements: Python 3 + SCons (`pip install scons`), a C/C++ toolchain
(MSVC on Windows; GCC/Clang on Linux; MinGW cross-compiles work — the
`compat/windows-case/Windows.h` shim covers case-sensitive hosts), and
nothing else: godot-cpp is vendored, the engine builds from source, no
prebuilt Godot binary is involved.

```sh
cd extern/box3d-godot/godot
scons                            # debug (editor) build for the host platform
scons target=template_release    # release build
# cross/other platforms:
scons platform=linux             # + target=... ; produces .so
scons platform=windows           # from MSVC prompt, or MinGW cross
# Android (arm64/x86_64 only -- the NEON path is AArch64-only):
#   see godot/ANDROID_BUILD.md for the NDK toolchain walkthrough
```

**If `scons` isn't found** (common on Windows: `pip` drops `scons.exe` in
a `Scripts\` folder that isn't on PATH), invoke it as a Python module
instead — same tool, no PATH change, and it works identically everywhere
`scons` appears above:

```sh
python -m SCons                          # == scons
python -m SCons target=template_release  # == scons target=template_release
```

If that reports "No module named SCons", your `pip` and `python` are
different interpreters — use the launcher so they match:
`py -m pip install scons` then `py -m SCons`. To find where the `.exe`
actually landed (to add it to PATH): `python -c "import sysconfig;
print(sysconfig.get_path('scripts'))"`.

Output lands in `extern/box3d-godot/godot/demo/bin/` as
`libbox3d_godot.<platform>.<target>.<arch>.<dll|so|framework>` next to the
full multi-platform `box3d.gdextension`. First build compiles godot-cpp too
(a few minutes); rebuilds are incremental.

The SConstruct already handles the details that matter:
- C17 for the engine sources (`/std:c17` / `-std=gnu17`)
- **Determinism flags** (`-ffp-contract=off` on GCC/Clang) — Box3D is
  cross-platform bit-exact and treats that as a red line; never add
  fast-math flags to this build
- The engine's SIMD solver (SSE2 on x64, NEON on arm64) — nothing to
  configure

### Deploying into the demo

```sh
cp extern/box3d-godot/godot/demo/bin/libbox3d_godot.windows.*.dll game/bin/
```

`game/bin/box3d.gdextension` carries **Windows and Linux x86_64** entries
(debug + release each), and the matching libraries are committed. To add
another platform, build its library, copy it to `game/bin/`, and restore that
platform's entries from the full reference file
`extern/box3d-godot/godot/demo/bin/box3d.gdextension` (macOS/Android lines,
including the Android 64-bit-only caveat).

### Committing the rebuilt DLLs into this repo

The two Windows DLLs are **tracked in this repo on purpose** — a fresh
clone plays on Windows with no build step. So "updating the DLL" is a plain
commit: the rebuild+copy overwrites the same two filenames in place, they
are already tracked, and **no `git add -f` is needed**.

```sh
git add game/bin/libbox3d_godot.windows.template_debug.x86_64.dll \
        game/bin/libbox3d_godot.windows.template_release.x86_64.dll
git commit -m "chore: rebuild Box3D DLLs (<what changed — e.g. wrapper extensions II>)"
git push
```

- **Commit both configs together** so `template_debug` and
  `template_release` never drift apart from the source they were built
  from. `git status` should show exactly those two `.dll` paths modified.
- `.gitignore` excludes only `game/bin/~*.dll` — the `~<name>…TMP` scratch
  files the copy step leaves behind (e.g.
  `~libbox3d_godot.windows.template_debug.x86_64.dll~RF…TMP`). Those are
  build litter; delete them, never commit them.
- The `box3d.gdextension` manifest rarely changes on a rebuild; only
  re-commit it if you actually edited platform entries (see above).
- After pushing, note the source commit the binaries were built from in
  the message (or the PR) — the committed DLLs otherwise give no hint of
  which wrapper revision they contain, which is exactly how they went
  stale before.

### When to rebuild

The committed libraries are built from the current vendored source, so they
already carry the extended binding plus the upstream solver work the scenes
check for (`async_step`, `contact_recycling`, `sync_node_transform`, the SIMD
SAT collision path). Rebuild when you pull upstream (§5) or edit the wrapper —
new engine work only reaches the demo through a binary you build. The one
piece the binding still doesn't surface is replay *playback* into a live world;
recording and validation are exposed
([`box3d-binding-extensions.md`](box3d-binding-extensions.md)).

## 4. Using it — the API surface

Full reference: **`extern/box3d-godot/godot/README.md`** documents every
node, property and method (worlds, bodies, all shapes, the full joint set,
character controller, queries, contact events). What *this fork* added on top
of the base binding is catalogued in
[`box3d-binding-extensions.md`](box3d-binding-extensions.md). The short version:

| Node | Role |
|---|---|
| `Box3DWorld` | Owns a simulation; steps each physics frame (`auto_step`) |
| `Box3DBody` | Rigid body under the nearest `Box3DWorld` ancestor |
| `Box3DCollisionShape` | Extra child shape → compound body |
| `Box3DCharacterBody` | Kinematic capsule with `move_and_slide` |
| `Box3D{Hinge,Slider,Distance,Ball,Fixed,Motor,Wheel,Parallel}Joint` | Constraints between two bodies |

Minimal scene (this is `game/main.gd`, the smoke test):

```gdscript
var world := Box3DWorld.new()
add_child(world)

var ground := Box3DBody.new()
ground.body_type = Box3DBody.STATIC
ground.box_size = Vector3(20, 1, 20)
ground.auto_visual = true          # quick debug mesh; real code adds visuals
world.add_child(ground)

var crate := Box3DBody.new()       # DYNAMIC is the default
crate.position = Vector3(0, 5, 0)
crate.auto_visual = true
world.add_child(crate)
```

What our gym code actually leans on, as a working vocabulary:

- **World**: `substep_count` (the quality dial — see box3d-techniques §1),
  `worker_count` (multithreaded solver), `continuous_collision`,
  `gravity`, `explode(at, radius, impulse, falloff)`,
  `overlap_sphere(at, radius)`, `raycast(from, to)` → `{hit, position,
  normal, body}`
- **Body**: `body_type` (STATIC/KINEMATIC/DYNAMIC), `shape_type` (BOX /
  SPHERE / CAPSULE / CYLINDER / CONE / HULL / MESH), `box_size` /
  `capsule_radius` / `capsule_height` / `collision_mesh` (HULL takes an
  `ArrayMesh`, ≤ 32 points is the sweet spot), `density`, `friction`,
  `collision_layer` / `collision_mask`, `apply_central_force` /
  `apply_torque` / `apply_central_impulse`, `get_/set_linear_velocity`,
  `get_angular_velocity`, `get_mass`, `contact_monitor` +
  `body_entered(other)` (how every fracture threshold in the gyms works)
- **Compound bodies**: add `Box3DCollisionShape` children (the GLB trees:
  trunk cylinder + canopy cylinder on one body)
- **Joints**: crane cables (`cable.gd`) chain `Box3DBallJoint` links —
  the reference for any rope/winch work

Two conventions the binding imposes that our code already follows: set
shape/size/density **before** `add_child` (the body is created in the
world on enter-tree), and there is no force-at-point — sum forces into
`apply_central_force` + `apply_torque` (see `water_fx.gd` for the
pattern).

### The sample browser

`extern/box3d-godot/godot/demo/project.godot` opens standalone in Godot
4.7 (prebuilt Windows DLLs are committed there too) — ~28 scenes covering
stacks, pyramids, joints, the car, ragdolls, queries and stress toys.
When a behavior surprises you, find the nearest sample and compare before
suspecting the engine; when the engine itself is suspect, path A's native
samples/tests are the second opinion.

## 5. Sync/update procedure

Use the updater scripts in `tools/` — they encode the whole cycle:

```sh
tools/update_box3d.sh          # Linux: pull upstream + rebuild + deploy .so
tools\update_box3d.bat         # Windows (MSVC prompt): same, deploys DLLs
# add --no-pull / nopull to rebuild-only (e.g. after editing the wrapper)
```

What they do, and the rules they follow:

1. Shallow-clone `erincatto/box3d` and replace ONLY upstream-owned paths
   (`src/`, `include/`, `test/`, `samples/`, `shared/`, `extern/`,
   `benchmark/`, `data/`, `docs/`, root build files). The fork's additive
   discipline means `godot/` — godot-cpp and **our extended wrapper**
   (marked `// --- Extended core access ---`) — plus `README.md` and
   `.gitignore` are never touched, so a pull cannot lose local work.
2. Record the pulled commit in `extern/box3d-godot/UPSTREAM_COMMIT` (the
   pin; the base fork was Stink-O/box3d-godot `a42bed6`, since extended
   locally in `godot/src`).
3. Rebuild debug + release via SCons and deploy that platform's libraries
   into `game/bin/` (the Linux script also appends the Linux entries to
   `box3d.gdextension` if missing). Nothing deploys on a failed build — a
   post-pull build failure means upstream changed the C API and the
   wrapper needs a matching patch. Commit rebuilt Windows DLLs per §3
   ("Committing the rebuilt DLLs into this repo").
4. Then verify: the headless suites under `game/systems/`, the vendored
   demo selftests (`--import`, then `tests/test_features.tscn` /
   `tests/test_samples.tscn` with `--selftest`), and a gym playtest.
