# Asset Pipeline

Where this project's assets come from, what their licenses allow, and the one
mandatory processing step between a downloaded photoscan and something a
physics scene can use. Constraints: CC0 only, glTF only, everything fetchable
by URL or scriptable from a terminal.

---

## 1. Sources and licensing

| Source | License | Used for |
|---|---|---|
| [Kenney](https://www.kenney.nl/assets) | CC0, whole catalog | impact/UI one-shots, particle sprites, low-poly stand-ins |
| [Quaternius](https://quaternius.com/) | CC0, commercial-OK | the rigged humanoid (one shared rig, glTF) |
| [Poly Haven](https://polyhaven.com/license) | CC0, whole catalog | photoscanned props, PBR facade textures, the HDRI sky |
| [ambientCG](https://ambientcg.com/) | CC0 | additional PBR materials; documented download API |
| [Freesound](https://freesound.org/apiv2/apply) | mixed — **filter to CC0** | ambience beds and spot sounds |
| [OpenGameArt](https://opengameart.org/content/all-cc0-uploader-kenney) | mixed — **filter to CC0** | no-auth fallback for CC0 ambience loops |

Two filtering rules that are easy to get wrong:

- **Freesound is a mixed corpus.** Queries must hard-filter
  `license:"Creative Commons 0"` (CC-BY and NC results appear by default).
  Token auth covers search plus **preview OGG download**; original-quality
  files need a one-time OAuth2 browser flow, which previews make unnecessary
  for ambience.
- **OpenGameArt is per-upload.** Only explicitly-CC0 packs qualify.

**Excluded on license grounds**, despite being otherwise ideal:

- **Mixamo** — the EULA prohibits redistributing raw character/animation
  files, which is exactly what committing exports to a public repo does.
  Quaternius covers the same need CC0-clean.
- **Sonniss #GameAudioGDC** — royalty-free EULA forbids redistributing files
  "as is"; raw `.wav`s in a public repo are arguably that.
- **BBC Sound Effects** — RemArc licence, non-commercial only.

The two non-CC0 assets that ship are credited where it is required: the C4
model is **CC-BY 3.0** and the CarConcept derby shell is **CC-BY 4.0** (both in
`game/lib/fx/models/CREDITS.md`). Every other
committed asset is itemized per file in that `CREDITS.md`,
`game/lib/fx/textures/CREDITS.md` and `game/lib/ambient/audio/CREDITS.md`.

**glTF only.** Godot 4's FBX import still has rig/retarget glitches, and every
source above ships a glTF variant anyway.

## 2. Procedural first, fetched second

Structures, street props and scenery are generated from primitives and
compound bodies in `game/lib/gen/`, and every fetched asset sits behind a
procedural fallback that is detected at load time. A fresh clone therefore
runs with no downloads, and `tools/fetch_polyhaven_assets.py` /
`tools/fetch_ambient_assets.py` only ever upgrade what is already working.
Same for audio: `tools/synth_ambience.py` writes seeded procedural beds under
the exact filenames the fetched CC0 takes would overwrite.

## 3. Fetch → decimate → compact GLB

**Raw Poly Haven photoscans are unusable as fetched.** Measured:
`pine_tree_01` is a 905 MB, multi-million-triangle mesh (`fir_tree_01`
456 MB; `quiver_tree_01` ~150 k tris / 88 k verts). Dropping dozens per scene
tanks frame rate, bloats the repo, and makes per-triangle geometry splitting
hitch (~260–350 ms per tree). So every heavy realistic asset goes through
headless Blender first — `blender -b file.blend --python script.py` runs fully
offscreen and the glTF 2.0 exporter works in background mode:

1. Fetch the 1k glTF (`tools/fetch_polyhaven_assets.py`) into a work dir.
2. Import the glTF, `object.transform_apply`, add a **Decimate (COLLAPSE)**
   modifier and preview ratios non-destructively against a viewport render.
   `~0.025` took 150 k → **3,753 tris** with silhouette and materials intact
   (97.5 % reduction, still clearly the same tree).
3. **Keep every material slot** (e.g. `_trunk` / `_leaf`) — the fracture code
   splits geometry per surface, so collapsing slots breaks it.
4. Apply the modifier and export `GLB` with `use_selection`.
5. Scan the filesystem in Godot to import. The glTF importer extracts the
   embedded textures next to the `.glb` (hence the `*_1k.jpg/png` files), and
   scenes reference the extracted files — so those maps must stay committed.
6. Wire it in with `keep_materials = true` so the photoscanned PBR survives; a
   flat tint override is for stylized fallbacks only.

**Budget:** ~2–4 k tris for anything instanced many times per scene; one
shared GLB (~5 MB with 1k textures) is loaded once and instanced. After
decimation the geometry split costs ~24 ms instead of 260–350 ms.

Headless Blender is also the right tool for the adjacent chores: batch
FBX/OBJ → glTF conversion, collision-hull generation, and Cell Fracture
(`--background --python`) for pre-fracturing hero props. Caveat: writing `bpy`
blind means verifying by re-import or a preview render
(`blender -b -o //preview -f 1`) — budget for that loop.
