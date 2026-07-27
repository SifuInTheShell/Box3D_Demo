# Glass — research and simulation design

How games break glass and what real glass does, distilled into the model
implemented in `game/systems/glass/glass_sim.gd` and verified by
`glass_sim_test.gd` (25 headless checks). Panes earn a system of their own for
two reasons: they carry the most spectacular shatter VFX in the project, and
they are the most readable **blast-radius indicator** — real blast waves break
windows at several times the structural-damage radius, so a careless charge
announces itself by raining glass off every building around it.

---

## 1. How games do it (survey)

- **Panes are a special-cased 2D problem.** Nobody runtime-fractures glass
  as a solid: because a pane is thin, fracture is computed in the pane
  plane (2D Voronoi or procedural radial pattern seeded at the impact
  point) and extruded by the thickness into prism shards. Rainbow Six
  Siege's RealBlast cuts thin surfaces procedurally per hit and replicates
  only the impact parameters (deterministic fracture as *gameplay*);
  Half-Life-2-era games swap to pre-fractured meshes.
- **Radial + concentric reads as glass.** Real panes crack radially from
  the hit with concentric rings crossing them — games fake it with ring-
  distributed Voronoi sites or a polar/crowded grid, dense near the impact.
- **Two blast radii.** GTA / Battlefield / Mafia give explosions a
  structural radius and a 2–4× larger fragile-object radius that only
  breaks glass and lights; Teardown gets the same from glass having the
  lowest material strength. This *is* our indicator mechanic, confirmed.
- **The feel is FX, not physics.** Shards are cosmetic (world-only
  collision), 8–30 per pane, alive 2–8 s then faded; a glitter particle
  burst and layered audio sell the moment more than shard accuracy.
  Far-away panes skip shards entirely. Global shard caps (~100–300,
  evict oldest) keep worst cases bounded.
- **Godot:** Stand43's `godot_breakable_glass_custom` (radial+ring pattern,
  layer-swapped shards) is the closest reference implementation; a
  screen-space crack shader (Lord0Sanz) covers a future "cracked but not
  broken" first stage.

## 2. What glass actually does (distilled physics)

- **Blast overpressure is the star.** Windows are the weakest blast-loaded
  element of any building: occasional annealed breakage from ~0.7–1.7 kPa
  side-on overpressure, most panes gone by 3.5–7 kPa — while structural
  damage to houses only *begins* near 7 kPa. Distance scaling is
  Hopkinson–Cranz (Z = R/W^⅓) with simple polynomial fits (Newmark–Hansen
  family) for P(Z).
- **Impact:** annealed glass fails from surface-flaw tension at a few
  joules (a stone at ~10 m/s) into long dagger shards; tempered is ~4–5×
  stronger and dices into blunt cubes; laminated cracks but hangs in the
  frame. (We model annealed; tempered/laminated are future pane types.)
- **Thermal (fires):** the flame-heated centre fights the frame-shaded
  cool edge; annealed panes crack at a ΔT of ~50–90 °C — minutes into a
  compartment fire — and fall out shortly after, creating new vents.
  Tempered needs ~300 °C.
- **Vibration:** ground-borne PPV at demolition-legal levels (12–51 mm/s
  USBM limits) essentially never breaks windows — real "blasting broke my
  window" complaints are airblast. So the PPV model stays about ground
  vibration and the overpressure channel owns glass.

## 3. Our model (`systems/glass/glass_sim.gd`)

Pure GDScript, engine-free, RNG-free, same interface shape as FireSim. Panes
are points with area and a **tag** (`target` / `protected` / `neutral`); the
**ledger** tallies broken count, area and cause per tag, which is what HUDs and
headless checks read.

- **Blast:** `P(Z) = 1772/Z³ − 114/Z² + 108/Z` kPa (Kingery-style far-field
  fit), pane breaks at `BREAK_KPA`. Real thresholds (0.7–7 kPa) would
  shatter the entire scene on any charge at our compact scale, so the
  threshold sits above the real band (11 kPa) to preserve the *ratio*:
  small/medium/large gym charges break glass to ~18/34/52 m vs their
  3.5/6.5/10 m structural radii — a 3–5× warning ring, per the survey's
  two-radius convention. `break_distance(w)` exposes that ring as a query.
  Broken panes return nearest-first so the engine layer can stagger
  the shatters into a visible radial wave.
- **Impact:** contact past 2.2 m/s relative speed (annealed fragility;
  the engine layer detects the collision, the sim keeps the ledger).
- **Heat:** fires pour pulses via `add_heat` (FireSim's falloff); pane
  temperature integrates with Newton cooling between pulses and the pane
  pops at ΔT = 150 °C — burning buildings blow their own windows out.
- **Shatter pattern:** `shatter_pattern(size, impact, energy)` splits the
  pane face into shard rects on a grid crowded toward the impact point
  (finer wedges near the hit, big plates far away — §2's pattern), tiling
  the area exactly; the engine layer jitters them into glass-looking
  shards. Verified: exact tiling, in-bounds, count scales with energy,
  finer near impact, deterministic.

## 4. Engine layer (`game/lib/glass/`)

- `glass_pane.gd` — a thin transparent Box3DBody (group `glass`): breaks on
  fast contact, on the explosion fracture sweep, and on command from the
  system; shatters into flat jittered shards (world-lifetime-capped,
  survey budgets) plus a glitter burst (`glass_fx.gd`).
- `glass_system.gd` — the bridge (fire_system's pattern): sweeps panes into
  the sim, mirrors positions, forwards explosion `blast_wave`s (radius →
  TNT mass via BlastPlan's calibration), staggers the radial shatter wave,
  pours fire heat onto nearby panes, cleans up old shards, and serves the
  ledger to HUDs.
- **Buildings get glazed:** `building_gen.gd` fits a pane into every window
  opening and carries a per-building `glass_tag`, so every break is
  attributable to the structure it came from.
- **Fire scene additions:** timber cabins get a front window (burning cabins
  pop their own glass), plus a free-standing pane rack next to the lumber
  yard for point-blank shatter tests.

## 5. Future stages (deliberately deferred)

A first `cracked` stage before `broken` exists as a cosmetic craze (a
sub-shatter hit crazes a pane without breaking it); a full screen-space crack
shader, tempered and laminated pane types (dicing / hanging shards), and shard
pooling if profiling ever demands it, do not.

## Sources

Game techniques: ResearchGate real-time fracturing survey, DiVA 2D-Voronoi
pane-fracture thesis, GDC 2016 "The Art of Destruction" (Siege RealBlast),
Frostbite destruction-masking deck, Battlefield wiki, Teardown wiki +
Better Glass mod, Stand43 godot_breakable_glass_custom, Lord0Sanz glass
crack shader, US patent 10950010 (dynamic destructive detail), pooling
articles. Physics: Bluefield/UNICEF blast-protection tables (overpressure
thresholds), thescipub/Shodhganga (Newmark–Hansen scaling), ScienceDirect +
IAFSS (thermal ΔT breakage, BREAK1), PA DEP / USBM RI 8507 (PPV limits).
