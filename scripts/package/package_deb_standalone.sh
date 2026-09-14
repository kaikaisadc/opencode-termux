#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/package_deb_standalone.sh — build the opencode-wrapper-standalone DEB
# Pure-addition standalone package: frozen single version for rollback only.
# Coexists with `opencode` (native) and `opencode-wrapper` (no Conflicts on the
# literal name `opencode`). Uses an independent work dir and control template.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGED_PREFIX="${STAGED_PREFIX:-$ROOT_DIR/artifacts/staged/prefix-standalone}"
CONTROL_TEMPLATE="$ROOT_DIR/packing/deb-standalone/DEBIAN/control"

# Standalone staged prefix must use the independent lib prefix.
[[ -x "$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode" ]] || {
	echo "Error: missing standalone staged runtime" >&2
	exit 1
}
[[ -x "$STAGED_PREFIX/bin/opencode-wrapper" ]] || {
	echo "Error: missing standalone staged launcher" >&2
	exit 1
}
pkg_version_from_runtime "$STAGED_PREFIX/lib/opencode-wrapper/runtime/opencode"

pkg_deb_prepare dpkg-standalone opencode-wrapper-standalone
cp -a "$STAGED_PREFIX/." "$DEB_ROOT$PREFIX/"

# Ensure the standalone launcher is present (source of truth at repo bin/).
mkdir -p "$DEB_ROOT$PREFIX/bin"
cp "$ROOT_DIR/bin/opencode-wrapper" "$DEB_ROOT$PREFIX/bin/opencode-wrapper"
chmod 755 "$DEB_ROOT$PREFIX/bin/opencode-wrapper"

# Render control from template, substituting version/architecture.
sed -e "s/\${OPENCODE_VERSION}/$VERSION/g" \
	-e "s/\${ARCHITECTURE}/$ARCH_DEB/g" \
	"$CONTROL_TEMPLATE" >"$DEB_ROOT/DEBIAN/control"
chmod 644 "$DEB_ROOT/DEBIAN/control"

pkg_deb_installed_size
pkg_deb_build
