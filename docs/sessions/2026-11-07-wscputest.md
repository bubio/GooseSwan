# Session 2026-11-07 — WSCpuTest (M1 done, M2 groundwork)

Goal of the session: run FluBBa's WSCpuTest (v0.7.1 ROM, colour model)
against the CPU core and fix what it flags. This needed the WonderSwan
bus and a headless ROM runner, which pulls the M2 groundwork forward.

## Infrastructure

- `ws_mode` in `sst.goose`: physical reads/writes go through a bus map —
  64 KB internal RAM, cartridge SRAM window, ROM bank windows 0/1 and the
  linear window, modulo decode (reset at FFFF:0000 lands on the ROM
  footer). Bank registers power on at 0xFF/0xFF/0xFF, linear bank 0.
- Port shadows for the registers the ROM touches: SYSTEM_CTRL1 reads
  0x02 (colour-capable, so the ROM tests its colour flag variants),
  interrupt base/enable/cause (cause cleared by writing ~mask to 0xB6),
  keypad scan select/state, bank ports C0–C3. IN/OUT do byte accesses;
  word IN/OUT is two byte accesses, low then high.
- Runner `run_ws`: 100k steps per frame, VBLANK cause bit raised per
  frame, interrupts delivered between instructions, TF single-step trap
  honoured (with the POPF/IRET interrupt shadow), HLT parks the CPU.
  Menu key scripting for single suites; screen text reconstructed from
  the BG map so results are judged from the ROM's own output. A survey
  variant (`div+` etc.) presses B at failure stops to catalogue every
  failing test in one pass.
- The V30MZ behaviour lives behind a new `cpu_mz` profile layered on
  `cpu_v20`, so the SingleStepTests profiles stay bit-exact.

## V30MZ behaviours established (all hardware-fitted via WSCpuTest)

- Shift/rotate counts are masked to 5 bits. Masked count 0: rotates keep
  operand and CF, OF is recomputed; shifts keep operand and CF, SZP
  latch from the operand, AF = 0, OF per kind.
- 0x0F and 0x63–0x67 are 1-byte NOPs (no 0F extensions, 0x64/0x65 are
  not REP prefixes). D6 is SALC, not XLAT. F6/F7 /1 are NOPs (the
  immediate is not eaten). C0/C1 /6 ("SAL") zeroes the operand with
  exhausted-shift flags. FE /6 is PUSH (SP decremented first, as in FF);
  FF /7 is a NOP, not a PUSH alias. 8C/8E segment fields wrap mod 4;
  8F executes POP for every reg field.
- LEA/LES/LDS with mod=3 still run the EA adder, fed with the addressing
  form's first register and the r/m register itself; LES/LDS then read
  the far pointer at that EA. FF /3 and /5 (CALL/JMP far) mod=3 likewise.
- DAA/DAS use the classic rule: the 0x60 step triggers iff the original
  AL > 0x99 or CF (the 8086 corpus model wants >= 0xA0 plus an AF
  exception in 0x9A–0x9F). AAA/AAS produce branch-constant flags:
  adjust → CF=AF=ZF=PF=1, SF=0; no adjust → SF=PF=1, rest 0; OF cleared.
  AAD honours the imm8 base (unlike the plain V20, which always uses 10).
- MUL/IMUL on the colour model write a constant status template —
  SF=0, ZF=1, AF=0, PF=0 — plus CF=OF = per-form overflow. (The mono
  model in the ROM differs only in the ZF bit of the base template.)
- DIV/IDIV flags: 16-bit forms clear CF/OF/SF/PF/AF and set ZF iff
  remainder == 0 and the quotient is odd. DIV8 instead latches CF/OF
  from a stale multiply/divide-unit state (below); IDIV8 normal takes
  SZP from the quotient with CF=OF=AF=0. Fault ZF for DIV8/DIV16 comes
  from FluBBa's add-chain over (dividend, divisor), replicated exactly
  in `divu8_err_zf` / `divu16_err_zf`.
- The "magical C & V flags" in FluBBa's calc functions are not random:
  the `imul`/`mul` he executes just before the tested instruction sets
  a stale unit CF/OF that DIV8 (normal and fault), IDIV8 faults and
  AAM faults then latch into FLAGS. Modelled as `unit_cfof`, written by
  every MUL/IMUL, read by those paths. With that, AAM's divide-by-zero
  flags match case-for-case through all 256 error inputs.
- IDIV faults on |quotient| = 128 / 32768 as well: the range check is a
  magnitude pre-check, so -128 and -32768 are not valid results.
- Divide-by-zero oddities: IDIV8 with AX = 0x8000 and divisor 0 returns
  AX = 0x0081 without faulting; IDIV 32/16 with dividend 0x80000000 and
  divisor 0 returns AX = 0x8001, DX = 0 without faulting.

## Result

- Suites individually: Logic, Arithmetic, Rot & Shift, Misc,
  Multiplication, Division, Signed Division — all "Ok!".
- **Test All passes end to end**: 5,441,282,361 instructions, zero
  failure blocks, zero unsupported opcodes. M1 is done.
- Corpus regression, unchanged: 8086 634,406 / 646,000; V20
  2,980,747 / 3,125,000.

Next: M2 proper — fill out I/O coverage and EEPROM, then M3 (PPU) with
WSTimingTest / WSHWTest as the test assets.
