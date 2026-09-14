#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-compressed pacman provider (UPX-packed native variant).
#
# D1 ruling: three mutually exclusive providers — opencode (native mainline),
# opencode-wrapper (glibc appendix), opencode-compressed. This package provides
# the versioned virtual name opencode=<ver> and conflicts with BOTH other
# families; no replaces=() (variant, not upgrade).
#
# Input: the UPX-packed ELF produced by T3
#   artifacts/transplant/<ver>/opencode-native-revived-upx

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkg_version_from_transplant
pkg_compressed_bin
# Normalize to absolute paths BEFORE pkg_pacman_prepare cd-s into packing/pacman:
# makepkg's package() resolves these from the makepkg cwd, so a relative path
# would fail there (T5 real-build finding).
COMPRESSED_BIN="$(readlink -f "$COMPRESSED_BIN")"
OPENCODE_CRHANDLER_SO="$(readlink -f "${OPENCODE_CRHANDLER_SO:?OPENCODE_CRHANDLER_SO must point to libopencode-crhandler.so}")"

pkg_pacman_prepare PKGBUILD.compressed opencode-compressed
# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
printf "\nPKGEXT='.pkg.tar.gz'\n" >>"$TMP_MAKEPKG_CONF"

pkg_pacman_run OPENCODE_COMPRESSED_BIN="$COMPRESSED_BIN"

echo "Compressed pacman package created under: $ROOT_DIR/packing/pacman"

# --- Regression guard: reject packages with data/ payload paths (double-prefix bug) ---
BUILT_PKG=$(ls "$ROOT_DIR/packing/pacman/"opencode-compressed-"$VERSION"-"$PKGREL"-*.pkg.* 2>/dev/null || true)
pkg_pacman_guard "$BUILT_PKG"

# crhandler guard (unconditional): the package MUST contain the shim.
if [[ -n "$BUILT_PKG" ]]; then
	if ! bsdtar -tf "$BUILT_PKG" | grep -q 'usr/lib/opencode/libopencode-crhandler.so'; then
		echo "FATAL: package does not ship libopencode-crhandler.so" >&2
		exit 1
	fi
	echo "crhandler guard: OK (shim shipped)"
fi
