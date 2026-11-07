# Session 2026-11-07 (3) — INC/DEC, XCHG, stack (M1 in progress)

## Built
- INC/DEC: 40-4F, FE /0-/1, FF /0-/1. Flags update like ADD/SUB 1 but CF preserved.
- XCHG: 86/87, 90 (NOP), 91-97.
- Stack: PUSH r16 (50-57), POP r16 (58-5F), PUSH/POP segment
  (06/07/0E/16/17/1E/1F), POP r/m (8F).

## Results
- Cumulative: 138 files × 2,000 = **276,000 cases, all passing**.

## Notes
- PUSH SP (8086 semantics: pushes the already-decremented SP) confirmed by the
  corpus — the implementation reads the register after decrementing SP.
  V30MZ behaviour to check later against WSCpuTest.
- 8F executes as POP for every ModRM reg value on the 8086 (same pattern as
  C6/C7). The /0-only reading is documentation fiction; V30MZ recheck pending.
- There is no 0F (POP CS) case file in the v1 corpus, so that opcode is
  implemented but unverified. Popping CS mid-stream presumably breaks the
  capture rig's assumptions.

## Next slice
Control flow: JMP/Jcc/CALL/RET (E8/E9/EB/70-7F/C2/C3/CA/CB, FF /2-/6),
LOOP/JCXZ (E0-E3), INT (CC/CD/CE), which ends the "one instruction, compare
state" model's easy cases — interrupt cases reference the vector table in RAM,
which the harness already models.
