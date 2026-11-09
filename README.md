# Gooswan - WonderSwan / WonderSwan Color Emulator

Gooswan is a **WonderSwan / WonderSwan Color** emulator written in [Goose](https://github.com/aardappel/goose), developed test-first against hardware-captured CPU corpora and public test ROMs.

<p align="center">
  <a href="https://github.com/bubio/Gooswan/releases/latest">
    <img src="https://img.shields.io/github/v/release/bubio/Gooswan" alt="Latest Release">
  </a>
  <a href="https://github.com/bubio/Gooswan/releases/latest">
    <img src="https://img.shields.io/github/downloads/bubio/Gooswan/total.svg" alt="Downloads">
  </a>
  <a href="https://github.com/bubio/Gooswan/actions/workflows/ci.yml">
    <img src="https://github.com/bubio/Gooswan/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

Gooswan separates a platform-independent core (`core/`, a Goose package with no host I/O) from a small SDL3 frontend (`app/`). Its structural and behavioural reference is [Swanium](https://github.com/bubio/Swanium), the same machine implemented in Rust; a milestone is done when its tests pass, not when the code looks right.

## Key Features

- **Test-First Core:** The V30MZ CPU is built against the [SingleStepTests](https://github.com/SingleStepTests) 8086 / V20 corpora, then WSCpuTest for the V30MZ-specific behaviour.
- **Platform-Independent Core:** CPU, memory map, interrupts, timers, DMA, PPU, APU, EEPROM, cartridge and RTC live in `core/`, which imports nothing but std; `scripts/check_core.sh` keeps it that way.
- **WonderSwan + WonderSwan Color:** Mono and colour rendering, sound DMA and HyperVoice, cartridge / internal EEPROM, RTC carts.
- **Vertical Games:** Detected from the cartridge footer; the picture turns 90° in a portrait window and the pads turn with it, as in Swanium.
- **Swanium Differential Check:** `tools/diff_swanium.py` compares framebuffers, WRAM and audio frame by frame against a sibling Swanium checkout.
- **CI-Packaged Releases:** One GitHub Actions workflow builds and tests Linux, macOS and Windows, and attaches a zip per platform to each release.

## Download

Prebuilt binaries are attached to [**Releases**](https://github.com/bubio/Gooswan/releases/latest). Each zip holds the `gooswan` binary and this README.

| Platform | Asset name |
|----------|------------|
| macOS (Apple Silicon) | `gooswan-macos-arm64.zip` |
| macOS (Intel) | `gooswan-macos-x86_64.zip` |
| Linux (x64, glibc of Ubuntu 22.04 or newer) | `gooswan-linux-amd64.zip` |
| Windows (x64) | `gooswan-windows-x86_64.zip` |

> Note for macOS: the binary is not notarized, so Gatekeeper may block it on first launch. Remove the quarantine flag:
> ```bash
> xattr -d com.apple.quarantine ./gooswan
> ```

## Building

Requires the Goose compiler on `PATH` (CI pins `v2026.4`, see `.github/workflows/ci.yml`).

```bash
goose build app/gooswan.goose    # frontend -> app/gooswan
goose build tools/sst.goose      # test harness / headless runner -> tools/sst
```

Full check (core purity, lint, both builds and the regression battery). Runs on Linux, macOS and Git Bash on Windows; the battery needs `nasm`, `curl` and `unzip` for the test data:

```bash
sh scripts/fetch_test_roms.sh    # builds WSHWTest / WSTimingTest into tests/roms
sh scripts/fetch_corpus.sh       # SingleStepTests 8086 corpus into tests/data
sh scripts/build.sh --test
```

`scripts/lint.sh` fails on any `goose check` warning or a source not in `goose format` layout.

## Usage

```bash
./app/gooswan path/to/game.wsc
```

Default controls:

- Arrow keys = X-pad
- `W A S D` = Y-pad
- `X` = A, `Z` = B
- `Enter` = Start
- `Esc` = quit

Save data is written next to the ROM on exit and every 600 frames: `<rom>.sav`, `<rom>.eep`, `<rom>.iep`, and `<rom>.rtc` for carts with a clock.

`./app/gooswan <rom> <frames> check` runs a fixed number of frames and verifies the presented picture against the emulated framebuffer (works headless with `GOOSE_GFX_HEADLESS=1` and lavapipe).

### Test harness

```bash
./tools/sst [v20] <case-file.json>...     # SingleStepTests corpora
./tools/sst ws <rom> [suite] [fb|wav|fbwav]  # headless ROM runner (framebuffer / audio dump)
./tools/sst cpu_test | ppu_test | apu_test | eeprom_test  # core self-tests
sh tests/ws_test_suite.sh                 # ws-test-suite, opt-in (WS_TEST_SUITE=<dir>)
python3 tools/diff_swanium.py <rom> [frames]  # needs a sibling ../Swanium checkout
```

## Status

M1–M4 are complete; M5 (frontend polish: gamepad, scaling) and M6 (Swanium parity) are in progress. See [ROADMAP.md](ROADMAP.md) and the session notes in [docs/sessions](docs/sessions).

| Test | Result |
|------|--------|
| SingleStepTests 8086 | 634,406 / 646,000 (residue: documented-undefined flags) |
| WSCpuTest Test All | pass |
| WSHWTest Test All | pass |
| WSTimingTest | 400 / 407 (7 documented quantisation cases) |
| ws-test-suite | 22 / 22 |

## Accuracy References

- [WSDev Wiki](https://ws.nesdev.org/wiki/WSdev_Wiki)
- [SingleStepTests](https://github.com/SingleStepTests) (8086, V20)
- [FluBBaOfWard/WSCPUTest](https://github.com/FluBBaOfWard/WSCPUTest)
- [FluBBaOfWard/WSTimingTest](https://github.com/FluBBaOfWard/WSTimingTest)
- [FluBBaOfWard/WSHWTest](https://github.com/FluBBaOfWard/WSHWTest)
- [asiekierka/ws-test-suite](https://github.com/asiekierka/ws-test-suite)
- [Swanium](https://github.com/bubio/Swanium)

## Architecture

```text
app/ (SDL3 window, keyboard, audio out, save files via Goose gfx)
                     |
                     v  core/core.goose (public API)
core/: CPU (V30MZ), Bus, Interrupts, Timers, DMA, PPU, APU, EEPROM, Cartridge, RTC
```

- `core/` — the emulator core (`namespace core`), headless and platform-independent
- `app/` — the frontend, using only the core API
- `tools/` — the `sst` harness (SingleStepTests runner, headless ROM runner, white-box self-tests) and the Swanium diff tool
- `tests/`, `scripts/` — test data fetch, regression battery, CI builds
- `docs/` — research notes, decisions and session logs
