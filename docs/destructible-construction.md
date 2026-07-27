# Destructible Construction System ("Bricks")

How every structure — target and surroundings alike — is built to be
physically destructible. Based on an industry survey (§1), numeric feasibility
validation (§3), and the verified constraints of the vendored Box3D binding.
Companion math: [`core-math.md`](core-math.md).

**The one-line design:** *stacked dynamic panels are the simulation truth; a
brick lattice plus a geometry-derived support graph is the analysis layer;
debris lives on a hard budget.*

Two representations coexist, deliberately:

- **Runtime** is the **panel stack** (`lib/gen/building_gen.gd`,
  `lib/bodies/wall_panel.gd`): every structure is dynamic `Box3DBody` wall
  panels stacked platform-style (piers → lintel band → floor slab → next
  storey), held up by nothing but friction (≥ 0.75) and gravity — no joints,
  no welds, no static merging — with two-tier impact fracture (panel → BSP
  shard chunks → fragments), a per-frame fracture queue, global debris caps
  and seeded RNG. Blast out the piers and the solver itself drops whatever
  they carried: correct collapse is *emergent*, with no integrity rules in the
  loop. Measured (see [`box3d-techniques.md`](box3d-techniques.md)): ~24 k
  settled bodies cost ~2 ms (persistent sleeping islands), 16 k awake bodies
  step in ~26 ms, and the headless settle test verifies 1,740 panels stand at
  rest in a 6×6 city.
- **Analysis** is `panel_graph.gd` over the same panels and `brick_lattice.gd`
  + `structural_integrity.gd` over lattice cells: deterministic *prediction*
  (what is likely to fall, and where load re-routes after a cut) and
  **bake-time certification** that a generated structure stands on load. The
  sim decides what actually falls; the analysis layer answers questions
  without running the sim. `panel_graph.gd` builds the support graph from
  panel geometry alone (rest-on relations + contact areas), runs the
  area-weighted load flow over it, and exposes per-contact stress,
  unsupported-panel flags and `certify()` — 13 headless checks green (a band
  splits evenly across piers; cutting a pier doubles the surviving contact's
  stress; floating panels are flagged; storey chains resolve to ground).

Engine island-sleeping removes most of the cold-tier cost that motivated
static merging, so §2's tier design below is retained as a documented
optimization path — for city scale beyond what sleeping islands absorb, and
for masonry-only structure types that want finer-than-panel damage — not as
the current foundation. The lattice code stays validated and ready.

---

## 1. What the industry actually does (survey)

Systems studied: Teardown, Red Faction: Guerrilla (GeoMod 2.0), Rainbow Six
Siege (RealBlast), Battlefield/Frostbite + THE FINALS, NVIDIA APEX/Blast SDK,
Brick Rigs, ABRISS, Instruments of Destruction, Space Engineers (source read),
Medieval Engineers, 7 Days to Die, Valheim, Besiege. Sources at the end.

### The five-stage consensus pipeline for "destructible anywhere" at 60 fps

1. **Merged at rest.** Undamaged structure = one static (or few) bodies;
   per-piece bodies exist only latently (Blast chunk hierarchy; Brick Rigs'
   editor welds; Teardown's static voxel shapes; UE Chaos clustering).
2. **Damage events are local.** Damage reduces connection health / removes
   voxels in a radius — never a global operation.
3. **Batched connectivity on the damaged asset only.** Flood fill / island
   search scoped to the damaged structure, threaded, applied next tick. Space
   Engineers' own source comments that this costs "several ms per query — call
   sparingly"; nobody runs it per frame; Blast formalizes it as an explicit
   split call over a deliberately coarse support graph.
4. **Optional cheap stress pass** over the same coarse graph (iterative
   relaxation, never FEM) for progressive collapse instead of floating
   islands — Red Faction Guerrilla's signature system (GDC 2011, Eric Arnold);
   NVIDIA Blast's `ExtStress` (explicit per-frame iteration budget, default
   18 k, plus a `graphReductionLevel` that coarsens the graph by ~2³);
   Instruments of Destruction's Luke Schneider reports his RFG-style stress
   pass took "a couple hours to implement" on top of a working connection
   graph and transformed collapse quality.
5. **Ruthless debris lifecycle.** New islands become simplified dynamic bodies
   → sleep fast → small/old/unseen pieces convert to particles, merge to
   static, or get deleted (Teardown deletes debris when you look away; Siege
   hides pieces; Frostbite converts rubble to effects). Nobody keeps all
   debris live.

Orthogonal principle everywhere: **visual granularity ≠ structural
granularity.** The stress/connectivity graph is 1–2 orders of magnitude
coarser than what the player sees breaking.

### Why a *pure* Lego-brick runtime is rejected

Not because of the bricks — because of the joints:

- **The weld graph is the killer.** A 4,000-brick building is ~15–20 k weld
  constraints that must be solved (and force-checked) *while intact*. Brick
  Rigs — the shipped pure-brick game — sustains only ~500–1,500 jointed
  bricks before 60 fps dies, and survives via an editor "weld" feature that
  fuses bricks into single bodies; Blast's `graphReductionLevel` exists
  because NVIDIA hit the same wall. Realistic desktop budgets for *active*
  bodies are low-thousands (Jolt's published perf scenes: ~3.7 k-body piles;
  Box2D v3's threading pays off above ~2 k bodies; Box3D inherits that
  architecture).
- **Stiffness.** Long weld chains sag and jitter at 60 Hz; Besiege runs 100 Hz
  for machines of merely tens of blocks. A city block that visibly wobbles
  before you touch it reads as broken.

Also instructive, from opposite ends: **Teardown ships no structural integrity
at all** (a building stands on its last connected voxel — a deliberate
performance *and* content-authoring decision), while Red Faction warns of the
opposite cost — with real structural sim, "artists had to become structural
engineers." A stress pass therefore has to be strong enough to feel real and
predictable enough that a generator can guarantee its structures stand (§6).

## 2. The lattice tiers (optimization path)

Everything can be authored and damaged at brick granularity on a single data
structure, the **brick lattice** (`brick_lattice.gd`: sparse `Vector3i → cell`
occupancy, 6-connectivity, ground plane at `y == ground_y`), with the physics
engine only ever seeing a *derived, merged* representation.

### Tier 0 — Cold (intact structure): static boxes, zero joints

Per structure (or per 8³-brick chunk for big structures), the lattice is
decomposed by **greedy box decomposition** (`BrickLattice.greedy_boxes`) into
maximal axis-aligned boxes, each materialized as one **STATIC `Box3DBody`**
(BOX shape). Validated: a 5,128-brick warehouse shell → **6 static boxes**; a
wall with a blast hole → 12. Static bodies cost the solver nothing, and there
are **no joints anywhere** in an intact structure. Visuals render from the
lattice via MultiMesh, not from physics bodies.

### Tier 1 — Structural events: carve → connectivity → integrity → clusters

On a damage event (charge, impact above threshold, cable pull):

1. **Carve** the lattice locally (`carve_sphere` for charges; removed cells are
   the pulverized bricks → dust plus a few Tier-2 chips).
2. **Scoped connectivity** (`detached_clusters_after`): BFS only from cells
   adjacent to the carve — cost scales with the damaged components, not the
   building (validated: a severed band detaches exactly the top; an L-cut
   drops exactly the corner).
3. **Integrity pass** (`structural_integrity.gd`, §5): the remaining structure
   is re-evaluated against the two-rule model; regions that can no longer be
   supported (an over-wide opening's mid-span, an undercut cantilever, an
   overloaded pier) fail and feed step 4 as additional falling clusters over
   following ticks. **A blast hole is never just a hole.**
4. **Materialize clusters:** each detached cluster is greedy-box-decomposed
   into a handful of **DYNAMIC bodies** welded to each other with a few
   `Box3DFixedJoint`s (soft welds + displacement breaking per
   [`core-math.md`](core-math.md) §3.3). A 100-brick slab = 1 body; an
   L-shaped chunk = 2–3 bodies + 1–2 welds. This respects the binding
   constraint that dynamic bodies cannot be concave meshes (verified: MESH
   colliders are static-only) while keeping per-cluster joint counts near
   zero.
5. **Rebuild Tier 0** for affected chunks (local re-decomposition; a chunk is
   ≤ 512 bricks, sub-millisecond).

### Tier 2 — Debris: spectacle under a hard budget

Clusters below a size threshold (and carve-edge chips near the camera or
blast) shatter into **per-brick dynamic bodies** — brick-scale destruction
where it is visible and affordable. Governed by a global budget:

- `DEBRIS_MAX` live debris bodies (initial: 800); overflow converts
  oldest/smallest to non-colliding particles.
- Settled debris (per `core-math.md` §5.1) is **frozen back into the lattice**
  as occupied cells (STATIC via Tier-0 rebuild) — rubble piles stay
  collidable, walkable and *re-carveable*, which no delete-based lifecycle
  gives. Tiny fragments fade instead.

### Why this keeps brick-level destructibility

Destruction can start at **any brick** of **any structure**: every charge
carves actual lattice cells, every connection can sever, cluster boundaries
are emergent (never authored fracture pieces), and neighbours are exactly as
destructible as the target. What is hierarchical is only the *cost*: intact ≈
0, damaged proportional to damage.

## 3. Validated feasibility numbers

| Quantity | Value |
|---|---|
| Brick granularity | 0.4 m cube, ~115 kg (masonry 1800 kg/m³) |
| Warehouse shell (20×10×8 m) | ~5.5 k bricks → **6 static boxes** intact |
| 12-floor tower (15×15×40 m) | ~33 k bricks → ~433 chunks (8³) for local rebuilds |
| Bricks woken by one 4 m-radius blast (wall) | ~314 |
| Worst-case single blast (8 m radius) | ~1,257 woken + cluster bodies ≈ 1,357 < 1.5 k cap |
| Hole-carved wall re-decomposition | 12 boxes, exact coverage, no overlap |
| Detached 100-brick slab | 1 dynamic body |
| Connectivity checks | scoped BFS; blast-hole → 0 clusters; band cut → exactly top 5 rows; L-cut → exactly the 4×5 corner |

Budgets (initial, tunable): ≤ 1.5 k dynamic bodies peak during an event,
`DEBRIS_MAX` 800 live debris, stress pass ≤ a fixed iteration budget per tick
(Blast's amortization pattern), connectivity on a worker thread with results
applied next tick (Space Engineers' pattern) — with the caveat that
determinism requires the *application* of results at a fixed tick boundary
regardless of thread timing.

## 4. Engine mapping (verified against vendored source)

| Need | Binding fact | Consequence |
|---|---|---|
| Merged static chunks | MESH colliders static-only; BOX shapes universal | greedy **box** decomposition, not merged meshes — works for static *and* dynamic tiers uniformly |
| Dynamic concave clusters | one body = one shape; no compound bodies | cluster = few box bodies + 1–2 soft welds (breakable per core-math §3.3) |
| Waking/freezing tiers | `body_type` settable at runtime (STATIC ↔ DYNAMIC), `teleport` bound | tier transitions are property flips + node adds/frees, no scene rebuild |
| Carve-driven forces | `explode(center, radius, impulse_per_area, falloff, mask)` | one charge event drives both the lattice carve (our layer) and the impulse on live bodies (engine) |
| Debris rendering | `Box3DMultiMeshRenderer` | brick/debris visuals decoupled from body count |
| Sleep management | `enable_sleep`, per-body damping | settle thresholds from core-math §5.1 |

Godot-side note: bricks must **not** be one `Node3D` each at Tier 0 (node
overhead would dwarf physics). The lattice is plain data; only materialized
bodies (boxes, clusters, debris) are nodes, pooled and recycled.

## 5. The structural-integrity layer

Connectivity alone gives Teardown-style "floats until fully cut". When a blast
leaves a hole, the remaining structure has to respond to its actual
load-bearing state.

### The two-rule model

**Rule A — span/bending** (`structural_integrity.gd`): a cell is *columned* if
a continuous vertical chain of cells connects it to ground; every cell must lie
within `span_max` horizontal hops (through the structure, vertical hops free)
of a columned cell, else it fails. This is the 7DTD/Valheim family of scalar
support — cheap, incremental, predictable — and it produces the correct
qualitative statics:

| Case | Result |
|---|---|
| Narrow opening (≤ 2·span) | lintel holds — nothing collapses |
| Over-wide opening (10 bricks, span 3) | exactly the unsupportable mid-span above the hole fails (20 cells); flanks stand |
| Undercut cantilever | fails exactly beyond `span_max`; supported end stands |
| Cascade | deterministic, terminates, bounded rounds |

`span_max` is a material property (masonry ~3 bricks = 1.2 m, steel-framed
much higher), and it is not a tuned constant: `core-math.md` §3.4's bending
math **derives** it (`L_max = √(2·σ_bend·Z/(μ·g))` → 1.23 m ≈ 3 bricks for
0.2 MPa masonry). The same §3.4 moment check runs on the coarse graph as
**Rule A′** — mass-aware cantilever failure the span rule can't see (a
3-brick arm holds bare but fails under a 500 kg tip load).

**Rule B — load/compression** (`demo_math.support_loads`): the support-graph
load estimate on a coarsened graph (2³ super-nodes — Blast's default
reduction) with capacities `σ·A`; connections at utilization > 1 for more than
`T_overload` ticks sever. This is what makes *pre-weakening cuts* meaningful
before any charge fires (remove half the columns → survivors carry double), in
the lineage of RFG's stress system, NVIDIA `ExtStress`, and Space Engineers'
`MyOndraSimulator3` (read first-hand: BFS from grounded cells with side-path
attenuation). Load distribution is area-weighted
(`support_loads_weighted`, stress-equalizing).

### Cascade dynamics

One integrity round runs after every carve; failed regions detach as falling
clusters (Tier 1) and the round repeats next tick until stable
(`integrity_failures` per round; `cascade` computes the fixpoint). Validated
behavior: a failure region is typically resolved in one round and falls **as
one cluster** — the *progressive* look of real collapse then emerges
physically, because the falling cluster impacts lower structure, impacts are
damage events, and damage events carve and trigger new integrity rounds.
Multi-stage collapse is an emergent chain of sim → integrity → sim, not a
scripted sequence.

### Budget & determinism

Rule A is a linear-time scan over the affected structure (bounded per tick,
threaded compute / tick-boundary apply); Rule B runs on the coarse graph with
a fixed iteration budget. Both are deterministic: fixed iteration counts and
lexicographic orders, tick-stamped failures.

### Bake-time certification

`StructuralIntegrity.cascade` doubles as the generator's certifier: a
generated structure must cascade to zero failures with margin (utilization
< 0.7, no cell within 1 hop of its span limit) or the spec fails CI — the
answer to RFG's "artists become structural engineers" problem, enforced
against the exact solver the demo runs. `PanelGraph.certify()` is the same
guarantee for the panel-stack runtime.

## 6. Authoring & the generator

- The generator emits structures whose every panel rests on something
  (`building_gen.gd`: full-height piers, window sills, one continuous lintel
  band per storey carrying the floor slab above). The same specs at lower
  detail generate *surrounding* buildings — one system, whole scene
  destructible.
- **Standing guarantee:** at bake time the generator runs the load solve and
  asserts utilization stays under margin, so specs that can't stand fail CI
  rather than the player's framerate.
- Facade dressing attaches to structures as visual-only children and
  despawns/converts to debris when its parent wakes.
- Non-lattice props (vehicles, fences, the crane) stay ordinary `Box3DBody`
  actors — the lattice is for *masonry*, not everything.

## 7. Determinism

All pipeline stages are our code over our data: carve order, BFS order (seeded
lexicographically — `greedy_boxes` and cluster BFS are already deterministic),
stress iteration counts, budget evictions — all tick-stamped and replayable,
same as `core-math.md` §6. Threaded connectivity must apply results at fixed
tick boundaries (compute-ahead, apply-at-tick). The state hash extends to
lattice occupancy (hash of sorted carved cells per tick) so CI catches
divergence in the destruction layer, not just body transforms.

## 7b. Performance & data-structure notes

- **Dirty-flag protocol (lazy evaluation):** no structural work runs on a
  clean structure — ever. Each structure carries `dirty: bool`; damage events
  (carve, impact above threshold, cable pull, weld break) set it; while dirty,
  one integrity round runs per tick (scoped connectivity + Rule A/A′/B on the
  affected region); reaching the fixpoint clears it. Queries against clean
  structures reuse the last computed solution. This formalizes what the survey
  found in every shipped system (Space Engineers: "several ms per query — call
  sparingly"; Blast's explicit split calls).
- **Why scoped BFS and not union-find for island detection:** union-find is
  near-O(1) for *merging* sets but cannot *split* — and destruction is
  deletion-heavy, which forces a full rebuild per break. Every shipped system
  surveyed (Teardown, Space Engineers, Blast) uses batched flood fill scoped
  to the damaged asset, which is what `BrickLattice.detached_clusters_after`
  implements (frontier-scoped BFS). Union-find IS the right tool for the
  **merge direction**: settled-rubble freeze-back and Tier-0 chunk
  re-consolidation (many small merges, no deletions).
- **Voronoi pre-fracture: props only.** Pre-fractured pieces reintroduce
  authored break boundaries and defeat "destructible anywhere" — rejected for
  structures. For non-masonry hero props (statues, vehicles, the crane cab),
  baking 5–15 convex Voronoi pieces with stored adjacency is standard and
  right; Blender's Cell Fracture runs headless (`--background --python`).

## 8. Risks

- **Box3D is young**; its behavior under mass body spawn/despawn and weld
  breaking is the least-proven area (its 2D sibling's architecture is proven at
  ~2 k+ active bodies). Mitigation: the stress benchmark measures a synthetic
  worst case before content depends on it.
- **Tier-transition pops** (static box → cluster boxes swap) may be visible.
  Mitigation: transitions only under damage events, masked by dust/particles.
- **Greedy decomposition churn:** repeated carves fragment chunks into more
  boxes over time. Mitigation: per-chunk re-decomposition keeps it bounded
  (≤ 512 cells); settled-rubble merging re-consolidates.
- **Stress feel vs. predictability** is a genuine design tension (Teardown
  chose none; RFG paid in authoring). The resolution here — certified
  structures plus a deterministic budgeted solve — is designed, not yet
  proven at content scale.

## Deeper reading

- Müller, Chentanez, Kim — *Real Time Dynamic Fracture with Volumetric
  Approximate Convex Decompositions* (SIGGRAPH 2013): the canonical real-time
  fracture paper behind the PhysX destruction lineage.
- Gabor Szauer — *Game Physics Cookbook* (constraint solvers, contact
  manifolds).
- NVIDIA Blast SDK source (github.com/NVIDIAGameWorks/Blast) — read
  first-hand; `NvBlastExtStressSolver.h` is the reference for budgeted
  graph-reduced stress solving.
- Eric Arnold — GDC 2011 RFG destruction talk (GDC Vault, paywalled): the
  highest-value unacquired source; the Rule A′/B framework matches its
  second-hand reconstruction, re-validated numerically here.

## Sources (survey)

Teardown: [80.lv voxel tech interview](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech) · [80.lv custom physics engine](https://80.lv/articles/see-what-s-new-in-teardown-creator-s-custom-voxel-physics-engine) · [Voxagon blog](https://blog.voxagon.se/) · [no structural integrity (Steam)](https://steamcommunity.com/app/1167630/discussions/0/2998794978529876575/) · [last-connected-voxel behavior](https://steamcommunity.com/app/1167630/discussions/0/2918850377439305091/) · [acko.net frame breakdown](https://acko.net/blog/teardown-frame-teardown/) · [debris lifecycle mods](https://www.nexusmods.com/teardown/mods/385)
Red Faction: [GeoMod 2.0 wiki](https://www.redfactionwiki.com/wiki/Geo-Mod_2.0) · [Eric Arnold Q&A](https://www.cbsnews.com/news/red-faction-guerrilla-q-a/) · [Building RF: Armageddon](https://www.gamedeveloper.com/design/the-destructible-world-building-i-red-faction-armageddon-i-)
Siege: [GDC 2016 talk](https://www.gdcvault.com/play/1023003/The-Art-of-Destruction-in) · [slides](https://ubm-twvideo01.s3.amazonaws.com/o1/vault/gdc2016/Presentations/LHeureux_Julien_Art_Of_Destruction.pdf) · [Ubisoft interview](https://news.ubisoft.com/en-us/article/4GHX2yepSaKkflLjLAlpwO/the-art-of-destruction-in-rainbow-six-siege-an-interview-with-julien-lheureux)
Frostbite/THE FINALS: [Battlefield Destruction wiki](https://battlefield.fandom.com/wiki/Destruction) · [SIGGRAPH 2010 destruction masking](https://www.slideshare.net/slideshow/siggraph10-arrdestruction-maskinginfrostbite2/4883521) · [GDC 2024 Engineering Mayhem](https://gdcvault.com/play/1034307/Engineering-Mayhem-Technical-Deep-Dive) + [slides](https://media.gdcvault.com/gdc2024/Slides/GDC+slide+presentations/Isaksson_Mans_Engineering+Mayham+Technical.pdf)
NVIDIA Blast (headers read first-hand): [repo](https://github.com/NVIDIAGameWorks/Blast) · [docs](https://nvidia-omniverse.github.io/PhysX/blast/index.html) · [ExtStress](https://docs.omniverse.nvidia.com/kit/docs/blast-sdk/latest/docs/api/extensions/ext_stress.html)
Brick Rigs: [building reference](https://shapes.inc/fandom/brick-rigs/vehicles-and-building) · Steam perf threads: [1](https://steamcommunity.com/app/552100/discussions/0/1480982971172125766/), [2](https://steamcommunity.com/app/552100/discussions/0/135513549089285521/), [3](https://steamcommunity.com/app/552100/discussions/0/1696045708643091995/)
ABRISS / IoD: [80.lv ABRISS](https://80.lv/articles/creating-an-atmospheric-physics-destruction-building-game-in-unity) · [IoD Destruction Tech Overview](https://steamcommunity.com/games/1428100/announcements/detail/3088910094668504531) · [IoD devlog video](https://www.youtube.com/watch?v=lXRfgeJg3r4)
Grid games (Space Engineers source read first-hand): [MyDisconnectHelper.cs](https://github.com/KeenSoftwareHouse/SpaceEngineers/blob/master/Sources/Sandbox.Game/Game/Entities/Cube/MyDisconnectHelper.cs) · [StructuralIntegrity sims](https://github.com/KeenSoftwareHouse/SpaceEngineers/tree/master/Sources/Sandbox.Game/Game/GameSystems/StructuralIntegrity) · [Medieval Engineers SI](https://medievalengineerswiki.com/w/Structural_Integrity) · [7DTD SI](https://7daystodie.wiki.gg/wiki/Structural_Integrity) · [Valheim stability](https://valheim.fandom.com/wiki/Building_stability) · [Besiege blocks](https://besiegetech.miraheze.org/wiki/Blocks)
Engine budgets: [Jolt PerformanceTest](https://github.com/jrouwe/JoltPhysics/blob/master/Docs/PerformanceTest.md) · [Jolt multicore scaling](https://jrouwe.nl/jolt/JoltPhysicsMulticoreScaling.pdf) · [Box2D 3.0 release](https://box2d.org/posts/2024/08/releasing-box2d-3.0/) · [box3d repo](https://github.com/erincatto/box3d) · [PhysX GPU rigid bodies](https://nvidia-omniverse.github.io/PhysX/physx/5.4.0/docs/GPURigidBodies.html) · [UE Chaos GDC 2019](https://dev.epicgames.com/community/learning/talks-and-demos/mXM/order-from-chaos-destruction-in-ue4-gdc-2019-unreal-engine)
Overviews: [GMTK "How Games Do Destruction"](https://gmtk.substack.com/p/how-games-do-destruction)
