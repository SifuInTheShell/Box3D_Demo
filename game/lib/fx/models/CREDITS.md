# Model credits

Every mesh under `models/`, itemized. CC0 needs no attribution but gets it
anyway; the CC-BY item's attribution is REQUIRED and is provided here.

## CC-BY (attribution required)

- `c4.glb` — **"C4" by J-Toastie** (https://poly.pizza/m/sDrFzJlbxy),
  **CC-BY 3.0**.
- `vehicles/car_concept.glb` — **"CarConcept" by Darmstadt Graphics Group GmbH**
  (Khronos glTF-Sample-Assets), **CC-BY 4.0**. Detailed concept car used as the
  derby body shell; interior/engine stripped, decimated 213k -> 34k tris and
  glass re-tinted in Blender, re-exported self-contained.

## Poly Haven (https://polyhaven.com, CC0)

Photoscans fetched at 1k and decimated headlessly in Blender to game budgets
(`docs/research/asset-pipeline.md` §3), re-exported as compact self-contained
GLBs.

- `props/wooden_crate.glb` — slug `wooden_crate_01`
- `props/fire_hydrant.glb` — slug `fire_hydrant` (+ aged material variant)
- `trees/quiver_tree.glb` — slug `quiver_tree_01` (decimated ~150k -> ~3.7k tris)
- `../sky/kloofendal_48d_partly_cloudy_puresky_2k.hdr` — slug
  `kloofendal_48d_partly_cloudy_puresky` (HDRI)

## Quaternius (https://quaternius.com, CC0)

- `humans/man.glb` — "Man", rigged low-poly character; skinned onto the
  physics ragdoll by `lib/bodies/human_ragdoll.gd`.

### Cars Bundle (https://poly.pizza, CC0)

Low-poly cars driven by the demolition derby (`lib/bodies/car_rig.gd`): the
body is sliced into the rig's tear-off panels and the model's own wheels ride
the physics suspension.

- `vehicles/sports_car.glb` — "Sports Car" (https://poly.pizza/m/1mkmFkAz5v)
- `vehicles/car.glb` — "Car" (https://poly.pizza/m/Cz6yDaUcM9)
- `vehicles/police_car.glb` — "Police Car" (https://poly.pizza/m/BwwnUrWGmV)
- `vehicles/taxi.glb` — "Taxi" (https://poly.pizza/m/x43lOScTpN)
- `vehicles/suv.glb` — "SUV" (https://poly.pizza/m/xsMtZhBkxL)
- `vehicles/sports_car_2.glb` — "Sports Car" (https://poly.pizza/m/OyqKvX9xNh)
- `vehicles/car_2.glb` — "Car" (https://poly.pizza/m/unqqkULtRU)
