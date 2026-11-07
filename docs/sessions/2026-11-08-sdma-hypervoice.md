# 2026-11-08 — Sound DMA + HyperVoice (M4 leftover)

## Model (from Swanium's bus/apu, the designated reference)

**SDMA** (`sdma_tick` in bus.goose, driven from ws_line_events with
the same cycle delta as the APU): colour only. Registers: source =
ports 0x4A/0x4B + segment 0x4C (low nibble), counter = 0x4E/0x4F +
0x50, ctrl = 0x52 (bit 7 ENABLE, bit 6 DECREMENT, bit 3 REPEAT,
bit 2 HOLD, bits 0-1 rate: period = 128 x {6,4,2,1} cycles). When a
stopped engine first ticks with ENABLE set it latches source/counter
from the ports (plus shadows for REPEAT); a zero counter self-clears
ENABLE without starting. Each period step writes the byte at the
source (through rd8, so ROM/SRAM/RAM all work) into the voice data
latch (port 0x89 shadow — the only CPU-visible effect; the voice
low-pass is audio-domain), advances the source, decrements the
counter, and writes both back to the port shadows. On completion:
REPEAT restores the shadows, otherwise ENABLE self-clears. HOLD
steps latch 0 into 0x89 and leave the pointers alone. Bulk ticks are
equivalent to Swanium's per-cycle loop for transfer counts; the
start latch can lag a port write by up to one instruction, which no
test asset measures.

**HyperVoice**: port-write semantics in port_wr (colour only): a
write to a direct word port (0x64-0x67) clears the data latch
(0x69); a write to 0x69 zeroes all four direct bytes. The sample
maths (`hv_sample`/`hv_output` in apu.goose) follows Swanium (after
Mednafen): expansion by ctrl bits 3-2 (unsigned / negated / signed /
raw), volume shift bits 1-0, truncation to i16 before the final
>> 5; direct signed words take precedence over the latch when
either is nonzero; the latch path scales by 32 and routes per
0x6B bits 6/5. CPU-invisible until the M5 audio stream exists, but
pinned now by Swanium's own unit-test vectors in apu_test.

**Read side needed no code**: the SPHINX I/O mask tables already
encode every read semantic (SDMA seg ports & 0x0F, ctrl & 0x5F —
note the tables say ENABLE does not read back, which wins over
Swanium's & 0xDF — HV 0x64-0x69 read 0, 0x6B & 0x6F).

## Verification
- `sst apu_test`: 68/68 (20 new SDMA checks: cadence, writeback,
  rate 0, decrement, repeat, hold, zero-counter, mono gate; 15 HV
  checks: write semantics, 4 sample vectors incl. the mode-4 i16
  wrap, routing/direct/disabled/speed-bits).
- Corpora at baseline (8086 634406/646000, V20 2980747/3125000),
  ppu_test 39/39, WSTimingTest 400/407 full harvest, WSHWTest Test
  All 0 failures — the IO-register pattern test is unaffected even
  though it pattern-writes the SDMA registers (the engine only runs
  while ENABLE is set with a nonzero counter, and its steps land on
  the 128-cycle cadence).
- fb_check 3/3.

## Left in M4
Cartridge EEPROM (the 93Cx6 serial protocol on the cart ports) and
the serial byte protocol. Swanium also models the WS internal
EEPROM — same slice family when picked up.
