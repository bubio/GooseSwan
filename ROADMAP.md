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

## M1 — CPU complete (in progress)
- All documented 8086 instructions pass the SingleStepTests 8086 corpus.
  Status 2026-11-07: 634,406 / 646,000 cases (98.21%); the only failures are
  documented-undefined flag residue after DIV/IDIV/IMUL and AAM base 0.
- V20/V30 corpora for the NEC differences. ← next
- Done when: WSCpuTest agrees (V30MZ-specific behaviour flushed out).

## M2 — Bus and cartridge
- Memory map, I/O-port bank switching, SRAM/EEPROM.
- Done when: test ROMs boot and run to their result screens.

## M3 — PPU
- 224x144 rendering (mono + color modes, sprites, windows).
- Harness: run N frames, dump framebuffer, compare by hash.
- Done when: WSHWTest's display/timing checks pass.

## M4 — Peripherals
- APU, timers, interrupts, DMA.
- Done when: real game ROMs run with sound.

## M5 — Frontend
- Goose gfx package (SDL3): window, input, audio out.
- Done when: a distributable build plays games end to end.
