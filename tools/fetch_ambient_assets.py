#!/usr/bin/env python3
"""Fetch the ambient layer's CC0 assets by manifest.

Needs open network access to the asset hosts. Nothing here is required to run
the project: the repo ships procedural placeholders (tools/synth_ambience.py)
and every fetched asset sits behind a procedural fallback. The manifest:

  audio       Freesound CC0 previews + OpenGameArt CC0 loops into
              game/lib/ambient/audio/ (overwriting the synth placeholders
              1:1 — same filenames, no code changes).
  characters  Quaternius Universal Base Characters (CC0, glTF) -- non-blocky,
              proportioned low-poly. Manual download (see the printed link);
              Kenney Mini Characters were dropped (too blocky/Minecraft).
  vehicles    Kenney Car Kit (CC0, glTF, separate wheels + debris).
  animals     Quaternius animated animals via poly.pizza API (CC0).
  props       Poly Haven bench/streetlamp/cafe-set/bicycle (CC0) into
              tools/asset_work/ — these are 7-15k tris and MUST go through
              the Blender decimate step (docs/research/asset-pipeline.md §3)
              before res:// wiring; this script only fetches.

License discipline: everything fetched is CC0-verified at the source at
fetch time; Freesound queries hard-filter license:"Creative Commons 0".
Excluded by policy (docs/research/asset-pipeline.md §1): Mixamo, Sonniss, BBC.

Usage:
  python3 tools/fetch_ambient_assets.py audio --freesound-token TOKEN
  python3 tools/fetch_ambient_assets.py characters vehicles animals props
  python3 tools/fetch_ambient_assets.py all --freesound-token TOKEN

Freesound token: create at https://freesound.org/apiv2/apply (token auth
is enough for search + preview download; previews are ample for beds).
NOTE: written in a container that cannot reach these hosts — endpoints
follow each service's published API docs but expect to shake out small
breakages on first real run.
"""

import argparse
import json
import re
import shutil
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUDIO_DIR = ROOT / "game" / "lib" / "ambient" / "audio"
WORK_DIR = ROOT / "tools" / "asset_work"

UA = {"User-Agent": "footprint-asset-fetch/1.0"}


def _get(url: str, dest: Path | None = None) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    if dest is not None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        print(f"  {dest.relative_to(ROOT)}  {len(data) / 1024:.0f} KiB")
    return data


# ---- audio -------------------------------------------------------------------

# What ambience_audio.gd loads; queries tuned for Freesound's tagging.
# (query, is_bed): beds are long ambience loops and need a wide duration
# window; the rest are short one-shots. Queries stay broad so the hard CC0
# filter still returns hits (over-specific phrases came back empty).
FREESOUND_WANTS = {
    "street":      ("city street traffic ambience", True),
    "rural":       ("countryside nature birds ambience", True),
    "birdsong_1":  ("bird chirp", False),
    "birdsong_2":  ("blackbird song", False),
    "birdsong_3":  ("sparrow chirp", False),
    "dog_1":       ("dog bark", False),
    "chatter_1":   ("crowd murmur walla", False),
    "rooster_1":   ("rooster crow", False),
    "wind_gust_1": ("wind gust trees", False),
    "car_pass_1":  ("car passing by", False),
}


def _freesound_pick(query: str, is_bed: bool, token: str):
    """Top CC0 hit for a query; retries with a 2-word fallback before None."""
    dur = "[8 TO 300]" if is_bed else "[0.3 TO 30]"
    for q in (query, " ".join(query.split()[:2])):
        params = urllib.parse.urlencode({
            "query": q,
            "filter": f'license:"Creative Commons 0" duration:{dur}',
            "sort": "rating_desc",
            "fields": "id,name,username,previews,license,url",
            "page_size": 3,
            "token": token,
        })
        data = json.loads(_get(f"https://freesound.org/apiv2/search/text/?{params}"))
        if data.get("results"):
            return data["results"][0]
    return None


def fetch_audio(token: str) -> None:
    if not token:
        sys.exit("audio needs --freesound-token (https://freesound.org/apiv2/apply)")
    print("[audio] Freesound CC0 previews")
    credits = ["# fetched by fetch_ambient_assets.py", ""]
    for name, (query, is_bed) in FREESOUND_WANTS.items():
        try:
            hit = _freesound_pick(query, is_bed, token)
            if hit is None:
                raise ValueError("no CC0 result")
            _get(hit["previews"]["preview-hq-ogg"], AUDIO_DIR / f"{name}.ogg")
            credits.append(f"| {name}.ogg | {hit['url']} (by {hit['username']}) | CC0 |")
        except Exception as e:  # keep fetching the rest
            print(f"  {name}: FAILED ({e}) - placeholder stays")
    print("\nAppend to game/lib/ambient/audio/CREDITS.md:")
    print("\n".join(credits))


# ---- models ------------------------------------------------------------------

KENNEY_PAGES = {
    # kenney.nl serves each zip from a content-hashed /media/pages/ path that
    # changes on every asset update, so we scrape the current link off the
    # asset page rather than hardcode it (the hardcoded form 404s over time).
    "car-kit": "https://kenney.nl/assets/car-kit",
}

# Kenney Mini Characters were dropped (too blocky). Quaternius characters are
# the non-blocky CC0 replacement, but download is manual (Drive/gumroad).
QUATERNIUS_CHARACTERS = "https://quaternius.com/packs/ultimatedanimatedcharacter.html"


def fetch_kenney(which: str) -> None:
    page = KENNEY_PAGES[which]
    dest = WORK_DIR / "kenney" / f"{which}.zip"
    print(f"[kenney] {which} (CC0)")
    try:
        html = _get(page).decode("utf-8", "replace")
        m = re.search(r"https://kenney\.nl/media/pages/assets/"
                      + re.escape(which) + r"/[^\"']+\.zip", html)
        if not m:
            raise ValueError("no .zip link found on the asset page")
        _get(m.group(0), dest)
        with zipfile.ZipFile(dest) as z:
            # Zip-slip guard: refuse member paths that escape the target dir.
            target = (dest.parent / which).resolve()
            for mem in z.namelist():
                if not (target / mem).resolve().is_relative_to(target):
                    raise ValueError(f"zip member escapes target dir: {mem}")
            z.extractall(target)
        print(f"  extracted -> {dest.parent / which}; wire the glTF variants "
              "(Godot-friendly) into res:// by hand")
    except Exception as e:
        print(f"  FAILED ({e}); download manually from {page}")


QUATERNIUS_MANUAL = "https://quaternius.com/packs/ultimateanimatedanimals.html"


def fetch_animals(token: str = "") -> None:
    """Quaternius animated animals (CC0). poly.pizza's API now requires a key;
    without one the pack is a hand download (Google-Drive link on the page)."""
    print("[animals] Quaternius (CC0)")
    if not token:
        print("  poly.pizza API now needs a key (free: https://poly.pizza/api),")
        print(f"  or fetch the CC0 pack by hand from {QUATERNIUS_MANUAL}")
        print("  -> tools/asset_work/animals/")
        return
    try:
        # poly.pizza v1.1: key in x-auth-token; Animated is a number (1), and
        # result fields are Capitalised (Title/Download/Creator/Licence).
        req = urllib.request.Request(
            "https://api.poly.pizza/v1.1/search/Animal?Animated=1",
            headers={**UA, "x-auth-token": token})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read())
        picks = [m for m in data.get("results", [])
                 if (m.get("Creator") or {}).get("Username", "").lower() == "quaternius"
                 and (m.get("Licence") or "").upper().startswith("CC0")][:8]
        for m in picks:
            url = m.get("Download")
            if url:
                title = (m.get("Title") or "animal").replace(" ", "_")
                _get(url, WORK_DIR / "animals" / f"{title}.glb")
    except Exception as e:
        print(f"  FAILED ({e}); manual: {QUATERNIUS_MANUAL}")


POLYHAVEN_PROPS = ["outdoor_table_chair_set_01"]  # + browse categories below


def fetch_props() -> None:
    """Poly Haven props — fetch only; decimate in Blender before wiring."""
    print("[props] Poly Haven (CC0) — MUST be decimated before res:// use")
    for cat in ["seating", "lighting"]:
        try:
            listing = json.loads(_get(
                f"https://api.polyhaven.com/assets?type=models&categories={cat}"))
            print(f"  {cat}: {', '.join(list(listing)[:10])}")
        except Exception as e:
            print(f"  {cat} listing FAILED ({e})")
    for slug in POLYHAVEN_PROPS:
        try:
            files = json.loads(_get(f"https://api.polyhaven.com/files/{slug}"))
            gltf = files["gltf"]["1k"]["gltf"]
            _get(gltf["url"], WORK_DIR / "polyhaven" / slug / Path(gltf["url"]).name)
            for relpath, extra in gltf.get("include", {}).items():
                # keep the glTF's own relative layout (its textures/ subdir) so
                # the .gltf loads with materials in Blender/Godot with no hand-fix.
                _get(extra["url"], WORK_DIR / "polyhaven" / slug / relpath)
        except Exception as e:
            print(f"  {slug} FAILED ({e})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", nargs="+",
            choices=["audio", "characters", "vehicles", "animals", "props", "all"])
    ap.add_argument("--freesound-token", default="")
    ap.add_argument("--polypizza-token", default="")
    args = ap.parse_args()
    what = set(args.what)
    if "all" in what:
        what = {"audio", "characters", "vehicles", "animals", "props"}
    if "audio" in what:
        fetch_audio(args.freesound_token)
    if "characters" in what:
        print("[characters] Kenney Mini Characters dropped (too blocky). Use "
              "Quaternius (non-blocky CC0), a manual download:")
        print(f"  {QUATERNIUS_CHARACTERS}  -> tools/asset_work/characters/")
    if "vehicles" in what:
        fetch_kenney("car-kit")
    if "animals" in what:
        fetch_animals(args.polypizza_token)
    if "props" in what:
        fetch_props()
    if shutil.which("blender") is None and "props" in what:
        print("\nNOTE: no blender on PATH — the decimate step "
              "(docs/research/asset-pipeline.md §3) still stands between "
              "fetched props and res:// wiring.")


if __name__ == "__main__":
    main()
