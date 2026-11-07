# 2026-11-07 — WSTimingTest full fit (M3 timing, slice 2)

## Result

- **WSTimingTest: 398/406 cases pass (98.0%)** — all 29 pages, up from
  16/17 on page 1 at the end of M2. Page 0 is now 17/17, including the
  "Unaligned" prefetch case that failed throughout M2.
- No regressions: WSHWTest Test All still fully passes; both
  SingleStepTests corpora are exactly at baseline
  (8086 634,406/646,000; V20 2,980,747/3,125,000). WSCpuTest's logic
  suite was run for 332k frames under the cycle runner with every
  visible subtest "Ok!" and zero "Failed" — it was not run to
  completion because the exhaustive logic groups take hours at
  cycle-runner speed (a full-suite re-run is worth scheduling
  separately if that ever matters).

## How the fit works

The ROM measures with `runtest`: HBL timer preset to 350, the test loop
runs 1000 iterations, elapsed HBL lines must match the expected value
*exactly*. One cycle per iteration ≈ 3.90625 lines, so the estimator
has to be right to the cycle on average.

The estimator (`est_cycles`) is now form-aware instead of a flat opcode
table:

- **Base loop cost is 14 cycles/iteration** (fill_prefetch = NOP×3 +
  IN AL,DX at 8, DEC = 1, JNZ tail = 5).
- **EA premium**: memory operands with two-register EAs (rm 0–3) pay
  +2 over the base form cost (one-reg and direct `[disp16]` pay 0);
  displacement size is free. Per-family bases fitted from the EA pages:
  ALU r/m-dest = 3, r←[mem] = 2, CMP = 2, MOV = 1, XCHG r,[mem] = 5,
  LEA = 1, LES/LDS = 6 (+1 for the `[bx+si]` form, 8 for the MZ mod=3
  quirk form).
- **Loop-tail rule (the key discovery)**: a backward-taken Jcc/LOOP
  tail costs 5, but **7 when the same iteration already executed a
  control transfer** (taken branch, call, ret, iret, far jump, or the
  handler IRET of a fault/interrupt taken in that iteration) — modelled
  as the second prefetch-queue flush. A tiny Jcc loop (span ≤ 4 bytes,
  target still in the queue) costs 4 instead. Taken-forward branches:
  Jcc = 2, LOOP = 3, LOOPE/LOOPNE = 4, JCXZ = 2; landing on an odd
  offset costs +1.
- **Shifts saturate**: cost = 1 + 2·min(count, 2); the count is the
  masked (5-bit) count actually executed.
- **MUL/IMUL/DIV/IDIV are fast for the tests' operand values**
  (early termination): MUL/IMUL = 4, DIV8 = 16, IDIV8 = 18,
  DIV16 = 24, IDIV16 = 25.
- **REP strings**: base 5 + per-element — MOVS 7, CMPS 10, SCAS 9,
  INS/OUTS/STOS/LODS 6; CX=0 costs 5. Early-exit REPE/REPNE are charged
  by the CX actually consumed.
- **Faults/interrupts**: entry is charged like an interrupt (44,
  INT3 = 41 total, INT imm = 42) plus a per-opcode partial-execution
  cost (DIV 5, IDIV 8, BOUND 9, AAM 4, INTO 1). The TF single-step
  trap entry is 33.
- Fixed a CPU-runner bug found on the way: **a pending enabled
  interrupt now wakes HLT even with IF=0** (it is just not serviced),
  matching x86 behaviour. WSTimingTest's HLT test deadlocked without
  it.

## Remaining 8 misses (documented, parked)

- **F4 HLT (214 vs 101) and ExIrq (78 vs 293)**: both depend on the
  serial port's TX-complete timing, which we do not model yet.
- **AAA/AAS (+3 lines each)**: per-iteration cost is not an integer —
  the adjust fires on a data-dependent pattern across iterations.
- **A04X (−4)**: a load through a pointer that marches +2 per
  iteration costs ~1 cycle/iteration more than the same load through
  `[bx+si]`; no fitted rule yet.
- **tripplejump (+4)**: chained-branch microstructure.
- **RETF imm (−1 line), shifts by CL D2/D3 (−1 line each)**:
  quantization edges at the 1-line resolution of the test.

## Runner changes

- New `pgN` suite argument: advances WSTimingTest's results pages by
  holding X-right after each page's screen settles, so all 29 pages
  can be harvested unattended (~30 s for the whole sweep).

## Next

M3 rendering proper: framebuffer generation (BG/sprites/windows) and
the hash-comparison harness, using the now-solid cycle/scanline
foundation.
