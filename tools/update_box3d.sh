#!/usr/bin/env bash
# Update the vendored Box3D engine from Erin Catto's upstream repo, rebuild
# the GDExtension (which includes OUR extended wrapper in godot/src -- the
# near-complete C-API binding), and deploy the fresh library into game/bin/.
#
#   tools/update_box3d.sh              pull upstream + rebuild + deploy
#   tools/update_box3d.sh --no-pull    rebuild + deploy only (wrapper changes)
#
# The sync follows the fork's additive discipline: ONLY upstream-owned paths
# (src/, include/, test/, samples/, shared/, extern/, benchmark/, data/,
# docs/, root build files) are replaced. Everything custom -- godot/ with the
# extended wrapper, README.md, .gitignore -- is never touched, so
# an upstream pull can never lose our binding.
#
# If the build FAILS after a pull, upstream changed its C API and the wrapper
# in extern/box3d-godot/godot/src needs a matching patch (see
# docs/box3d-build-and-use.md). Nothing is deployed on failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$REPO_ROOT/extern/box3d-godot"
GAME_BIN="$REPO_ROOT/game/bin"
UPSTREAM_URL="${BOX3D_UPSTREAM:-https://github.com/erincatto/box3d}"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Upstream-owned paths (replaced wholesale on sync). Anything not listed
# here survives untouched.
UPSTREAM_DIRS=(src include test samples shared extern benchmark data docs)
UPSTREAM_FILES=(CMakeLists.txt CMakePresets.json build.sh deploy_docs.sh
	build_vs2022.bat build_vs2026.bat CONTRIBUTING.md LICENSE)

PULL=1
[[ "${1:-}" == "--no-pull" ]] && PULL=0

if [[ $PULL -eq 1 ]]; then
	echo "==> Pulling latest erincatto/box3d ($UPSTREAM_URL)"
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	git clone --depth 1 "$UPSTREAM_URL" "$TMP/box3d"
	COMMIT="$(git -C "$TMP/box3d" rev-parse --short HEAD)"
	echo "==> Upstream at $COMMIT -- replacing upstream-owned paths"
	for d in "${UPSTREAM_DIRS[@]}"; do
		if [[ -d "$TMP/box3d/$d" ]]; then
			rm -rf "${VENDOR:?}/$d"
			cp -a "$TMP/box3d/$d" "$VENDOR/$d"
		fi
	done
	for f in "${UPSTREAM_FILES[@]}"; do
		[[ -f "$TMP/box3d/$f" ]] && cp -a "$TMP/box3d/$f" "$VENDOR/$f"
	done
	echo "$COMMIT" > "$VENDOR/UPSTREAM_COMMIT"
	echo "==> Vendored tree now tracks upstream $COMMIT (recorded in extern/box3d-godot/UPSTREAM_COMMIT)"
fi

echo "==> Building the GDExtension (debug + release, -j$JOBS)"
command -v scons >/dev/null || { echo "scons not found -- pip install scons"; exit 1; }
cd "$VENDOR/godot"
scons -j"$JOBS"
scons -j"$JOBS" target=template_release

echo "==> Deploying into game/bin/"
shopt -s nullglob
LIBS=(demo/bin/libbox3d_godot.linux.*.so demo/bin/libbox3d_godot.macos.*)
[[ ${#LIBS[@]} -eq 0 ]] && { echo "no built libraries found in demo/bin -- build failed?"; exit 1; }
cp -av "${LIBS[@]}" "$GAME_BIN/"

# game/bin/box3d.gdextension ships Windows-only; make sure this platform's
# entries exist (appending lands inside the trailing [libraries] section).
MANIFEST="$GAME_BIN/box3d.gdextension"
if ! grep -q "^linux.debug.x86_64" "$MANIFEST"; then
	{
		echo ""
		echo "linux.debug.x86_64 = \"res://bin/libbox3d_godot.linux.template_debug.x86_64.so\""
		echo "linux.release.x86_64 = \"res://bin/libbox3d_godot.linux.template_release.x86_64.so\""
	} >> "$MANIFEST"
	echo "==> Added Linux entries to box3d.gdextension"
fi

echo ""
echo "Done. Suggested verification before committing:"
echo "  godot --headless --path game -s systems/fire/fire_sim_test.gd    (and the other suites)"
echo "  godot --headless --path extern/box3d-godot/godot/demo --import   (then the demo selftests)"
echo "Windows DLLs must be rebuilt separately: tools\\update_box3d.bat on the Windows machine."
