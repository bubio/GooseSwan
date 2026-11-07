# 2026-11-07 — Serial TX-ready latch + IRQ entry timing (WSTimingTest 400/407)

Slice goal: close the last two serial-dependent WSTimingTest cases,
F4 HLT (was 214 vs 101) and the exceptions-page IRQ case (was 78 vs
293). Both pass now; the full harvest is **400/407** (the remaining
7 are the documented edges: AAA, AAS, EA04, CA RETF, D2/D3 MEMIM2,
TRIPLE_JP — same deltas as before).

## The serial TX-ready cause is a level, not a baud timer

`test_opF4` and `test_ExIrq` both do the same setup: SERIAL_CTRL
(port 0xB3) = COMM_ENABLE | COMM_SPEED_38400, then enable the
SERIAL_SEND interrupt (INT_CAUSE bit 0). Reading the tests and
their handlers settled the model:

- ExIrq's handler (`serialTxInterruptHandler`) never acknowledges
  the cause — it only clears IF in the saved flags and IRETs — yet
  the interrupt is taken after the loop's STI on EVERY iteration
  (expected total = 75.008 cycles/iter, and the no-IRQ loop alone
  measures ~20). So the cause must simply be up the whole time.
- The HLT loop likewise wakes instantly every iteration once the
  serial is on.

Swanium models exactly this: `refresh_serial_tx_irq()` sets
INT_CAUSE bit 0 on writes to 0xB1/0xB2/0xB3 whenever the serial is
enabled and the SERIAL_SEND interrupt is enabled — a level that is
sampled at port writes and cleared only via INT_CAUSE_CLEAR.
Implemented as `refresh_serial()`; SERIAL_CTRL writes are masked
to 0xC4 (enable/speed/overrun bits) as in Swanium.

## The latch is mono-only — WSHWTest's IO test proves it

First implementation latched unconditionally and WSHWTest Test All
livelocked: its IO-register test pattern-writes ports in order,
and at port 0xB2 it writes INT_ENABLE = 0xFF while the serial is
still enabled from testIrq. An instantly-pending bit 0 (whose
handler only increments a counter and IRETs, never ACKs) starves
the main flow completely — measured 3,381 bit-0 deliveries, then
the line-match bit (which latches once the line counter crosses
port 0x03's restored value 64) took over for 2.2M deliveries.
Bisected against the pre-slice commit (844770f) with single-change
variants: serial latch alone reproduces the stall; IRQ-entry and
HLT charges alone do not.

Swanium gates the latch on `model == Mono`. Our runner boots every
ROM as a colour machine, so the gate here follows the CART: the
ROM footer's byte at `len - 9` is 0 for mono-only carts
(WSTimingTest) and 1 for colour carts (WSHWTest, WSCpuTest). The
latch fires only for mono carts (`ws_mono_cart`). Whether the real
distinction is the machine or the mode is unverified — the gate
reproduces both test ROMs' hardware-measured behaviour, and
`apu_test` pins both sides of it.

## Two timing constants fitted

- **Hardware IRQ entry = 40 cycles** (fault entry stays 44). The
  runner previously charged nothing for `ws_deliver_int`. With 44
  the ExIrq iteration summed to 79 (fill 8 + NOP 1 + STI 4 + entry
  44 + handler 13 + MOV 1 + DEC 1 + JNZ tail 7, verified by a
  per-instruction trace); 40 lands exactly on 75.
- **HLT est = 12** (was the default 4). With the cause already
  pending, an HLT iteration is fill 8 + HLT + DEC 1 + tail 5 =
  26 cycles → 101.56 lines → the measured 101.

## Correction: GDMA raises no interrupt

FluBBa's include names INT_CAUSE bit 3 = SERIAL_RECEIVE, so the
bit-3 latch added with GDMA in the M4 slice (following Swanium's
IrqSource enum, which its author marks unverified) was wrong:
GDMA is synchronous and raises no cause. Removed; the GDMA case in
`apu_test` now asserts no latch.

## Verification

- WSTimingTest full harvest: **400 pass / 7 fail** (per-page
  scoring over all 29 pages; fails = the 7 documented edges).
- Corpora at baseline: 8086 634,406/646,000, V20 2,980,747/3,125,000.
- WSHWTest Test All completes with 0 failures; the sound sweep
  suite passes (see the harness note below); WSCpuTest logic suite
  ran to its end screen (295M instructions, 0 Failed).
- `sst apu_test` 33/33 (incl. the mono/colour serial gate),
  `sst ppu_test` 39/39, `tests/fb_check.sh` 3/3.

## Harness notes (not emulator behaviour)

- The fb_check m1 golden was re-recorded (928216367990215109 →
  -295421874257209499). Test All ends in a key wait; whether the
  runner's freeze-stop lands on the results screen or back at the
  menu is a race between the 600-frame freeze-stop and the
  200-frame auto-dismiss, and the new IRQ-entry charge flipped it.
  The value is deterministic for this build (verified 3 runs) and
  Test All itself is failure-free either way; the script carries a
  comment saying so.
- The m6 sweep run under the stock runner shows no sweep screens:
  the test runs and passes between the sparse 2000-frame dumps and
  returns to the menu before the final dump. Verified with a
  temporary 200-frame-dump variant (all sweep cases Ok!, 0 failed).

## Not modelled

Actual serial byte transmission/reception, baud timing, overrun
and receive behaviour. SERIAL_DATA writes are still discarded and
reads return 0. Next M4 leftovers: Sound DMA + HyperVoice,
cartridge EEPROM.
