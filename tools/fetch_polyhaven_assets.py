#!/usr/bin/env python3
"""Fetch the curated Poly Haven asset manifest (CC0, glTF 1k) into the demo.

Run from the repo root on a machine with open network access:

    python tools/fetch_polyhaven_assets.py

Idempotent: files whose md5 already matches are skipped. Downloads the 1k
texture resolution (right for gameplay props; bump RES for hero shots).
Appends a credits block to CREDITS.md once.

Sources, licensing and the mandatory decimate step: docs/research/asset-pipeline.md.
"""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

API = "https://api.polyhaven.com/files/{slug}"
RES = "1k"
DEST = Path(__file__).resolve().parent.parent / "game" / "lib" / "fx" / "models" / "realistic"
CREDITS = Path(__file__).resolve().parent.parent / "game" / "lib" / "fx" / "textures" / "CREDITS.md"

# slug -> human note (all CC0, https://polyhaven.com/a/<slug>)
#
# IMPORTANT: Poly Haven's photoscanned TREES are NOT usable as fetched and are
# not in this manifest. They are multi-million-tri meshes -- pine_tree_01 alone
# is a 905 MB .bin, fir_tree_01 456 MB -- so placing dozens per scene would
# destroy performance and bloat the repo. A tree only ships after the Blender
# decimate step (research/asset-pipeline.md §3, e.g. trees/quiver_tree.glb at
# ~3.7k tris); everything else stays procedural or low-poly. Only lightweight
# scan props/decor are fetched here.
MANIFEST = {
    # Static decor (small)
    "tree_stump_01": "cut stump (static decor)",
    # Demolition-site & street props
    "concrete_road_barrier": "checker-painted concrete barrier",
    "concrete_road_barrier_02": "weathered concrete barrier",
    "modular_chainlink_fence": "site perimeter fencing",
    "fire_hydrant": "street hydrant",
    "wooden_crate_01": "vintage wooden crate",
    "wooden_crate_02": "vintage wooden crate variant",
    "Barrel_02": "blue plastic industrial drum",
    "barrel_03": "steel drum",
    "wooden_barrels_01": "wooden barrel group",
    "ladder_sectioned_01": "folding site ladder",
    "planter_box_02": "street planter",
}


# Poly Haven's API rejects the default "Python-urllib/x.y" User-Agent with a
# 403, which the old code misread as "no glTF listing". Send a real UA.
UA = "physics-game-asset-fetch/1.0 (+https://polyhaven.com)"


def _open(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_json(url):
    with _open(url, 60) as r:
        return json.load(r)


def download(url, dest: Path, md5: str | None) -> str:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and md5:
        if hashlib.md5(dest.read_bytes()).hexdigest() == md5:
            return "skip"
    with _open(url, 300) as r:
        data = r.read()
    if md5 and hashlib.md5(data).hexdigest() != md5:
        raise RuntimeError(f"md5 mismatch for {url}")
    dest.write_bytes(data)
    return "ok"


def fetch_asset(slug: str) -> bool:
    for candidate in (slug, slug.lower()):
        try:
            files = fetch_json(API.format(slug=candidate))
            break
        except Exception:
            files = None
    if files is None or "gltf" not in files:
        print(f"  !! {slug}: no glTF listing (check slug)")
        return False
    by_res = files["gltf"]
    res = RES if RES in by_res else sorted(by_res)[0]
    entry = by_res[res]
    main = entry.get("gltf", entry)
    root = DEST / slug
    n = 0
    status = download(main["url"], root / main["url"].rsplit("/", 1)[-1],
                      main.get("md5"))
    n += status == "ok"
    for rel, meta in (main.get("include") or {}).items():
        status = download(meta["url"], root / rel, meta.get("md5"))
        n += status == "ok"
    print(f"  ok {slug} ({res}, {n} new files)")
    return True


def append_credits():
    marker = "## Poly Haven realistic models"
    text = CREDITS.read_text() if CREDITS.exists() else ""
    if marker in text:
        return
    lines = [f"\n{marker}\n",
             "\nModels under `models/realistic/` come from **Poly Haven**\n",
             "(https://polyhaven.com), license **Creative Commons CC0**:\n"]
    for slug, note in MANIFEST.items():
        lines.append(f"- `{slug}` — {note} (https://polyhaven.com/a/{slug})\n")
    CREDITS.write_text(text + "".join(lines))
    print("credits appended")


def main():
    ok = 0
    for slug in MANIFEST:
        print(f"fetching {slug}…")
        ok += fetch_asset(slug)
    append_credits()
    print(f"\n{ok}/{len(MANIFEST)} assets present. Re-open the Godot editor "
          "(or run --headless --import) so the .gltf files import.")
    return 0 if ok == len(MANIFEST) else 1


if __name__ == "__main__":
    sys.exit(main())
