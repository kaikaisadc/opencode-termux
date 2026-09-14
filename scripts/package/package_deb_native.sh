#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode DEB provider (transplant revival line, native mainline).
#
# This package IS the plain `opencode` name (inherited by the native mainline
# per the 27/28 package-rename decision). Built from
# artifacts/transplant/<ver>/opencode-native-revived; conflicts with the glibc
# appendix package (opencode-wrapper) and the compressed transitional package
# (opencode-compressed): installing one replaces the other.
#
# Native line constraints (documented in the package description):
#   - zero glibc runtime dependencies (pure Bionic)
#   - requires Android API >= 28
#   - full TUI via bionic libopentui.so (W10a deep smoke 5/5); zero glibc runtime deps

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pkg_version_from_transplant
pkg_native_bin

pkg_deb_prepare dpkg-native opencode
mkdir -p "$DEB_ROOT$PREFIX/bin"
install -m755 "$NATIVE_BIN" "$DEB_ROOT$PREFIX/bin/opencode"

# W11: ship the self-activating seccomp shim when the binary references it
# (DT_NEEDED libopencode-crhandler.so). It must land in $PREFIX/lib/opencode/
# to satisfy the binary's DT_RUNPATH $ORIGIN/../lib/opencode.
if grep -aqF libopencode-crhandler.so "$NATIVE_BIN"; then
	SHIM_SO="$(dirname "$NATIVE_BIN")/libopencode-crhandler.so"
	if [[ ! -f "$SHIM_SO" ]]; then
		echo "Error: hardened binary references libopencode-crhandler.so but $SHIM_SO is missing" >&2
		echo "       (run: make seccomp-harden VER=$VERSION)" >&2
		exit 1
	fi
	mkdir -p "$DEB_ROOT$PREFIX/lib/opencode"
	install -m644 "$SHIM_SO" "$DEB_ROOT$PREFIX/lib/opencode/libopencode-crhandler.so"
	echo "Packaging seccomp shim: $SHIM_SO -> $PREFIX/lib/opencode/"
else
	echo "Note: binary is not seccomp-hardened; shipping without libopencode-crhandler.so"
fi

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Depends:
Conflicts: opencode-wrapper, opencode-compressed
Description: OpenCode native bionic mainline (stable since 27/28). Full TUI via bionic libopentui.so (W10a deep smoke 5/5). Zero glibc dependencies.
EOF

pkg_deb_installed_size

cat >"$DEB_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "OpenCode Native for Termux installed (stable mainline since 27/28)"
echo "Run: opencode --version"
echo "Scope: full TUI via bionic libopentui.so (W10a deep smoke 5/5). Zero glibc runtime deps."
echo "Requires Android API >= 28; zero glibc runtime deps."
echo "The glibc wrapper line is now the appendix (renamed opencode-wrapper); native is the stable mainline."
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

pkg_deb_build
