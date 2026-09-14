#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-native pacman provider (transplant revival line).
#
# Provides the `opencode` command from artifacts/transplant/<ver>/opencode-native-revived.
# Stable mainline provider; conflicts with the glibc appendix package (`opencode-wrapper`);
# conflicts with it (installing one replaces the other).
# Native constraints: zero glibc deps, Android API >= 28, full TUI (stable mainline since 27/28).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkg_version_from_transplant
pkg_native_bin

pkg_pacman_prepare PKGBUILD.native opencode-native

pkg_pacman_run OPENCODE_NATIVE_BIN="$NATIVE_BIN"

echo "Native pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/opencode-${VERSION}-${PKGREL}-aarch64.pkg.tar.xz" 2>/dev/null || true)
pkg_pacman_guard "$BUILT_PKG"
