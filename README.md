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

Project setup. No emulation code yet — see [ROADMAP.md](ROADMAP.md) and
[docs/test-assets.md](docs/test-assets.md) (research notes, in Japanese).

## Layout (planned)

- `src/` — emulator core and frontend (Goose)
- `tests/` — harness code and test data notes
- `docs/` — research notes and decisions
