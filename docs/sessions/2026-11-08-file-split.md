# 2026-11-08 — File split: cpu / bus / ppu / apu (behaviour-preserving)

At the user's prompt, the single-file core (`src/sst.goose`, 1,999
lines) was split by subsystem. Goose's `import name;` is plain file
inclusion relative to the root file's directory — no namespaces, no
visibility walls — so the split is a mechanical cut along the
file's existing section boundaries, with all globals shared as
before.

Layout now:

- `src/sst.goose` (root, ~150 lines) — imports, the SingleStepTests
  harness (case state, JSON reader, run_file) and `main()`. The
  build is unchanged: `goose build src/sst.goose` → `src/sst`.
- `src/cpu.goose` (~900 lines) — CPU state, memory access helpers,
  ModRM decode, `exec_one`, flag/div/shift models, and the
  WSTimingTest-fitted cycle model (`init_cyc`, `est_cycles`).
- `src/bus.goose` (~330 lines) — WS memory map (`rd8`), I/O ports
  (`port_rd`/`port_wr`, SPHINX mask tables), timers, interrupt
  latching/delivery, GDMA, the serial TX-ready refresh, scanline
  events, screen-text helpers and the headless runner (`run_ws`).
- `src/ppu.goose` (~360 lines) — framebuffer rendering (BG,
  windows, sprites), fb hash/PPM dump, and `ppu_test`.
- `src/apu.goose` (~270 lines) — noise LFSR, wave channels, sweep,
  mixer readback, and `apu_test`.

Two declarations moved against their neighbourhood: `ws_mono_cart`
lives in bus.goose (set by the runner, read by the serial refresh),
and the `touched`/`recording` bookkeeping stayed in the root (it is
SST-harness state, written by the CPU's `wb8`).

Verification — the full battery, byte-identical to pre-split:
8086 corpus 634,406/646,000; V20 corpus 2,980,747/3,125,000;
WSTimingTest harvest 400 pass / 7 fail (the documented edges);
WSHWTest Test All completes with 0 failures; `apu_test` 33/33;
`ppu_test` 39/39; `tests/fb_check.sh` 3/3 (golden hashes unchanged,
so rendering and timing are bit-for-bit the same).
