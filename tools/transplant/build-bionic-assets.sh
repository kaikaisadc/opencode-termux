#!/data/data/com.termux/files/usr/bin/bash
# build-bionic-assets.sh — regenerate the prebuilt bionic native assets that
# swap_native_assets.py injects into the transplanted opencode binary.
#
# Why these exist
# ---------------
# Upstream opencode bundles aarch64-linux-gnu (glibc) builds of fff, @parcel/watcher
# and bun-pty inside its bun standalone graph. On Termux/bionic none can dlopen, so
# file search / the internal file watcher / the PTY silently break. The repo ships
# prebuilt bionic replacements under tools/prebuilt/bionic/; this script rebuilds
# them when opencode bumps the upstream dependency versions.
#
# Requirements (Termux): rust + cargo, clang (bionic target), git, npm, python3.
#   pkg install rust clang git nodejs-lts python3
#
# Versions are pinned to match tools/prebuilt/bionic/MANIFEST.json. Bump both
# together after checking opencode's packages/opencode/package.json for the
# bundled fff-bun / @parcel/watcher versions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/tools/prebuilt/bionic"
PATCH_DIR="$OUT_DIR/patches"
WORK="${BIONIC_ASSETS_WORK:-${TMPDIR:-/tmp}/bionic-assets}"

FFF_TAG="${FFF_TAG:-v0.9.4}"
WATCHER_TAG="${WATCHER_TAG:-v2.5.1}"
NODE_ADDON_API_MAJOR="${NODE_ADDON_API_MAJOR:-7}"

NODE_INC="${NODE_INC:-/data/data/com.termux/files/usr/include/node}"
STRIP="$(command -v llvm-strip || command -v strip)"

log() { printf '[bionic-assets] %s\n' "$*" >&2; }
die() {
	printf '[bionic-assets] ERROR: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

need cargo
need clang++
need git
need npm
need python3
[ -n "$STRIP" ] || die "no strip tool (llvm-strip/strip)"
[ -f "$NODE_INC/node_api.h" ] || die "node headers not found: $NODE_INC (pkg install nodejs-lts)"

mkdir -p "$OUT_DIR" "$WORK"

# ---------------------------------------------------------------- fff-c
build_fff() {
	log "fff-c $FFF_TAG (mimalloc + untagged mmap handle patch)"
	rm -rf "$WORK/fff"
	git clone -q --depth 1 --branch "$FFF_TAG" https://github.com/dmtrKovalenko/fff.git "$WORK/fff"
	git -C "$WORK/fff" apply "$PATCH_DIR/fff-c-android.patch"
	(
		cd "$WORK/fff"
		CARGO_TARGET_DIR="$WORK/fff-target" \
			cargo build --release -p fff-c --features mimalloc
	)
	cp "$WORK/fff-target/release/libfff_c.so" "$OUT_DIR/libfff_c.so"
	"$STRIP" --strip-unneeded "$OUT_DIR/libfff_c.so"
}

# ---------------------------------------------------------------- @parcel/watcher
build_watcher() {
	log "@parcel/watcher $WATCHER_TAG (NAPI addon)"
	rm -rf "$WORK/watcher" "$WORK/node-addon-api"
	git clone -q --depth 1 --branch "$WATCHER_TAG" https://github.com/parcel-bundler/watcher.git "$WORK/watcher"
	(
		cd "$WORK"
		npm pack "node-addon-api@$NODE_ADDON_API_MAJOR" >/dev/null
		tar xzf node-addon-api-*.tgz
	)
	(
		cd "$WORK/watcher"
		clang++ -shared -fPIC -std=c++17 -O2 -fvisibility=hidden \
			-DNAPI_DISABLE_CPP_EXCEPTIONS -DWATCHMAN -DINOTIFY -DBRUTE_FORCE \
			-I"$WORK/package" -I"$NODE_INC" \
			src/binding.cc src/Watcher.cc src/Backend.cc src/DirTree.cc \
			src/Glob.cc src/Debounce.cc \
			src/watchman/BSER.cc src/watchman/WatchmanBackend.cc \
			src/shared/BruteForceBackend.cc \
			src/linux/InotifyBackend.cc src/unix/legacy.cc \
			-o "$OUT_DIR/watcher.node" -pthread
	)
	"$STRIP" --strip-unneeded "$OUT_DIR/watcher.node"
}

# ---------------------------------------------------------------- bun-pty
build_pty() {
	log "bun-pty rust-pty (termios android patch)"
	rm -rf "$WORK/bun-pty"
	git clone -q --depth 1 https://github.com/sursaone/bun-pty.git "$WORK/bun-pty"
	# Force the dependency sources into the cargo registry first.
	(
		cd "$WORK/bun-pty/rust-pty"
		CARGO_TARGET_DIR="$WORK/pty-target" cargo fetch >/dev/null 2>&1 || true
	)
	# termios@0.2.2 only cfg's linux/macos/bsd; teach it android (linux ABI).
	TERMIOS="$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" -maxdepth 2 -type d -name 'termios-0.2.2' 2>/dev/null | head -1)"
	[ -n "$TERMIOS" ] || die "termios-0.2.2 source not found in cargo registry"
	python3 - "$TERMIOS/src/os/mod.rs" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('#[cfg(target_os = "linux")] pub use self::linux as target;',
              '#[cfg(any(target_os = "linux", target_os = "android"))] pub use self::linux as target;')
s = s.replace('#[cfg(target_os = "linux")]\npub use self::linux as target;',
              '#[cfg(any(target_os = "linux", target_os = "android"))]\npub use self::linux as target;')
s = s.replace('#[cfg(target_os = "linux")] pub mod linux;',
              '#[cfg(any(target_os = "linux", target_os = "android"))] pub mod linux;')
s = s.replace('#[cfg(target_os = "linux")]\npub mod linux;',
              '#[cfg(any(target_os = "linux", target_os = "android"))]\npub mod linux;')
open(p, "w").write(s)
PY
	(
		cd "$WORK/bun-pty/rust-pty"
		CARGO_TARGET_DIR="$WORK/pty-target" cargo build --release
	)
	cp "$WORK/pty-target/release/librust_pty.so" "$OUT_DIR/librust_pty.so"
	"$STRIP" --strip-unneeded "$OUT_DIR/librust_pty.so" 2>/dev/null || true
}

# ---------------------------------------------------------------- manifest
refresh_manifest() {
	python3 - "$OUT_DIR/MANIFEST.json" <<'PY'
import hashlib, json, sys
p = sys.argv[1]
m = json.load(open(p))
for a in m["assets"]:
    a["sha256"] = hashlib.sha256(open(f'{p.rsplit("/",1)[0]}/{a["file"]}', "rb").read()).hexdigest()
json.dump(m, open(p, "w"), indent=2)
open(p, "a").write("\n")
print("manifest sha256 refreshed")
PY
}

case "${1:-all}" in
fff) build_fff ;;
watcher) build_watcher ;;
pty) build_pty ;;
all)
	build_fff
	build_watcher
	build_pty
	;;
*) die "usage: $0 [all|fff|watcher|pty]" ;;
esac
refresh_manifest
log "done. assets in $OUT_DIR:"
ls -l "$OUT_DIR"/*.so "$OUT_DIR"/*.node
