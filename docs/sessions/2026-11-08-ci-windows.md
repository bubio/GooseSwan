# 2026-11-08 — CI rework: one matrix workflow, Windows, Goose v2026.4

User: "CIの再整備。Windowsの追加。Goooseの最新版の使用"

The three workflows become one `.github/workflows/ci.yml`: a 4-way build
matrix (linux-amd64, macos-arm64, macos-x86_64, windows-x86_64) plus an
inline release job. Goose is pinned to v2026.4, sha256-verified.

## Changes

- Goose v2026.3 → v2026.4 (linux-x64 559ad7…, macos-arm64 8ef0b5…,
  macos-x64 471bee…, windows-x64 87ceb0…). Locally on macOS arm64 the
  full battery is unchanged (lint clean, 634406/646000, fb 3/3, 400/7).
- Windows: `windows-2025`, every step in Git Bash (`shell: bash`),
  nasm from Chocolatey, `goose build` with the runner's Visual Studio.
  Artifact `gooswan-windows-x86_64` holds `gooswan.exe`. The lavapipe
  frontend smoke stays Linux-only (no GPU stand-in on other runners).
- `.gitattributes` forces LF so the sh scripts survive a Windows checkout.
- `run_tests.sh` / `fb_check.sh` strip `\r` from sst's output before
  parsing (the Windows C runtime prints `\r\n`).
- `build_linux.sh` and `build_macos.sh` were identical → `scripts/build.sh`.
- `package_zip.sh` keeps the binary's own name (`gooswan.exe` on Windows).
- Actions bumped: checkout v7, cache v6, upload-artifact v7,
  download-artifact v8.

| Alternative | Why not |
| --- | --- |
| Keep per-OS workflows + reusable publish workflow | Each OS's release run uploaded its own zips, so the publish job ran 2–3 times per release; one matrix states the platform list once |
| MSYS2 / WSL for Windows | Git Bash already ships on the runner and runs the existing scripts; Goose itself is a native Windows binary |

## Non-goals

- Windows frontend smoke (needs a GPU device on the runner).
- Adopting v2026.4's `goose format` as a CI check.
