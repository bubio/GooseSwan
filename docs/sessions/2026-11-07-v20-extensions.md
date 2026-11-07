# Session 2026-11-07 (8) — V20/V30 native extensions (0F-prefixed)

## Result
- V20 corpus complete: **2,980,747 / 3,125,000 cases (95.38%)**, all 360
  files. The 8086 profile is unchanged at 634,406 / 646,000.
- Fully green: the TEST1/CLR1/SET1/NOT1 family (16 files, 160k cases).

## What the extensions turned out to be (all measured from the corpus)
- **Bit operations** (0F10-0F1F): the index — from CL or an imm8 — is taken
  modulo the operand size (bit = idx mod 8/16 of the ModRM operand itself,
  no string addressing). TEST1 sets flags exactly like AND with the bit
  mask (CF=OF=AF=0, SZP from the result); the others preserve flags.
- **BCD string ops** (ADD4S/SUB4S/CMP4S): CL digits at DS:SI (override-able)
  and ES:DI, processed in whole bytes — ceil(CL/2) of them, the last byte
  in full even for odd counts; pointers do not move; offsets wrap at 64K.
  Each byte is a binary add/sub followed by a DAA/DAS-style correction in
  which the low digit's ±6 carries into the high digit like a binary carry.
  SUB4S's high correction also fires when the high digit sum is exactly 9
  and the low digit needed its correction (the DAS quirk zone). CF and ZF
  (whole-result zero) are exact, OF is always 0; SF/PF/AF are residue.
  Values: 2000/2000 in both directions.
- **BINS/BEXT** (0F31/33, imm8-count forms at 0F39/3B): insert the low bits
  of AX into the bit string at ES:DI, or extract a field from DS:SI into
  AX. The count is (register or imm8) + 1, the first operand is a running
  bit offset — and the addressing is word-oriented: the offset register
  keeps only (offset + count) mod 16 while SI/DI advance by 2 per full
  word crossed. ZF = (new offset == 0) exactly; AF/OF are 0; CF/SF/PF are
  residue. Values and pointer updates: exact.
- **ROL4/ROR4** (0F28/2A): OPEN. A plain digit-string rotation fits only
  ~4%: the operation visibly reaches into neighbouring registers (AL
  changes even for memory operands) in a pattern that is neither a
  rotation of the operand nor of the register file in encoding order.
  Parked with the current best-effort model in place.

## Debugging note
Two analysis traps cost time here and are worth remembering: the corpus
generator reuses identical seed states across files, so the first cases of
every file can "confirm" a wrong model; and the SST harness only compares
recorded final state, so a spurious write to an unrecorded address is
invisible (it hid a wrong-opcode bug in the imm bit operations).
