#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_pacman_standalone.sh — build the opencode-wrapper-standalone pacman package
# Pure-addition standalone package: frozen single version for rollback only.
# Coexists with `opencode` (native) and `opencode-wrapper` (no Conflicts on the
# literal name `opencode`). Uses PKGBUILD.standalone.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix-standalone}"

# Standalone staged prefix must use the independent lib prefix.
[[ -x "$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode" ]] || {
	echo "Error: missing OpenCode standalone runtime"
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode-wrapper" ]] || {
	echo "Error: missing standalone staged launcher"
	exit 1
}
pkg_version_from_runtime "$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode"

pkg_pacman_prepare PKGBUILD.standalone opencode-wrapper-standalone

pkg_pacman_run STAGED_PREFIX="$STAGED_PREFIX"

echo "Pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/"*-standalone-* 2>/dev/null || ls "$ROOT_DIR/packing/pacman/"*-compressed-* 2>/dev/null || true)
pkg_pacman_guard "$BUILT_PKG" '^data/.*/(bin|lib)/'
