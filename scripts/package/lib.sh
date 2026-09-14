#!/data/data/com.termux/files/usr/bin/bash
# scripts/package/lib.sh — shared plumbing for scripts/package/package_*.sh.
#
# Sourced, never executed. Centralizes what every package variant needs:
# environment defaults, tool checks, version resolution, deb work-tree prep,
# and pacman makepkg staging. The pacman work dir cleanup is serialized with
# flock (fd 9, held until process exit) so concurrent package_*.sh runs
# cannot delete each other's pkg/ src/ trees.
#
# Conventions (scripts/AGENTS.md): strict mode lives at the caller; this
# file assumes set -euo pipefail. Package-specific control/PKGBUILD content
# stays in the calling script.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "Error: lib.sh is a library — source it from a package_*.sh script" >&2
	exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MAINTAINER="${MAINTAINER:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PACKAGER_NAME="${PACKAGER_NAME:-Hope2333(幽零小喵) <u0catmiao@proton.me>}"
PKGREL="${PKGREL:-1}"
TRANSPLANT_ROOT="${TRANSPLANT_ROOT:-$ROOT_DIR/artifacts/transplant}"

pkg_require_cmds() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || {
			echo "Error: $c not found" >&2
			exit 1
		}
	done
}

# Resolve the deb architecture (explicit ARCH_DEB wins, dpkg if present).
pkg_resolve_arch_deb() {
	if [[ -z "${ARCH_DEB:-}" ]]; then
		ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo aarch64)"
	fi
}

# VERSION from a staged runtime binary (explicit VERSION wins).
pkg_version_from_runtime() {
	local runtime="$1"
	if [[ -z "${VERSION:-}" ]]; then
		if ! VERSION="$("$runtime" --version)"; then
			echo "Error: staged runtime version check failed" >&2
			exit 1
		fi
	fi
	[[ -n "$VERSION" ]] || {
		echo "Error: staged runtime returned an empty version" >&2
		exit 1
	}
}

# VERSION from the single transplant build (explicit VERSION wins).
pkg_version_from_transplant() {
	local builds=()
	if [[ -z "${VERSION:-}" ]]; then
		shopt -s nullglob
		builds=("$TRANSPLANT_ROOT"/*)
		shopt -u nullglob
		if [[ ${#builds[@]} -eq 0 ]]; then
			echo "Error: no transplant builds under $TRANSPLANT_ROOT (run: make transplant VER=<x>)" >&2
			exit 1
		fi
		if [[ ${#builds[@]} -gt 1 ]]; then
			echo "Error: multiple transplant builds found; set VERSION=<x> explicitly:" >&2
			printf '  %s\n' "${builds[@]}" >&2
			exit 1
		fi
		VERSION="$(basename "${builds[0]}")"
	fi
}

# NATIVE_BIN: OPENCODE_NATIVE_BIN wins, then opencode-native-tui (post-TUI-swap),
# then opencode-native-revived fallback (task-tui-common-fix).
pkg_native_bin() {
	NATIVE_BIN="${OPENCODE_NATIVE_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-tui}"
	[[ -x "$NATIVE_BIN" ]] || NATIVE_BIN="$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
	[[ -x "$NATIVE_BIN" ]] || {
		echo "Error: missing native runtime $NATIVE_BIN (run: make transplant VER=$VERSION)" >&2
		exit 1
	}
}

# COMPRESSED_BIN: the T3 UPX-packed product of the transplant pipeline.
pkg_compressed_bin() {
	COMPRESSED_BIN="${OPENCODE_COMPRESSED_BIN:-$TRANSPLANT_ROOT/$VERSION/opencode-native-revived-upx}"
	[[ -x "$COMPRESSED_BIN" ]] || {
		echo "Error: missing compressed runtime $COMPRESSED_BIN (waiting on T3 upx output)" >&2
		exit 1
	}
}

# ── deb ────────────────────────────────────────────────────────────────────

# pkg_deb_prepare <packing-subdir> <pkgname>
# Sets DEB_ROOT/OUT_DIR/OUT_FILE and recreates the work tree.
pkg_deb_prepare() {
	local sub="$1" pkgname="$2"
	pkg_require_cmds dpkg-deb
	pkg_resolve_arch_deb
	DEB_ROOT="$ROOT_DIR/packing/$sub/work"
	OUT_DIR="$ROOT_DIR/packing/$sub"
	OUT_FILE="$OUT_DIR/${pkgname}_${VERSION}_${ARCH_DEB}.deb"
	rm -rf "$DEB_ROOT"
	mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT$PREFIX" "$OUT_DIR"
	chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"
}

# Append Installed-Size to DEBIAN/control (after the caller wrote it).
pkg_deb_installed_size() {
	INSTALLED_SIZE="$(du -sk "$DEB_ROOT" | cut -f1)"
	echo "Installed-Size: $INSTALLED_SIZE" >>"$DEB_ROOT/DEBIAN/control"
}

# pkg_deb_build [dpkg-deb args...] — build $DEB_ROOT into $OUT_FILE.
pkg_deb_build() {
	dpkg-deb --build "$@" "$DEB_ROOT" "$OUT_FILE"
	echo "DEB package created: $OUT_FILE"
}

# ── pacman ─────────────────────────────────────────────────────────────────

# pkg_pacman_prepare <PKGBUILD-template> <tag>
# Takes the pacman work-dir lock, cleans pkg/ src/, stages a temp makepkg.conf
# (PACKAGER appended) and a rewritten PKGBUILD (pkgver/pkgrel). Sets
# TMP_MAKEPKG_CONF/TMP_PKGBUILD; traps cleanup on EXIT. The lock (fd 9) is
# held until the calling script exits.
pkg_pacman_prepare() {
	local template="$1" tag="$2"
	pkg_require_cmds makepkg
	PACMAN_DIR="$ROOT_DIR/packing/pacman"
	mkdir -p "$PACMAN_DIR"
	exec 9>"$PACMAN_DIR/.work.lock"
	flock 9
	cd "$PACMAN_DIR"
	rm -rf "$PACMAN_DIR/pkg" "$PACMAN_DIR/src"
	TMP_MAKEPKG_CONF="$PACMAN_DIR/.makepkg-$tag.conf"
	TMP_PKGBUILD="$PACMAN_DIR/.PKGBUILD.$tag.tmp"
	cleanup() { rm -f "$TMP_MAKEPKG_CONF" "$TMP_PKGBUILD"; }
	trap cleanup EXIT
	if [[ -f "$PREFIX/etc/makepkg.conf" ]]; then
		cp "$PREFIX/etc/makepkg.conf" "$TMP_MAKEPKG_CONF"
	else
		: >"$TMP_MAKEPKG_CONF"
	fi
	printf "\nPACKAGER=%q\n" "$PACKAGER_NAME" >>"$TMP_MAKEPKG_CONF"
	# Termux ships an EMPTY /etc/makepkg.conf (the pacman package only carries
	# pacman.conf); makepkg 7.x hard-fails without CARCH/PKGEXT/SRCEXT. Set
	# defaults here (appended last so caller overrides still win).
	printf "\nCARCH=%s\n" "$(uname -m)" >>"$TMP_MAKEPKG_CONF"
	printf "PKGEXT='.pkg.tar.xz'\nSRCEXT='.src.tar.xz'\n" >>"$TMP_MAKEPKG_CONF"
	cp "$PACMAN_DIR/$template" "$TMP_PKGBUILD"
	sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$TMP_PKGBUILD"
	sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$TMP_PKGBUILD"
}

# pkg_pacman_run [VAR=VALUE...] — run makepkg on the staged PKGBUILD.
# Extra environment assignments are passed through; REPO_ROOT is always set.
pkg_pacman_run() {
	env "$@" REPO_ROOT="$ROOT_DIR" makepkg --config "$TMP_MAKEPKG_CONF" -f --noconfirm -p "$TMP_PKGBUILD"
}

# pkg_pacman_guard <pkg-file> [grep-pattern]
# Regression guard: reject packages with data/ payload paths (double-prefix bug).
pkg_pacman_guard() {
	local pkg="$1" pat="${2:-^data/}" hit
	[[ -n "$pkg" ]] || return 0
	hit="$(bsdtar -tf "$pkg" | grep -E "$pat" | head -1 || true)"
	if [[ -n "$hit" ]]; then
		echo "FATAL: regression guard triggered — found data/ payload path: $hit" >&2
		echo "Ensure PKGBUILD stages to \$pkgdir/usr/ (relative), not \$pkgdir\$prefix." >&2
		exit 1
	fi
	echo "Regression guard: OK (no data/ payload paths)"
}
