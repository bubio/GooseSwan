# 2026-11-08 — core / app split, then Swanium parity

**Conclusion:** the emulator core is now a Goose package `core/` (namespace `core`,
public API in `core/core.goose`) that imports only std and does no host I/O; `app/`
(frontend) and `tools/` (test harness) depend on it. Accuracy is measured against
Swanium two ways: the hardware test ROMs Swanium passes (ws-test-suite now 22/22 here
too) and a differential frame/RAM/audio diff against swanium-core (`tools/diff_swanium.py`).

## Layout and boundary

| Directory | Role |
|---|---|
| `core/` | cpu / bus / eeprom / rtc / ppu / apu + `core.goose` (API: `power_on`, `run_frame`, `fb`, audio, save media, model, RTC) |
| `app/` | window, input, audio device, save files (`app/saves.goose`), host clock → RTC |
| `tools/` | `sst` harness: SingleStepTests, headless runner, `mark` / `run` modes, white-box self-tests (same namespace as the core) |

`scripts/check_core.sh` (run by both build scripts) typechecks `core/core.goose` on its
own — so nothing in the core can name an app/tool declaration — and rejects imports
other than std/core modules and any file/stdout/process call.

| Alternative considered | Why not |
|---|---|
| Keep plain `import` file inclusion with directories only | No enforcement; the old frontend already leaned on harness globals |
| Wrap all machine state in a struct (Swanium-style, no globals) | Large rewrite of every module for no accuracy gain; Goose globals stay per program instance |

## Accuracy changes (all from Swanium unless noted)

- CPU: IRQ held off one instruction after STI / POPF / IRET (IF 0→1) / POP SS / MOV SS;
  TF trap deferred likewise; frame loop order IRQ → instruction → trap; an IRQ after a
  ≥256-cycle REP returns to its first prefix. FE /2–/5 mirror FF; 0xF1 = INT 1.
- Hardware model flag (`model_mono`, footer colour flag, `core::set_model`): mono
  INT_VECTOR readback of the pending cause, 16 KB WRAM, HW_FLAGS 0x86/0x87.
- Interrupts: a latched cause is delivered after INT_ENABLE drops it (WSHWTest
  "IRQs happen when disabled" — failing before this session but unseen, see below).
- Sweep sample points: word IN / word OUT complete one cycle after byte forms (fits both
  WSHWTest and ws-test-suite gdma_timing).
- SDMA: live SDMA_CTRL readback in colour mode, start/self-clear on write.
- Cartridge: RTC (0xCA/0xCB), linear window `(C0 << 20 | a) % size` with C0 = 0xFF at
  reset (the old top-alignment hack mis-mapped every ROM > 1 MB that wrote C0),
  Bandai 2003 bank high bytes, SRAM sized from the footer, open bus when absent.
- Boot state: SP = 0x2000, 0x9E = 3. Sprite table latched per frame (captured before
  line 142, active from the next frame).
- Frame length: the overshoot of a frame's last instruction carries over and the GDMA
  stall is charged to its OUT, so a frame is exactly 40,704 cycles (audio was ~1 % long,
  so the frontend's queue grew).

## Test infrastructure

- `tests/ws_test_suite.sh` (opt-in, local ROM dir): Swanium's marker tables. 16 → 22/22.
- The WSHWTest runner now reports every screen showing "Failed" (it used to sample one
  screen per 2000 frames) and stops when Test All returns to the menu; m1 golden
  re-recorded on that menu screen.
- `sst run` + `tools/swprobe` (Rust, against `../Swanium`) + `tools/diff_swanium.py`:
  per-frame fb hashes, final fb / WRAM / audio. Frame-exact equality is not expected:
  the CPU cycle models differ (Gooswan's REP STOSW is 5+6n, fitted to WSTimingTest;
  Swanium uses 3n), so games drift by a few frames. Use the diff to find functional
  breakage (blank/garbage screens, stops), not timing.

## Results

Battery green (8086 634,406/646,000; WSHWTest Test All; fb 3/3; WSTimingTest
400/407). ws-test-suite 16 → 22/22.

Library sweep (311 commercial ROMs, final framebuffer vs Swanium):

| | identical | <1k px | <10k px | ≥10k px | stops (unsupported opcode) |
|---|---|---|---|---|---|
| start (600 frames) | 190 | 19 | 28 | 74 | 11 |
| end (1200 frames) | 230 | 37 | 26 | 18 | 0 |

The functional bugs the sweep surfaced: the linear-window decode (all >1 MB ROMs that
write 0xC0), INS/OUTS without port I/O (OUTSW palette loads), colour rendering on mono
models, and the frame-length drift. Of the 18 large differences left, the ones checked
(Ring Infinity, Medarot, Hunter X Hunter, Wonder Classic) show the same scene at a
different animation/fade phase — CPU-timing drift; several others are bad dumps ([f1]).

## Non-goals (this session)

- The 7 WSTimingTest misses (sub-cycle loop-overhead quantisation; changing the AAA /
  RETF imm table entries moves them past the expected value).
- Boot ROM (BIOS) execution, save states, LCD icon segments.
