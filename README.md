# Gooswan

WonderSwan / WonderSwan Color emulator written in [Goose](https://github.com/aardappel/goose).

Developed test-first: the CPU core is built against the hardware-captured
[SingleStepTests](https://github.com/SingleStepTests) JSON corpora (8086 / V20 /
V30), and the SoC against FluBBaOfWard's hardware test ROMs (WSCpuTest,
WSTimingTest, WSHWTest) and asiekierka's ws-test-suite. A milestone is done
when its tests pass, not when the code looks right.

The structural and behavioural reference is
[Swanium](https://github.com/bubio/Swanium), the same machine implemented in
Rust (cpu / ppu / apu / bus under `crates/core`).

## Status

M1–M4 complete; M5 (frontend) and M6 (Swanium parity) in progress — see
[ROADMAP.md](ROADMAP.md). The core passes the SingleStepTests corpora at
their fitted baselines, WSCpuTest Test All, WSHWTest Test All, 400/407
WSTimingTest timing cases and all 22 ws-test-suite pass/fail ROMs
(`tests/ws_test_suite.sh`, opt-in). `tools/diff_swanium.py` compares it
frame by frame with [Swanium](https://github.com/bubio/Swanium) when a
sibling checkout is present. Session notes live in [docs/sessions](docs/sessions).

CI (GitHub Actions, modelled on the author's BubiBoyLite setup) builds
and runs the full battery on every push to main for Linux and macOS;
publishing a GitHub Release attaches `gooswan-<platform>-<arch>.zip`
(the binary plus this README) to it.

## Build & run

The test harness (also the headless ROM runner):

    goose build tools/sst.goose        # -> tools/sst
    ./tools/sst ws <rom> [suite] [fb|wav|fbwav]

The frontend (SDL3 window via Goose's gfx package, keyboard input,
audio out):

    goose build app/gooswan.goose    # -> app/gooswan
    ./app/gooswan <rom>

Keys: Y pad = WASD, X pad = arrow keys, A = X, B = Z, Start = Return,
Escape closes. Vertical games (cartridge footer flag) are detected
automatically: the picture is turned 90° counter-clockwise in a
portrait window and both pads' directions turn with it, as in
Swanium. Save data lands next to the ROM (`<rom>.sav`,
`<rom>.eep`, `<rom>.iep`). `./app/gooswan <rom> <frames> check`
runs a fixed number of frames and verifies the presented picture
against the emulated framebuffer (headless-friendly).

`sh scripts/build.sh --test` (Linux, macOS, or Git Bash on Windows) runs the core
purity check, the lint (`scripts/lint.sh`: Goose has no linter or
formatter, so any `goose check` warning fails it), both builds and the
full regression battery.

## Layout

- `core/` — the emulator core as a Goose package (`namespace core`):
  cpu / bus / eeprom / ppu / apu, with the public API in
  `core/core.goose`. It imports nothing but std and does no host I/O;
  `scripts/check_core.sh` typechecks it on its own to keep it that way.
- `app/` — the frontend (window, input, audio device, save files),
  using only the core API
- `tools/` — the `sst` test harness: SingleStepTests runner, headless
  ROM runner and white-box core self-tests
- `tests/`, `scripts/` — test data fetch, regression battery, CI builds
- `docs/` — research notes, decisions and session logs
