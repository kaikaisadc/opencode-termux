#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-wrapper pacman package (glibc appendix line).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"

[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing OpenCode runtime"
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher"
	exit 1
}
pkg_version_from_runtime "$STAGED_PREFIX/lib/opencode/runtime/opencode"

pkg_pacman_prepare PKGBUILD opencode-wrapper
# Bin-only: ship ONLY usr/bin/opencode (no full-prefix copy)
# The PKGBUILD template is already edited for bin-only; these sed commands
# enforce it on the temp copy as a safety net.
sed -i '/^package() {/,/^}/c\package() {\n  mkdir -p "$pkgdir/usr/bin"\n  install -D -m755 "${_staged_prefix}/bin/opencode" "$pkgdir/usr/bin/opencode"\n}' "$TMP_PKGBUILD" 2>/dev/null || true
# Remove hook scripts that reference dropped files (run-system-skills.sh)
sed -i '/^post_install() {/,/^}/d; /^post_upgrade() {/,/^}/d; /^pre_remove() {/,/^}/d; /^post_remove() {/,/^}/d' "$TMP_PKGBUILD" 2>/dev/null || true

pkg_pacman_run STAGED_PREFIX="$STAGED_PREFIX"

echo "Pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/opencode-wrapper-${VERSION}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
pkg_pacman_guard "$BUILT_PKG"
