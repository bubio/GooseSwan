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
  Rendering itself has not started.

## M4 — Peripherals (in progress)
- APU, timers, interrupts, DMA.
- Done when: real game ROMs run with sound.
- Status 2026-11-07: timers, the interrupt controller semantics and
  the APU noise LFSR were pulled forward and are WSHWTest-verified.
  Remaining: wave channels / sweep / volume (audible APU), DMA.

## M5 — Frontend
- Goose gfx package (SDL3): window, input, audio out.
- Done when: a distributable build plays games end to end.
