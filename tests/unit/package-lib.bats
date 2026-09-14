#!/usr/bin/env bats
# Unit tests for scripts/package/lib.sh (shared packaging plumbing).

load '../lib/helper'

setup() {
	make_tmpdir
	LIB="$(script_path scripts/package/lib.sh)"
	# Isolate the repo-derived paths the library computes from BASH_SOURCE.
	FAKE_ROOT="$TEST_TMPDIR/fake-root"
	mkdir -p "$FAKE_ROOT/packing/pacman"
}

teardown() {
	clean_tmpdir
}

# Source lib.sh as if it lived inside a package/ dir of a fake repo root.
# PREFIX is overridden so pkg_pacman_prepare reads a fake makepkg.conf
# instead of the real /data/data/com.termux/files/usr/etc one.
source_lib() {
	local fake_pkg="$FAKE_ROOT/scripts/package"
	mkdir -p "$fake_pkg"
	cp "$LIB" "$fake_pkg/lib.sh"
	PREFIX="$TEST_TMPDIR/fake-prefix" source "$fake_pkg/lib.sh"
}

@test "lib.sh refuses to be executed directly" {
	run bash "$LIB"
	[ "$status" -eq 1 ]
	[[ "$output" == *"library"* ]]
}

@test "PREFIX default points at the Termux system prefix" {
	(
		fake_pkg="$FAKE_ROOT/scripts/package"
		mkdir -p "$fake_pkg"
		cp "$LIB" "$fake_pkg/lib.sh"
		source "$fake_pkg/lib.sh"
		[[ "$PREFIX" == "/data/data/com.termux/files/usr" ]]
	)
}

@test "ROOT_DIR / TRANSPLANT_ROOT / PKGREL defaults are set" {
	(
		source_lib
		[[ "$ROOT_DIR" == "$FAKE_ROOT" ]]
		[[ "$TRANSPLANT_ROOT" == "$ROOT_DIR/artifacts/transplant" ]]
		[[ "$PKGREL" == "1" ]]
	)
}

@test "pkg_require_cmds fails on a missing command" {
	(
		source_lib
		run pkg_require_cmds definitely-not-a-command-xyz
		[ "$status" -eq 1 ]
		[[ "$output" == *"not found"* ]]
	)
}

@test "pkg_require_cmds passes for existing commands" {
	(
		source_lib
		pkg_require_cmds bash ls
	)
}

@test "pkg_resolve_arch_deb honors explicit ARCH_DEB" {
	(
		source_lib
		ARCH_DEB=arm64
		pkg_resolve_arch_deb
		[[ "$ARCH_DEB" == "arm64" ]]
	)
}

@test "pkg_version_from_runtime uses explicit VERSION" {
	(
		source_lib
		VERSION=9.9.9
		pkg_version_from_runtime "$TEST_TMPDIR/whatever"
		[[ "$VERSION" == "9.9.9" ]]
	)
}

@test "pkg_version_from_runtime reads --version from the runtime" {
	cat >"$TEST_TMPDIR/fake-runtime" <<'EOF'
#!/usr/bin/env bash
echo "1.2.34"
EOF
	chmod +x "$TEST_TMPDIR/fake-runtime"
	(
		source_lib
		pkg_version_from_runtime "$TEST_TMPDIR/fake-runtime"
		[[ "$VERSION" == "1.2.34" ]]
	)
}

@test "pkg_version_from_runtime fails when runtime errors" {
	cat >"$TEST_TMPDIR/bad-runtime" <<'EOF'
#!/usr/bin/env bash
	exit 3
EOF
	chmod +x "$TEST_TMPDIR/bad-runtime"
	(
		source_lib
		run pkg_version_from_runtime "$TEST_TMPDIR/bad-runtime"
		[ "$status" -ne 0 ]
	)
}

@test "pkg_version_from_transplant resolves the single build" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		mkdir -p "$TRANSPLANT_ROOT/1.18.30"
		pkg_version_from_transplant
		[[ "$VERSION" == "1.18.30" ]]
	)
}

@test "pkg_version_from_transplant fails on multiple builds" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		mkdir -p "$TRANSPLANT_ROOT/1.18.29" "$TRANSPLANT_ROOT/1.18.30"
		run pkg_version_from_transplant
		[ "$status" -eq 1 ]
		[[ "$output" == *"multiple transplant builds"* ]]
	)
}

@test "pkg_version_from_transplant fails on zero builds" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/empty"
		mkdir -p "$TRANSPLANT_ROOT"
		run pkg_version_from_transplant
		[ "$status" -eq 1 ]
		[[ "$output" == *"no transplant builds"* ]]
	)
}

@test "pkg_native_bin prefers explicit OPENCODE_NATIVE_BIN" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		VERSION=1.18.30
		mkdir -p "$TRANSPLANT_ROOT/$VERSION"
		: >"$TEST_TMPDIR/explicit-bin"
		chmod +x "$TEST_TMPDIR/explicit-bin"
		OPENCODE_NATIVE_BIN="$TEST_TMPDIR/explicit-bin" pkg_native_bin
		[[ "$NATIVE_BIN" == "$TEST_TMPDIR/explicit-bin" ]]
	)
}

@test "pkg_native_bin prefers tui over revived" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		VERSION=1.18.30
		mkdir -p "$TRANSPLANT_ROOT/$VERSION"
		: >"$TRANSPLANT_ROOT/$VERSION/opencode-native-tui"
		chmod +x "$TRANSPLANT_ROOT/$VERSION/opencode-native-tui"
		: >"$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
		chmod +x "$TRANSPLANT_ROOT/$VERSION/opencode-native-revived"
		pkg_native_bin
		[[ "$NATIVE_BIN" == */opencode-native-tui ]]
	)
}

@test "pkg_native_bin fails when no runtime exists" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		VERSION=1.18.30
		mkdir -p "$TRANSPLANT_ROOT/$VERSION"
		run pkg_native_bin
		[ "$status" -ne 0 ]
	)
}

@test "pkg_pacman_prepare rewrites pkgver/pkgrel and stages conf" {
	(
		source_lib
		TRANSPLANT_ROOT="$TEST_TMPDIR/transplant"
		mkdir -p "$TRANSPLANT_ROOT/1.18.30"
		pkg_version_from_transplant

		# fake makepkg so pkg_require_cmds passes and nothing executes
		mkdir -p "$TEST_TMPDIR/bin"
		cat >"$TEST_TMPDIR/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
		chmod +x "$TEST_TMPDIR/bin/makepkg"
		PATH="$TEST_TMPDIR/bin:$PATH"

		# fake makepkg.conf template where lib.sh expects it
		mkdir -p "$PREFIX/etc"
		: >"$PREFIX/etc/makepkg.conf"

		# fake PKGBUILD template inside the fake pacman dir
		cat >"$FAKE_ROOT/packing/pacman/PKGBUILD.test" <<'EOF'
pkgname=opencode-test
pkgver=0.0.0
pkgrel=1
EOF

		pkg_pacman_prepare PKGBUILD.test opencode-test
		[[ -f "$TMP_PKGBUILD" ]]
		[[ "$TMP_PKGBUILD" == "$FAKE_ROOT/packing/pacman/.PKGBUILD.opencode-test.tmp" ]]
		grep -q '^pkgver=1.18.30$' "$TMP_PKGBUILD"
		grep -q '^pkgrel=1$' "$TMP_PKGBUILD"
		grep -q "^PACKAGER=" "$TMP_MAKEPKG_CONF"
	)
}

@test "pkg_pacman_guard skips silently when package file is absent" {
	(
		source_lib
		run pkg_pacman_guard "$TEST_TMPDIR/no-such.pkg.tar.xz"
		[ "$status" -eq 0 ]
	)
}

@test "all 8 package scripts pass bash -n syntax check" {
	for f in package_deb package_deb_native package_deb_standalone package_deb_compressed \
		package_pacman package_pacman_native package_pacman_standalone package_pacman_compressed; do
		run bash -n "$(script_path "scripts/package/$f.sh")"
		[ "$status" -eq 0 ]
	done
}
