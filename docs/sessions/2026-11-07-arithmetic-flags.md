# Session 2026-11-07 (5) — Arithmetic completion + flag archaeology (M1 in progress)

## Built
Shifts/rotates (D0-D3), group 3 (F6/F7: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV),
BCD (DAA/DAS/AAA/AAS), AAM/AAD, SALC, XLAT, CBW/CWD, PUSHF/POPF, SAHF/LAHF,
flag ops (CMC/CLC/STC/CLI/STI/CLD/STD), MOV moffs (A0-A3), LEA/LES/LDS, IRET,
ESC (D8-DF, no-op), IN/OUT (open bus reads as FF), and decoder aliases:
60-6F = Jcc, C0/C1/C8/C9 = RET family, 82 = group 1, FF /7 = PUSH.

## Results
313 files, **614,406 / 626,000 cases passing (98.15%)**. Everything except
the residue below is at 100% per file.

## Hardware behaviour learned from the corpus (the "undefined" flags are not)
- **POPF/IRET normalize the loaded flags**: bits 15-12 read as 1111, bit 1
  as 1, bits 3/5 as 0 — `(v & 0x0FD5) | 0xF002`, verified 2000/2000.
- **D0-D3 /6 is SETMO**: operand := all ones; flags as for a -1 result
  (SF=1, PF=1, CF/AF/ZF/OF=0). Via D2/D3 with CL=0 it is a complete no-op.
- **MUL's flags come from the high half** (AH / DX): CF=OF=(high != 0),
  AF=0, and SF/ZF/PF computed on the high half (PF on its low byte).
- **Shift flags latch as if from the final 1-bit step**: OF uses the one-bit
  formula at any count (SHL: CF^MSB, SHR: pre-final MSB = result bit top-1,
  SAR: 0); SHL's AF is bit 3 of the pre-final value (= bit 4 of the result,
  because a 1-bit SHL is an ADD of the value with itself); SHR/SAR clear AF.
- **DAA/DAS**: the 0x60 step triggers on CF, on AL >= 0xA0, or on
  AL in 0x9A-0x9F with AF=0 (an AF-triggered low adjust suppresses it).
  OF is the overflow of the single combined ±adjustment addition.
- **AAA/AAS** adjust AL and AH as separate byte operations (the AL ±6
  carry/borrow does not propagate); SZP comes from the pre-mask AL,
  OF from the low-byte ±6 operation.
- **AAM** clears CF/OF/AF and sets SZP from the remainder; **AAD's** flags
  are exactly those of its internal add ((AH*base)&0xFF) + AL.
- **IN** reads 0xFF/0xFFFF (the capture rig's bus floats high).

## Known residue (values and control flow are correct; flags differ)
- DIV/IDIV (F6.6, F6.7, F7.6, F7.7; ~7,850 cases): post-division flags are
  microcode residue of the restoring-division loop; no compact rule found.
  IDIV's CF/OF at least read as 0 when no overflow occurs.
- IMUL (F6.5, F7.5; ~3,720 cases): CF/OF are correct, but SF/ZF/PF/AF
  follow neither the MUL high-half rule nor the result; not yet modelled.
- AAM with base 0 (12 cases): takes INT 0 as implemented, but the flags
  pushed/stored are the pre-trap residue (same swamp as DIV).
These are all documented-undefined on Intel and unlikely to be exercised by
WSCpuTest; they stay on the list for a possible microcode-modelling pass.

## Next slice
String operations (A4-A7, AA-AF) with REP/REPE/REPNE — the last unimplemented
files of the 8086 corpus (323 total). Full pass on those completes the
corpus except the residue above.
