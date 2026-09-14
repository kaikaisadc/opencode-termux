# GitHub Actions Scope

GitHub Actions runs the automated native release pipeline for this fork.

## Active release path

- `release-native.yml`: daily cron poll of the official npm channel
  `opencode-linux-arm64`; when newer than the newest `v<version>` release
  here, runs the full transplant pipeline (official npm tgz + official
  android Bun → ELF surgery → bionic libopentui swap → seccomp harden)
  and publishes the release (aarch64 .deb, raw ELF, watcher, SHA256SUMS).
  Manual dispatch accepts an explicit version.

## Verification boundary

The CI runner is x86_64: the built aarch64 ELF cannot be executed there
(transplant runs with `--no-execve`; the TUI pty gate records
"skipped(no-aarch64)"). On-device runtime/TUI/plugin validation still
happens on real Termux devices — CI releases are marked prerelease until
smoke-tested on device.

## Diagnostic-only workflows

- `prebuild-armv7.yml` and `scripts/ci/*`: attempt-based armv7 build
  evidence, not final release artifacts.
