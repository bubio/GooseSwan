# Session 2026-11-07 (6) — String operations (8086 corpus complete)

## Built
- MOVS/CMPS/STOS/LODS/SCAS (A4-A7, AA-AF), byte and word forms, with
  DF-controlled pointer updates wrapping at the segment offset boundary.
- REP / REPE / REPNE: the repeat loop runs to completion inside the single
  step, as the corpus captures state at instruction retirement. The ZF
  condition applies only to CMPS/SCAS; the source segment honours overrides,
  the destination is always ES.

## Results
- All 10 string files pass 2000/2000 on the first run.
- **Full 8086 corpus: 323 files, 634,406 / 646,000 cases (98.21%).**
  316 files are at 100%. The only remaining failures are the flag residue
  documented in 2026-11-07-arithmetic-flags.md (DIV/IDIV post-division flags,
  IMUL's SF/ZF/PF/AF, AAM base 0 — all documented-undefined flag behaviour;
  values, memory, and control flow match everywhere).

## M1 status
The 8086 phase of M1 is done modulo that residue. What remains for M1:
run a NEC corpus (SingleStepTests V20 suite / nuV30's V30 subset) to flush
out V30MZ differences — SETMO already hints the capture CPU shares NEC
traits — and then FluBBa's WSCpuTest ROM once the harness grows a bus
(M2 groundwork).
