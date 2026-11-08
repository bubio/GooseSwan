# GooseSwan

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

M1–M4 complete; M5 (frontend) in progress — see [ROADMAP.md](ROADMAP.md).
The core passes the SingleStepTests corpora at their fitted baselines,
WSCpuTest Test All, WSHWTest Test All and 400/407 WSTimingTest timing
cases. Session notes live in [docs/sessions](docs/sessions).

CI (GitHub Actions, modelled on the author's BubiBoyLite setup) builds
and runs the full battery on every push to main for Linux and macOS;
publishing a GitHub Release attaches `gooseswan-<platform>-<arch>.zip`
(the binary plus this README) to it.

## Build & run

The test harness (also the headless ROM runner):

    goose build src/sst.goose          # -> src/sst
    ./src/sst ws <rom> [suite] [fb|wav|fbwav]

The frontend (SDL3 window via Goose's gfx package, keyboard input,
audio out):

    goose build src/gooseswan.goose    # -> src/gooseswan
    ./src/gooseswan <rom>

Keys: Y pad = WASD, X pad = arrow keys, A = X, B = Z, Start = Return,
Escape closes. Save data lands next to the ROM (`<rom>.sav`,
`<rom>.eep`, `<rom>.iep`). `./src/gooseswan <rom> <frames> check`
runs a fixed number of frames and verifies the presented picture
against the emulated framebuffer (headless-friendly).

## Layout

- `src/` — emulator core (cpu / bus / ppu / apu), the `sst` harness
  and the `gooseswan` frontend (Goose)
- `tests/` — test data fetch scripts and the framebuffer hash battery
- `docs/` — research notes, decisions and session logs
