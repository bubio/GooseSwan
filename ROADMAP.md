# Roadmap

Each milestone's completion condition is a set of passing tests.
Work proceeds in slices: one slice per session, ending with the pass counts
and the next step recorded in the session notes.

## M0 — Scaffolding ✅ (2026-11-07)
- SingleStepTests harness in Goose: load a JSON case file, set initial
  registers/memory, execute one instruction, compare final state.
- V30MZ core skeleton passing a handful of opcodes (MOV / basic ALU).
- Done when: the harness runs a real 8086 case file and reports pass/fail counts.
- Result: 28,000 cases passing (MOV + ADD slice). See docs/sessions/2026-11-07-m0.md.

## M1 — CPU complete ✅ (2026-11-07)
- All documented 8086 instructions pass the SingleStepTests 8086 corpus.
  Status 2026-11-07: 634,406 / 646,000 cases (98.21%); the only failures are
  documented-undefined flag residue after DIV/IDIV/IMUL and AAM base 0.
- V20/V30 corpora for the NEC differences.
  Status 2026-11-07: V20 corpus complete at 2,980,747 / 3,125,000 (95.38%)
  under a `v20` CPU profile, including the 0F-prefixed native extensions.
  Non-green residue: multiply/divide flag bits, SF/PF/AF on the BCD and
  bit-string ops (values exact), and ROL4/ROR4, whose register-entangled
  behaviour is still unexplained.
- Done when: WSCpuTest agrees (V30MZ-specific behaviour flushed out).
  Result 2026-11-07: **WSCpuTest Test All passes end to end** on the
  colour model — all 7 suites "Ok!", 5.44 billion instructions, under a
  `cpu_mz` profile layered on the V20 profile. V30MZ deltas (shift-count
  masking, undefined-opcode map, LEA/LES/LDS mod=3 adder quirk, BCD and
  multiply/divide flag models, the stale multiply/divide-unit CF/OF)
  are catalogued in docs/sessions/2026-11-07-wscputest.md.

## M2 — Bus and cartridge ✅ (2026-11-07)
- Memory map, I/O-port bank switching, SRAM/EEPROM.
- Done when: test ROMs boot and run to their result screens.
- Result 2026-11-07: exceeded — **WSHWTest Test All passes** (interrupt
  manager, HBL/VBL timers, the full SPHINX I/O-register mask model in
  mono and colour modes, noise LFSR). The linear window is decoded
  top-aligned so odd-sized images (WSHWTest's 768 KB) boot. Cartridge /
  internal EEPROM remains unimplemented — no current test asset covers
  it. See docs/sessions/2026-11-07-timing-foundation.md.

## M3 — PPU (in progress)
- 224x144 rendering (mono + color modes, sprites, windows).
- Harness: run N frames, dump framebuffer, compare by hash.
- Done when: WSHWTest's display/timing checks pass.
- Status 2026-11-07: the timing foundation landed first — a cycle
  estimator drives the scanline model (159 lines × 256 cycles), the
  current-line port and the frame loop. The estimator is now
  form-aware (EA premiums, loop-tail/prefetch rules, saturating
  shifts, value-dependent MUL/DIV, REP per-element costs, fault
  partials) and WSTimingTest passes 398/406 cases across all 29
  pages; the 8 misses are documented (two need a serial TX timing
  model, the rest are sub-line quantization/data-dependent edges).
  Background rendering has landed: SCR1/SCR2 with windows, mono and
  colour palettes, 2bpp/4bpp tiles, rendered per completed scanline
  into an RGB444 framebuffer, with a `ppu_test` synthetic suite
  (24/24), an `fb` dump/hash harness arg, and the WSHWTest Test All
  and Test Windows screens rendering correctly. Sprites have since
  landed too (attribute table, SCR2 priority, sprite window,
  32-per-line limit; `ppu_test` 39/39), and `tests/fb_check.sh`
  guards three golden screen hashes. Remaining PPU gaps: LCD
  icons/off state and per-frame sprite latching.

## M4 — Peripherals (in progress)
- APU, timers, interrupts, DMA.
- Done when: real game ROMs run with sound.
- Status 2026-11-07: timers, the interrupt controller semantics and
  the APU noise LFSR were pulled forward and are WSHWTest-verified.
  Wave channels, the sweep and GDMA have since landed: the mixer
  readback ports (0x96–0x9B) are live, WSHWTest's sound sweep
  suite passes all 12 cases including the fast-sweep CPU-cycle
  measurement, and `sst apu_test` covers GDMA (26/26). The serial
  TX-ready latch (mono carts) plus the fitted IRQ-entry (40) and
  HLT (12) charges have since closed WSTimingTest's last two
  serial cases — the harvest is 400/407 with only the documented
  quantisation/data-dependent edges left. One correction from
  that slice: GDMA raises no interrupt (bit 3 is SERIAL_RECEIVE).
  Sound DMA + HyperVoice landed 2026-11-08 (Swanium-modelled,
  `sst apu_test` 68/68). Remaining: cartridge EEPROM, serial
  byte protocol; the audible sample stream arrives with the M5
  frontend.

## M5 — Frontend
- Goose gfx package (SDL3): window, input, audio out.
- Done when: a distributable build plays games end to end.
