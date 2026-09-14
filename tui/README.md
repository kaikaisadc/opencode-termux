# Vendored TUI runtime: bionic `libopentui.so`

`libopentui-bionic.so` is the Android/bionic build of OpenTUI's renderer that
`tools/transplant/swap_tui.py` equal-length-swaps into the transplanted
`opencode-native` ELF (producing `opencode-native-tui`). Without it the TUI
cannot `dlopen` the renderer and the pipeline records `tui: absent`.

Provenance (recorded for supply-chain auditing):

- Upstream: OpenTUI (`@opentui/core` 0.4.5 — the version opencode 1.18.21
  through 1.18.30 pins in its workspace catalog), MIT licensed.
- Extracted from: `Hope2333/opencode-termux` release `Push260912`, asset
  `opencode_1.18.30_aarch64.deb`
  (sha256 `098fe39a426bf128ad1a0af5206fdc90f7518413f6684cb6aba7f825317395f9`),
  by scanning the embedded `/$bunfs/root/libopentui-<hash>.so` asset with
  `swap_tui.find_libopentui_asset` + `elf_size`.
- File: 5,878,192 bytes, sha256
  `bfc631c84748c63cdd27a8d86c3b3c53d3f6970f1fd376cdb2bb1b7a710e1811`.
- Guard verified: `swap_tui.has_ffi_guard()` passes (clamp=6, csel_vs=12).

Refresh policy: rebuild from source with `tools/transplant/build-libopentui.sh`
on a Termux device, or re-extract from a newer native release, whenever
upstream opencode bumps `@opentui/core` past 0.4.5 or TUI rendering breaks.
