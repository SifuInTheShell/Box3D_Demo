# Fire — research and simulation design

How games do fire propagation and what wood actually does, distilled into the
model implemented in `game/systems/fire/fire_sim.gd` and verified by
`fire_sim_test.gd` (27 headless checks). The goal is a real simulation rather
than timed decoration: fire ignites, spreads, weakens structures and consumes
its fuel.

---

## 1. How games do it (survey)

**Far Cry 2 (Dunia)** — the genre reference. A 2D grid over terrain for
grass plus a 3D grid for trees/objects; each cell holds combustion state
(unburnt → igniting → burning → burnt-out) and fuel from vegetation
density. Deliberately *no* fluid dynamics: "fast to simulate and easy to
understand." Wind biases spread direction; convection is faked as an uphill
bias (fire climbs faster than it descends); biome humidity and rain raise
ignition resistance; burn-out is the natural spread limiter. Flames/smoke
are pure VFX driven by cell state; scorch is a texture swap.

**Breath of the Wild ("chemistry engine")** — a rule-based state calculator
beside the physics engine. Two type classes: *elements* (fire, water, ice,
electricity, wind) and *materials* (wood, metal, grass). Three rules:
elements change material state; elements change element state (water kills
fire, wind carries fire); materials never change materials. Objects carry
material tags; elements attach to objects (a wooden club "has fire").
Predictability was the design goal — rules match real-world intuition.

**Teardown** — fire as discrete points attached to flammable voxels, hard
cap of ~100 simultaneous fires (culls oldest beyond ~200), flat spread
rate, fire slowly deletes the voxels it sits on. The lesson is budget
discipline: caps + cull + fuel exhaustion keep worst cases bounded.

**Consensus recipe for object-based (non-voxel) games:** per-object state
machine (`Cool → Heating → Burning → BurnedOut`) with `heat`,
`ignition_threshold`, `fuel`, `wetness`; a low-frequency global tick
(2–5 Hz, never per-frame); burning objects deposit heat into neighbours
(overlap query or cached graph) weighted by distance falloff, wind
alignment and an upward bias; fuel consumption self-limits; hard caps and
pooled VFX; sim decoupled from presentation. No mature Godot plugin exists
— rolling our own is expected and small.

## 2. What wood actually does (distilled physics)

- **Stages:** drying (moisture boils off ≤ ~150 °C, absorbing energy — wet
  wood ignites late) → pyrolysis (from ~200 °C the solid emits flammable
  gases; ~75% of mass loss) → flaming (the *gases* burn, ~1000 °C) →
  charring (an insulating black layer grows behind the front) →
  smoldering (char oxidizes flame-less for hours).
- **Spread anisotropy:** upward spread is ~10–100× downward (the plume
  preheats fuel above); lateral only ~1.3× downward. Wind tilts flames
  onto fresh fuel (wildfire forward rate ≈ 10% of wind speed); slope acts
  like wind (~2× per 10° upslope).
- **Structure:** timber chars at a near-constant ~0.65 mm/min (Eurocode 5).
  Char carries zero load; the cool core keeps full strength, so member
  strength ≈ residual cross-section. Thick beams last (a 130×530 beam
  ~50–65 min); a 2×4 stud fails in ~10–15 min. Heavy timber is genuinely
  hard to ignite — high thermal mass per surface — while kindling catches
  in seconds.
- **Ignition:** piloted ignition needs ≥ ~12 kW/m² sustained; direct flame
  contact is ~30–80 kW/m². Time-to-ignition falls steeply with flux.
- **Extinguishing:** fuel exhaustion, or water cooling the surface below
  pyrolysis temperature. Flaming wood needs ~1.3–3 g/m²·s of water but
  glowing char needs ~10 — under-dousing leaves **hot char that rekindles**.

## 3. Our model (`systems/fire/fire_sim.gd`)

Pure GDScript, no engine classes, no
RNG (deterministic; `state_hash()` for replay checks). Items are
axis-aligned fuel boxes; the engine layer mirrors body positions in and
reads states/events out.

Per item — the research's minimal state machine:

| Field | Meaning |
|---|---|
| `temp` | surface temperature (ambient 20, piloted ignition 300) |
| `moisture` | 0..1, boils off at a plateau before temp can climb |
| `char` | 0..1 of thickness consumed; linear while burning, never falls |
| `state` | `COLD → BURNING ⇄ SMOLDERING → BURNT_OUT` |
| `thickness` | 2× smallest half-extent: sets ignition inertia *and* burn duration |

Mechanics, each mapped from §1–§2:

- **Heat exchange:** burners emit `OUTPUT_K × area × intensity`; targets
  receive it with quadratic distance falloff, an upward multiplier
  (`UP_MULT` 7 straight up, `DOWN_MULT` 0.3 straight down — Far Cry's
  convection fake), a wind skew (`WIND_K` per m/s along the direction),
  and a contact-conduction bonus for touching items. Spatial hash keeps
  the scan near-linear.
- **Ignition inertia:** absorbed flux divides by `thickness` — kindling
  (fences, planks) catches in seconds, house beams only once a real fire
  surrounds them (multiple burners sum). Moisture boils off first.
- **Charring & strength:** `char += CHAR_RATE·dt / (thickness/2)`;
  `strength = (1−char)²` (residual cross-section). The engine layer maps
  strength onto fracture thresholds → burning walls weaken, then collapse.
  `CHAR_RATE` is ~100× real (0.0011 m/s vs 0.65 mm/min) — real timber
  fire-resistance minutes would be gameplay hours.
- **Burnout:** char = 1 → `BURNT_OUT`, zero strength, zero output — fuel
  exhaustion is the self-limiter, as in every surveyed game.
- **Douse/rekindle:** water removes temperature and adds moisture; a
  flaming item with real char drops to `SMOLDERING` (hot coals: low
  output, slow self-reheat toward reignition) — under-dousing rekindles,
  soaking (`MOISTURE_KILL`) puts coals out. Matches the char-rekindle
  hazard from §2 and gives the water system a real job.
- **Events:** `ignited / smolder / rekindled / burnout / cold` per step —
  the engine layer's cue to attach/detach FX and crumble burnt bodies.

Verified behaviors (the headless suite): threshold ignition, cooling of
unfed warmth, thin-before-thick, dry-before-wet, up > lateral > down,
downwind > upwind, firebreak gaps, contact conduction, monotonic
weakening, burnout stops both strength and spread, douse → smolder →
rekindle, soaked coals die, ordered fire-line travel along a fence,
moving fuel carries fire, bit-identical determinism, ash never reignites.

## 4. Engine layer (`game/lib/fire/`)

- `fire_system.gd` — the bridge (water's `water_fx.gd` pattern): sweeps
  the `flammable` group into the sim, mirrors positions, steps at 5 Hz,
  applies events — attach `burn_fx.gd` flames, weaken via
  `set_burn(char, strength)`, crumble on burnout; douses bodies that end
  up in water (`in_water` group). Explosions pour `add_heat` through the
  `fire_system` group; lingering ground fires (`fire_fx.gd`) radiate heat
  while they burn.
- `burn_fx.gd` — pooled per-body flames/smoke/glow scaled by sim
  intensity, hard-capped (Teardown's lesson) — the sim keeps running when
  the visual budget is exhausted.
- Wood is a material: `wall_panel.gd` / `breakable_block.gd` get a
  `flammable` flag; burning bodies hand fire to the debris they fracture
  into (born-burning pieces), so a collapsing burning wall seeds fires
  where it lands.
- `wood_gen.gd` builds the fuel: timber cabins (post frames, plank walls,
  plank roofs), fences (the propagation test track), log/lumber stacks.
  Wooden structures appear in the city (cabin lots, a lumber yard) and in
  the dedicated fire scene (key `4`): cabin row + connecting fences + a
  firebreak gap + a masonry control building, with ignite/douse tools.

## 5. Determinism note

The sim is RNG-free and FX jitter stays in the FX layer, with `fire_fx.gd`'s
RNG seeded so a full run stays reproducible.

## Sources

Game systems: gamedeveloper.com & jflevesque.com (Far Cry 2 fire, snippets),
pcgamer.com (FC2 retrospective), thumbsticks.com & gamesbeat.com (BotW GDC
2017 chemistry engine), teardown.fandom.com + Steam discussions (Teardown
fire caps), wayline.io (CA fire), arXiv 1905.09317 (Cell2Fire), 2403.08817
(probabilistic CA), gogamedev.itch.io (Godot fire VFX asset), Godot forum
98751. Wood physics: Springer 10.1007/s10694-009-0092-x (Eurocode 5 char
rates), USDA FPL (pyrolysis stages, ignition fluxes), PMC 9308566 (char
chemistry), ScienceDirect flame-spread topic, IAWF (10% wind rule), USFS
RMRS-P-46 (slope rule), Portland BDS appeal 13668 (beam failure minutes),
IAFSS fss_1-1145 (Rasbash: water extinction rates, rekindle).
