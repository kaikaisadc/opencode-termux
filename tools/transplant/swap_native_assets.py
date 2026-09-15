#!/usr/bin/env python3
"""swap_native_assets.py — replace upstream opencode's glibc native assets with
prebuilt bionic ones, in place, inside the bun standalone module graph.

Background
----------
Upstream opencode bundles three native libraries inside its bun standalone
module graph, built for aarch64-linux-gnu (glibc):

    /$bunfs/root/libfff_c-<hash>.so          fff file search / grep
    /$bunfs/root/watcher-<hash>.node         @parcel/watcher (file watcher)
    /$bunfs/root/librust_pty_arm64-<hash>.so bun-pty (PTY backend)

On Termux/bionic none of them can dlopen (they NEED libc.so.6 /
libstdc++.so.6), which silently disables file search, the internal watcher and
the PTY. This tool swaps in prebuilt bionic builds. Assets are stored RAW
(uncompressed) right after their registry name:

    \\x00/$bunfs/root/<name>\\x00<ELF bytes>

The replacement must be <= the embedded ELF's exact size; it is padded with
trailing NUL bytes (ELF loaders ignore out-of-section trailing bytes), so the
module graph and every downstream offset stay byte-identical.

Safety rails
------------
* Replacement must fit (hard fail otherwise).
* ABI guard: every exported symbol the embedded asset exposes that matches a
  manifest `symbol_prefixes` entry must also be exported by the replacement
  (hard fail otherwise) — catches upstream dep version bumps.
* Idempotent: a slot already holding the replacement (exact bytes) is skipped.
* Absent slots are tolerated (skipped) unless `--require-all` is given; use
  `--require-all` for opencode formats known to bundle all three assets so a
  layout change cannot silently regress.

Usage
-----
    python3 tools/transplant/swap_native_assets.py --binary <in> [--out <out>] [--require-all]
    python3 tools/transplant/swap_native_assets.py --binary <in> --check
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

TRAILER = b"\n---- Bun! ----\n"
BUNFS_TOKEN = b"/$bunfs/root/"
DEFAULT_ASSETS_DIR = Path(__file__).resolve().parent.parent / "prebuilt" / "bionic"


class SwapError(Exception):
    pass


# ------------------------------------------------------------------ ELF utils
def _elf_sections(data, off):
    if data[off : off + 4] != b"\x7fELF" or data[off + 4] != 2:
        raise SwapError(f"not ELF64 at {off:#x}")
    e_shoff = struct.unpack_from("<Q", data, off + 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, off + 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, off + 0x3C)[0]
    return e_shoff, e_shentsize, e_shnum


def elf_size(data, off):
    """Exact on-disk ELF64 size (max of shdr table end and last section extent)."""
    e_shoff, e_shentsize, e_shnum = _elf_sections(data, off)
    end = e_shoff + e_shentsize * e_shnum
    for n in range(e_shnum):
        so = off + e_shoff + n * e_shentsize
        if struct.unpack_from("<I", data, so + 0x4)[0] == 8:  # SHT_NOBITS
            continue
        s_off = struct.unpack_from("<Q", data, so + 0x18)[0]
        s_sz = struct.unpack_from("<Q", data, so + 0x20)[0]
        end = max(end, s_off + s_sz)
    return end


def dyn_defined_symbols(data, off):
    """Defined (global/weak) symbols from SHT_DYNSYM, or None if unavailable."""
    try:
        e_shoff, e_shentsize, e_shnum = _elf_sections(data, off)
    except SwapError:
        return None
    dynsym = None
    for n in range(e_shnum):
        so = off + e_shoff + n * e_shentsize
        if struct.unpack_from("<I", data, so + 0x4)[0] == 11:  # SHT_DYNSYM
            dynsym = so
            break
    if dynsym is None:
        return None
    sym_off = struct.unpack_from("<Q", data, dynsym + 0x18)[0]
    sym_sz = struct.unpack_from("<Q", data, dynsym + 0x20)[0]
    sym_entsize = struct.unpack_from("<Q", data, dynsym + 0x38)[0] or 24
    str_off = struct.unpack_from("<Q", data, dynsym + 0x28)[0]
    out = set()
    for i in range(sym_sz // sym_entsize):
        so = off + sym_off + i * sym_entsize
        st_name = struct.unpack_from("<I", data, so)[0]
        st_info = data[so + 4]
        st_shndx = struct.unpack_from("<H", data, so + 6)[0]
        binding = st_info >> 4
        if binding not in (1, 2):  # GLOBAL / WEAK
            continue
        if st_shndx == 0:  # undefined
            continue
        s = off + str_off + st_name
        e = data.find(b"\x00", s)
        out.add(data[s:e].decode("utf-8", "replace"))
    return out


# ------------------------------------------------------------------ slot logic
def find_slot(data, prefix):
    """Absolute offset of the ELF bytes for `/$bunfs/root/<prefix...>` asset."""
    needle = b"\x00" + BUNFS_TOKEN + prefix.encode()
    start = 0
    while True:
        i = data.find(needle, start)
        if i < 0:
            return -1
        ne = data.find(b"\x00", i + len(needle))
        if ne < 0:
            return -1
        elf_off = ne + 1
        if data[elf_off : elf_off + 4] == b"\x7fELF":
            return elf_off
        start = ne + 1


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def swap_one(data, manifest_entry, assets_dir, do_write):
    prefix = manifest_entry["slot_prefix"]
    repl_path = assets_dir / manifest_entry["file"]
    if not repl_path.is_file():
        raise SwapError(f"missing prebuilt asset: {repl_path}")
    repl = repl_path.read_bytes()
    want_sha = manifest_entry.get("sha256", "")
    if want_sha and sha256_file(repl_path) != want_sha:
        raise SwapError(
            f"{manifest_entry['file']}: sha256 mismatch (manifest {want_sha[:12]}…, "
            f"file {sha256_file(repl_path)[:12]}…) — regenerate the manifest"
        )

    off = find_slot(data, prefix)
    if off < 0:
        raise SwapError(
            f"slot not found for prefix {prefix!r} (upstream layout changed?)"
        )
    old = elf_size(data, off)

    # Idempotency: slot already holds exactly this replacement?
    if bytes(data[off : off + len(repl)]) == repl and all(
        b == 0 for b in data[off + len(repl) : off + old]
    ):
        return {"asset": manifest_entry["file"], "status": "already", "size": old}

    if len(repl) > old:
        raise SwapError(
            f"{manifest_entry['file']}: replacement {len(repl)} B > embedded slot {old} B "
            f"(cannot equal-swap; rebuild a smaller asset or update the graph writer)"
        )

    # ABI guard: embedded's exported symbols (matching the manifest prefixes)
    # must all exist in the replacement.
    prefixes = manifest_entry.get("symbol_prefixes", [])
    if prefixes:
        emb_syms = dyn_defined_symbols(data, off)
        rep_syms = dyn_defined_symbols(repl, 0)
        if emb_syms is not None and rep_syms is not None:
            missing = sorted(
                s
                for s in emb_syms
                if any(s.startswith(p) for p in prefixes) and s not in rep_syms
            )
            if missing:
                raise SwapError(
                    f"{manifest_entry['file']}: ABI guard failed — embedded asset exports "
                    f"{len(missing)} symbol(s) the replacement lacks, e.g. {missing[:5]} "
                    f"(upstream dep version likely bumped; rebuild the asset)"
                )

    if do_write:
        data[off : off + len(repl)] = repl
        for k in range(len(repl), old):
            data[off + k] = 0
    return {
        "asset": manifest_entry["file"],
        "status": "swapped",
        "offset": off,
        "embedded_size": old,
        "used": len(repl),
        "pad": old - len(repl),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--binary", required=True)
    ap.add_argument("--out", default=None, help="output path (default: in-place)")
    ap.add_argument("--assets-dir", default=str(DEFAULT_ASSETS_DIR))
    ap.add_argument(
        "--manifest", default=None, help="default: <assets-dir>/MANIFEST.json"
    )
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    ap.add_argument(
        "--require-all",
        action="store_true",
        help="fail if any asset slot is absent (use for formats known to bundle "
        "all three); default tolerates absent slots (older opencode builds)",
    )
    args = ap.parse_args(argv)

    assets_dir = Path(args.assets_dir)
    manifest_path = (
        Path(args.manifest) if args.manifest else assets_dir / "MANIFEST.json"
    )
    if not manifest_path.is_file():
        print(
            f"swap_native_assets: ERROR: manifest not found: {manifest_path}",
            file=sys.stderr,
        )
        return 1
    manifest = json.loads(manifest_path.read_text())

    bin_path = Path(args.binary)
    if not bin_path.is_file():
        print(
            f"swap_native_assets: ERROR: binary not found: {bin_path}", file=sys.stderr
        )
        return 1
    data = bytearray(bin_path.read_bytes())

    results = []
    try:
        for entry in manifest["assets"]:
            if find_slot(data, entry["slot_prefix"]) < 0:
                if args.require_all:
                    raise SwapError(
                        f"slot not found for prefix {entry['slot_prefix']!r} "
                        f"(upstream layout changed?)"
                    )
                results.append({"asset": entry["file"], "status": "missing"})
                continue
            results.append(swap_one(data, entry, assets_dir, do_write=not args.check))
    except SwapError as e:
        print(f"swap_native_assets: ERROR: {e}", file=sys.stderr)
        return 1

    if not args.check:
        out = Path(args.out) if args.out else bin_path
        out.write_bytes(data)

    for r in results:
        if r["status"] == "already":
            print(f"  {r['asset']}: already bionic (slot {r['size']} B)")
        elif r["status"] == "missing":
            print(f"  {r['asset']}: slot absent (skipped)")
        else:
            print(
                f"  {r['asset']}: swapped @{r['offset']} "
                f"({r['used']} B used, {r['pad']} B NUL pad, slot {r['embedded_size']} B)"
            )
    swapped = sum(1 for r in results if r["status"] in ("swapped", "already"))
    print(
        f"swap_native_assets: {'checked' if args.check else 'OK'} "
        f"({swapped}/{len(results)} assets) -> {args.out or bin_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
