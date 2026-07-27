# Erin Catto's engine techniques — what Box3D does and what it means for us

Distilled from Erin Catto's box2d.org posts. Box3D — the engine vendored in
`extern/box3d-godot` and driving every scene here — is Catto's own 3D fork of
Box2D v3, so most of this material *is* our engine's design doc.

Sources:
- [SIMD for Collision](https://www.box2d.org/posts/2026/07/simd-for-collision/) (Jul 2026)
- [Announcing Box3D](https://www.box2d.org/posts/2026/06/announcing-box3d/) (Jun 2026)
- [Replay](https://www.box2d.org/posts/2026/06/replay/) (Jun 2026)
- [Box2D 3.1 / Dynamic Tree Improvements](https://www.box2d.org/posts/2025/03/dynamic-tree-improvements/) (2025)
- [Determinism](https://www.box2d.org/posts/2024/08/determinism/), [SIMD Matters](https://www.box2d.org/posts/2024/08/simd-matters/) (Aug 2024)
- [Solver2D](https://www.box2d.org/posts/2024/02/solver2d/) (Feb 2024)
- [Simulation Islands](https://www.box2d.org/posts/2023/10/simulation-islands/) (Oct 2023)

## The techniques

### 1. Soft Step solver: substeps beat iterations (Solver2D)
Catto benchmarked 8 solver architectures; the winner ("TGS Soft" → Box2D
v3's "Soft Step") combines **sub-stepping** with **soft constraints** and a
relaxation pass. Key findings:
- Smaller time steps outperform more solver iterations (Taylor-series
  argument: step size reduction beats iteration count).
- **Strong friction is crucial to stable stacking** — more than warm
  starting.
- Soft constraint stiffness (contact hertz) can be higher when substeps are
  smaller, making contacts look more rigid.

**For us:** `Box3DWorld.substep_count` is *the* quality dial — that's why
our adaptive 4→2 substep drop under load is the right lever (it's exactly
what the solver design anticipates trading). Keep panel/brick friction high
(we use 0.75–0.8; don't lower it, stacks depend on it). `contact_hertz` (60
in the binding) is tuned for 4 substeps; if we ever run substeps=2
permanently, drop hertz toward 30.

### 2. Wide SIMD contact solving + graph coloring (SIMD Matters)
Contacts are grouped by graph coloring (no body appears twice per color), so
blocks of 4–8 constraints solve simultaneously in SSE2/NEON/AVX2 lanes.
Measured on the large pyramid: scalar 1.91 ms → SSE2 1.02 ms → AVX2 0.90 ms.

**For us:** free — this is the solver our DLL runs (SSE2 on x64). It's why
16k awake bodies still stepped in ~26 ms on a laptop iGPU machine. AVX2 adds
only ~14% and complicates cross-platform bit-exactness; not worth a custom
build.

### 3. SIMD for collision: SAT edge batching (the post you linked)
New in Box3D (Jul 2026): the separating-axis test for convex hulls is
quadratic in edges (a 32-point "boulder" hull = 7,921 edge pairs). Restructuring
edge data as structure-of-arrays and testing 4 (SSE2) or 8 ("AVX2-Lite")
edge pairs at once made the convex-pile benchmark (5,120 boulder hulls)
**2.3× faster** (40.7 s → 17.3 s single-threaded; 5.3 s → 2.4 s on 8 threads).

**For us:** currently negligible — Catto notes box-box pairs don't benefit,
and our city is 100% boxes. It becomes relevant the day we swap debris/props
to convex-hull meshes (`Box3DBody.HULL` with imported rock/chunk meshes):
the engine is already built for that, just keep hulls modest (≤32 points;
Box3D caps hulls at 128 edges). The committed DLLs are built from the current
vendored source, so the work is already in them.

### 4. Persistent simulation islands + island sleeping (Simulation Islands)
Bodies + constraints form graph islands; whole islands sleep when every body
stays below the velocity threshold, and wake by propagation. v3 keeps
islands persistent across steps (union-find merge, deferred splits) instead
of rebuilding via DFS each tick, keeping merges deterministic and cheap.

**For us:** this explains our best result — 24,000 settled bodies costing
~2 ms. Practical guidance it implies:
- Static geometry (our ground) doesn't merge islands: each building is its
  own island and solves on its own worker thread. Keep structures physically
  separate; don't chain the whole city together with touching rubble bridges
  if avoidable.
- "Large monolithic islands remain bottlenecks" — a single huge connected
  rubble pile is the worst case, which matches our crunch measurements. Our
  fracture queue + debris caps are the right mitigations.

### 5. Determinism (Determinism post)
Box2D/Box3D are cross-platform deterministic: no fast-math,
`-ffp-contract=off`, custom trig, bit-array ordering instead of atomics.
The vendored fork treats this as a red line (scalar/SSE2/NEON bit-exact,
verified by upstream's determinism test).

**For us:** the engine guarantee only holds end to end if our layer matches it,
so every generator and fracture RNG is seeded from a shared stream — the
condition for replays and for regression tests that compare exact outcomes.
Verified in practice: the stress benchmark's contact counts per stage are
byte-identical across two different CPUs (`perf-igpu-vs-rtx.md` §5).

### 6. Recording / replay (Replay post)
Box2D 3.2 records the initial world snapshot plus every API call's arguments
into a compact `.b2rec` file; determinism makes the replay bit-exact, with
keyframes for scrubbing. Box3D vendors the same machinery (`src/recording.c`,
`recording_replay.c`).

**For us:** a very attractive debugging tool — record a demolition that
misbehaves, replay it deterministically. `Box3DWorld.start_recording` /
`stop_recording` / `validate_replay` are exposed in the extended binding
(`box3d-binding-extensions.md`); feeding a recording *back* into a live world
is the piece still missing.

### 7. Dynamic tree (broadphase) improvements
The BVH insertion heuristic got smarter cost prediction (Box2D 3.1 era).
Free benefit; nothing to do on our side. Mass spawning (our 24k lattice)
stresses exactly this path and behaved fine.

## The rules that follow

| Rule | Why |
|---|---|
| Friction ≥ 0.75 on structural bodies | Stack stability, per Solver2D — more load-bearing than warm starting |
| Keep adaptive substeps; if locked at 2, lower `contact_hertz` to ~30 | Solver softness stays matched to the substep rate |
| Seed every game-layer RNG from a shared stream | The engine's determinism is only end-to-end if our layer matches it |
| Convex-hull debris only where it pays, ≤ 32 points | SAT SIMD keeps hulls affordable (2.3×), but boxes stay cheapest |
| Don't fuse the whole scene into one island | Islands are what buy parallelism *and* sleeping |
| Rebuild the DLLs after pulling upstream | New solver work (`async_step`, `contact_recycling`, SIMD SAT) only lands in the binary you build — see `box3d-build-and-use.md` |
