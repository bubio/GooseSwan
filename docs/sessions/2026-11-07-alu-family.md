# Session 2026-11-07 (2) — ALU family (M1 in progress)

## Built
- Unified ALU dispatcher in `src/sst.goose`: opcodes 00-3D (forms 0-5) for
  ADD/OR/ADC/SBB/AND/SUB/XOR/CMP, with ADC/SBB carry-in and per-class flag rules.
- Group 1 immediates: 80 / 81 / 83 (83 = sign-extended imm8, flags computed on
  the extended operand, matching hardware).
- TEST: 84 / 85 / A8 / A9 (AND without writeback).

## Results
- This slice: 70 files × 2,000 = **140,000 cases, all passing**.
- Cumulative: 84 files, **168,000 cases, 0 failures**.

## Notes
- Group-1 case files are split per reg field (`80.0.json` … `80.7.json`);
  `tests/fetch_data.sh` takes those names as-is.
- AF after logic ops (OR/AND/XOR/TEST) reads as 0 in the captured 8086 corpus;
  the implementation's AF=0 matched all 56,000 logic cases.
- The earlier full-run listing initially missed the group files because the
  fetch aborted on the 404 for the unsplit name — check file presence, not
  just run output, when a suite is assembled from parts.

## Next slice
INC/DEC (40-4F, FE/FE groups — CF preserved), XCHG (86/87, 91-97), and the
stack family: PUSH/POP (50-5F, 06/07/0E/16/17/1E/1F, 8F), which needs SS:SP
memory writes in the harness's single-step model.
