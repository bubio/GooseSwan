# Session 2026-11-07 (4) — Control flow (M1 in progress)

## Built
- Jcc (70-7F), JMP (EB/E9/EA, FF /4-/5), CALL (E8/9A, FF /2-/3), RET/RETF
  (C3/C2/CB/CA), LOOP/LOOPcc/JCXZ (E0-E3), INT3/INT/INTO (CC/CD/CE),
  MOV segment (8C/8E), PUSH Ev (FF /6).
- Cumulative: 177 files × 2,000 = **354,000 cases, all passing**.

## Hardware behaviour learned from the corpus
- **Word accesses wrap at the 64 KB segment offset boundary.** A word at
  offset 0xFFFF takes its high byte from offset 0x0000 of the same segment —
  for ModRM operands, far pointers, and the stack alike (CALL with SP=1
  pushes its high byte to SS:0x0000). The core now routes all word access
  through `seg_rd16`/`seg_wr16` (segment base + offset).
- **FF /6 PUSH reads its operand after decrementing SP**, so PUSH SP via
  FF /6 also pushes the new SP, consistent with the PUSH r16 opcode.

## Process notes
- One edit in this session landed inside the FF block (an unanchored
  replace matched `return false;` at the wrong site), which silently made
  ~20 new branches unreachable. The full-run listing exposed it; anchor
  replacements on unique full lines.
- Goose quirk: `ip = fetch16(); seg[1] = fetch16();` miscompiled (the second
  store lost its value); binding fetch results to locals first works.
  JMP far (EA) is written in the local form.
