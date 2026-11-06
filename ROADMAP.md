# Roadmap

Each milestone's completion condition is a set of passing tests.
Work proceeds in slices: one slice per session, ending with the pass counts
and the next step recorded in the session notes.

## M0 — Scaffolding
- SingleStepTests harness in Goose: load a JSON case file, set initial
  registers/memory, execute one instruction, compare final state.
- V30MZ core skeleton passing a handful of opcodes (MOV / basic ALU).
- Done when: the harness runs a real 8086 case file and reports pass/fail counts.

## M1 — CPU complete
- All documented 8086 instructions pass the SingleStepTests 8086 corpus.
- V20/V30 corpora for the NEC differences.
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
