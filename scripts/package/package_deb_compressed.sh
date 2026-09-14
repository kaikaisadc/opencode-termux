#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-compressed DEB (UPX-packed variant of the native line).
#
# D1 ruling: three mutually exclusive providers —
#   opencode (native mainline) / opencode-wrapper (glibc appendix) / opencode-compressed.
# This package Provides: opencode (= version) and Conflicts with ALL other
# families. It deliberately does NOT declare Replaces: the compressed variant
# is an alternative, not an upgrade — Replaces would let it silently displace
# an installed provider and wipe its user data on removal.
#
# Control is generated from the heredoc below (B1 lesson: the packing/deb*/
# DEBIAN/control template files are orphans; the script heredoc is the true
# source). packing/deb-compressed/DEBIAN/control is a reference copy only.
#
# Input: the UPX-packed ELF produced by T3
#   artifacts/transplant/<ver>/opencode-native-revived-upx
# placed bin-direct at usr/bin/opencode (no wrapper, zero glibc deps).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkg_version_from_transplant
pkg_compressed_bin

pkg_deb_prepare dpkg-compressed opencode-compressed
mkdir -p "$DEB_ROOT$PREFIX/bin"
install -m755 "$COMPRESSED_BIN" "$DEB_ROOT$PREFIX/bin/opencode"

# crhandler shim (REQUIRED, unconditional): the compressed input is always the
# hardened native runtime whose DT_NEEDED libopencode-crhandler.so resolves via
# DT_RUNPATH $ORIGIN/../lib/opencode. UPX compression hides the DT_NEEDED string
# from grep, so detection-by-grep is impossible — the shim ships unconditionally.
SHIM_SO="${OPENCODE_CRHANDLER_SO:-}"
[[ -n "$SHIM_SO" && -f "$SHIM_SO" ]] || {
	echo "FATAL: OPENCODE_CRHANDLER_SO unset or missing — the compressed family always ships libopencode-crhandler.so" >&2
	exit 1
}
install -D -m755 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/opencode/libopencode-crhandler.so"

# Field order matters (B1 lesson): Conflicts MUST precede Description or it
# gets swallowed into the description text (illegal field order).
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode-compressed
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Depends:
Provides: opencode (= $VERSION)
Conflicts: opencode, opencode-wrapper, opencode-wrapper-standalone
Description: OpenCode compressed variant (UPX-packed native bionic runtime)
 Size-optimized variant of the native mainline: the revived bionic ELF
 packed with UPX. Zero glibc dependencies, Android API >= 28, bin-direct
 (no wrapper). Mutually exclusive with opencode (native mainline) and
 opencode-wrapper (glibc appendix) and opencode-wrapper-standalone (frozen
 rollback); no Replaces by design - installing this
 variant never silently displaces another provider or wipes its data.
EOF

pkg_deb_installed_size

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode compressed variant installed (UPX-packed native bionic runtime)"
echo "Run: opencode --version"
echo "Scope: same runtime as the native mainline, UPX-packed for size."
echo "Mutually exclusive with opencode, opencode-wrapper and opencode-wrapper-standalone (no Replaces: variant, not upgrade)."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

# Compressed family uses fast gzip wrap because the payload ELF is already UPX-packed.
pkg_deb_build -Zgzip -z6

# crhandler guard (unconditional): the deb MUST contain the shim.
dpkg-deb -c "$OUT_FILE" | grep -q "lib/opencode/libopencode-crhandler.so" || {
	echo "FATAL: deb does not ship libopencode-crhandler.so" >&2
	exit 1
}
echo "crhandler guard: OK (shim shipped)"
