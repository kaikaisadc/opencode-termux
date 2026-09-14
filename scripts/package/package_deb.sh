#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build the opencode-wrapper DEB (glibc appendix line) from the staged prefix.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix}"

[[ -x "$STAGED_PREFIX/bin/opencode" ]] || {
	echo "Error: missing staged launcher" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/lib/opencode/runtime/opencode" ]] || {
	echo "Error: missing staged runtime" >&2
	exit 1
}
pkg_version_from_runtime "$STAGED_PREFIX/lib/opencode/runtime/opencode"

pkg_deb_prepare dpkg opencode-wrapper
install -D -m755 "$STAGED_PREFIX/bin/opencode" "$DEB_ROOT$PREFIX/bin/opencode"

cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: opencode-wrapper
Version: $VERSION
Architecture: $ARCH_DEB
Maintainer: $MAINTAINER
Section: utils
Priority: optional
Breaks: opencode (<< $VERSION)
Conflicts: opencode, opencode-native, opencode-compressed
Description: OpenCode AI coding assistant for Termux (glibc appendix, renamed opencode-wrapper)
 Alternative provider: opencode-native (stable mainline since 27/28, full TUI).
Depends: bash, ncurses
EOF

pkg_deb_installed_size
pkg_deb_build
