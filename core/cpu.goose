// GooseSwan CPU core: V30MZ (8086/V20 profiles) state, decoder,
// executor, and the WSTimingTest-fitted cycle model.
namespace core;

var mem: u8[1048576] = [0; 1048576];
var r: u16[8] = [0; 8];      // encoding order: ax cx dx bx sp bp si di
var seg: u16[4] = [0; 4];    // es cs ss ds
var ip: u16 = 0;
var flags: u16 = 0;

var cyc_tab: i64[256] = [0; 256];  // per-opcode cycle estimates for the WS timing model (fitted against WSTimingTest)
var dbg_taken: bool = false;  // last branch outcome, for the cycle estimator
var dbg_back: bool = false;  // last branch jumped backward
var dbg_head: i64 = 0;  // target offset of the last taken relative branch
var xfer_flag: bool = false;  // a control transfer already executed in the current loop iteration (the loop tail then costs +2: second prefetch flush)
var dbg_odd: bool = false;  // last relative branch landed on an odd offset
var dbg_disp: i64 = 0;  // displacement of the last relative branch (loop span = -disp)
var dbg_shift_cnt: i64 = 0;  // effective shift count of the last shift/rotate
var fault_chg: i64 = 0;  // interrupt-entry charge when the last instruction faulted (set in do_int)
var fault_base: i64 = 0;  // partial-execution cost of the faulting instruction
var cyc_in_exec: bool = false;  // true while exec_one runs under the WS runner
var d_valid: bool = false;  // a ModRM was decoded for the current instruction
var d_rm: i64 = 0;  // rm field of the current ModRM
fn init_cyc() {
    for i in 256 { cyc_tab[i] = 4; }
    for i in 0x40 { cyc_tab[i] = 3; }  // ALU block; form splits applied in est_cycles
    cyc_tab[0x06] = 2; cyc_tab[0x0E] = 2; cyc_tab[0x16] = 2; cyc_tab[0x1E] = 2;
    cyc_tab[0x07] = 3; cyc_tab[0x17] = 3; cyc_tab[0x1F] = 3;
    cyc_tab[0x0F] = 1; cyc_tab[0x27] = 10; cyc_tab[0x2F] = 11; cyc_tab[0x37] = 10; cyc_tab[0x3F] = 10;
    for i in 0x10 { cyc_tab[0x40 + i] = 1; cyc_tab[0x50 + i] = 1; }
    for i in 8 { cyc_tab[0x58 + i] = 1; cyc_tab[0xB0 + i] = 1; cyc_tab[0xB8 + i] = 1; }
    cyc_tab[0x60] = 9; cyc_tab[0x61] = 9; cyc_tab[0x62] = 14;
    cyc_tab[0x63] = 1; cyc_tab[0x64] = 1; cyc_tab[0x65] = 1; cyc_tab[0x66] = 1; cyc_tab[0x67] = 1;
    cyc_tab[0x68] = 1; cyc_tab[0x6A] = 1; cyc_tab[0x6C] = 5; cyc_tab[0x6D] = 5; cyc_tab[0x6E] = 5; cyc_tab[0x6F] = 5;
    for i in 4 { cyc_tab[0x80 + i] = 3; }
    cyc_tab[0x84] = 2; cyc_tab[0x85] = 2; cyc_tab[0x86] = 5; cyc_tab[0x87] = 5;
    cyc_tab[0x88] = 1; cyc_tab[0x89] = 1; cyc_tab[0x8A] = 1; cyc_tab[0x8B] = 1;
    cyc_tab[0x8C] = 1; cyc_tab[0x8D] = 1; cyc_tab[0x8F] = 3;
    cyc_tab[0x90] = 1;
    for i in 7 { cyc_tab[0x91 + i] = 3; }
    cyc_tab[0x98] = 1; cyc_tab[0x99] = 1; cyc_tab[0x9A] = 8; cyc_tab[0x9B] = 10; cyc_tab[0x9C] = 2; cyc_tab[0x9D] = 3; cyc_tab[0x9E] = 4; cyc_tab[0x9F] = 2;
    for i in 4 { cyc_tab[0xA0 + i] = 1; }
    cyc_tab[0xA4] = 5; cyc_tab[0xA5] = 5; cyc_tab[0xA6] = 6; cyc_tab[0xA7] = 6; cyc_tab[0xA8] = 1; cyc_tab[0xA9] = 1;
    cyc_tab[0xAA] = 3; cyc_tab[0xAB] = 3; cyc_tab[0xAC] = 3; cyc_tab[0xAD] = 3; cyc_tab[0xAE] = 4; cyc_tab[0xAF] = 4;
    cyc_tab[0xC2] = 4; cyc_tab[0xC3] = 4; cyc_tab[0xC4] = 6; cyc_tab[0xC5] = 6; cyc_tab[0xC6] = 1; cyc_tab[0xC7] = 1;
    cyc_tab[0xC8] = 8; cyc_tab[0xC9] = 3; cyc_tab[0xCA] = 7; cyc_tab[0xCB] = 6; cyc_tab[0xCC] = 41; cyc_tab[0xCD] = 42; cyc_tab[0xCE] = 6; cyc_tab[0xCF] = 8;
    cyc_tab[0xD4] = 16; cyc_tab[0xD5] = 6; cyc_tab[0xD6] = 8; cyc_tab[0xD7] = 5;
    for i in 8 { cyc_tab[0xD8 + i] = 1; }
    cyc_tab[0xE4] = 7; cyc_tab[0xE5] = 7; cyc_tab[0xE6] = 7; cyc_tab[0xE7] = 7; cyc_tab[0xEC] = 5; cyc_tab[0xED] = 5; cyc_tab[0xEE] = 5; cyc_tab[0xEF] = 5;
    cyc_tab[0xE8] = 3; cyc_tab[0xE9] = 2; cyc_tab[0xEA] = 5; cyc_tab[0xEB] = 2;
    cyc_tab[0xF1] = 41; cyc_tab[0xF4] = 12; cyc_tab[0xF5] = 4; cyc_tab[0xF6] = 5; cyc_tab[0xF7] = 5; cyc_tab[0xFE] = 3; cyc_tab[0xFF] = 5;
    cyc_tab[0xF8] = 4; cyc_tab[0xF9] = 4; cyc_tab[0xFA] = 4; cyc_tab[0xFB] = 4; cyc_tab[0xFC] = 4; cyc_tab[0xFD] = 4;
}

// Extra cost of a two-register EA ([bx+si] style forms) over a one-register
// or direct EA, per WSTimingTest's addressing page. LEA/LES/LDS/POP-mem pay
// only 1; most other ModRM ops pay 2.
fn ea_premium(op: i64) -> i64 {
    if !d_valid || d_isreg { return 0; }
    if d_rm > 3 { return 0; }
    if op >= 0xD8 && op <= 0xDF { return 0; }
    if op == 0x8D || op == 0xC4 || op == 0xC5 || op == 0x8F { return 1; }
    return 2;
}

fn cyc_alu(op: i64) -> i64 {
    let f: i64 = op & 7;
    if f >= 6 { return cyc_tab[op]; }  // PUSH/POP segment
    if f >= 4 { return 1; }  // accumulator, immediate
    if op >= 0x38 { if d_isreg { return 1; } return 2 + ea_premium(op); }  // CMP has no writeback
    if f <= 1 { if d_isreg { return 1; } return 3 + ea_premium(op); }  // r/m destination (read-modify-write)
    if d_isreg { return 1; } return 2 + ea_premium(op);  // register destination, memory source
}

fn cyc_f6f7(op: i64) -> i64 {
    if d_reg == 0 { return 2; }
    if d_reg == 1 { return 1; }
    if d_reg == 2 || d_reg == 3 { return 3; }
    if d_reg == 4 || d_reg == 5 { return 4; }
    if d_reg == 6 { if op == 0xF6 { return 16; } return 24; }
    if d_reg == 7 { if op == 0xF6 { return 18; } return 25; }
    return 5;
}

fn cyc_ff() -> i64 {
    if d_reg == 0 || d_reg == 1 { if d_isreg { return 1; } return 3; }
    if d_reg == 2 { return 4; }
    if d_reg == 3 { return 12; }
    if d_reg == 4 { return 4; }
    if d_reg == 5 { return 8; }
    if d_reg == 6 { return 2; }
    return 1;
}

fn cyc_fe() -> i64 {
    if d_reg == 0 || d_reg == 1 { if d_isreg { return 1; } return 3; }
    if d_reg == 6 { return 2; }
    if d_reg >= 2 && d_reg <= 5 { return cyc_ff(); }  // the mirrored FF transfers
    return 1;
}

fn cyc_loop(op: i64) -> i64 {
    if op == 0xE3 { return 2; }
    if !dbg_taken { return 2; }
    if dbg_back { return 6; }
    if op == 0xE2 { return 3; }
    return 4;
}

fn rep_cost(op: i64, n: i64) -> i64 {
    if n == 0 { return 5; }
    if op == 0xA4 || op == 0xA5 { return 5 + 7 * n; }
    if op == 0xA6 || op == 0xA7 { return 5 + 10 * n; }
    if op == 0xAE || op == 0xAF { return 5 + 9 * n; }
    return 5 + 6 * n;
}

// Partial-execution cost of a faulting instruction, before the 44-cycle
// interrupt entry (fitted from WSTimingTest's exception page).
fn cyc_fault_base() -> i64 {
    if dbg_op == 0xF6 || dbg_op == 0xF7 { if d_reg == 7 { return 8; } return 5; }
    if dbg_op == 0xD4 { return 4; }
    if dbg_op == 0x62 { return 9; }
    if dbg_op == 0xCE { return 1; }
    return 0;
}

fn est_cycles(pre_cx: i64) -> i64 {
    let op: i64 = dbg_op;
    if fault_chg > 0 { xfer_flag = true; return fault_base + fault_chg; }
    var c: i64 = 0;
    var is_tail: bool = false;
    var sets_xfer: bool = false;
    if rep_prefix != 0 && ((op >= 0xA4 && op <= 0xAF) || (op >= 0x6C && op <= 0x6F)) {
        var n: i64 = pre_cx - (r[1] as i64); if n < 0 { n += 65536; }
        c = rep_cost(op, n);
    }
    else if op == 0xF6 || op == 0xF7 { c = cyc_f6f7(op) + ea_premium(op); }
    else if op == 0xFF { c = cyc_ff() + ea_premium(op); if d_reg >= 2 && d_reg <= 5 { sets_xfer = true; } }
    else if op == 0xFE { c = cyc_fe() + ea_premium(op); if d_reg >= 2 && d_reg <= 5 { sets_xfer = true; } }
    else if op >= 0x70 && op <= 0x7F {
        if dbg_taken {
            sets_xfer = true;
            if dbg_back { is_tail = true; c = 5; } else { c = 2; }
            if dbg_odd { c += 1; }
        } else { c = 1; }
    }
    else if op >= 0xE0 && op <= 0xE3 {
        c = cyc_loop(op);
        if dbg_taken { sets_xfer = true; if dbg_back { is_tail = true; } }
    }
    else if (op >= 0xC0 && op <= 0xC1) || (op >= 0xD0 && op <= 0xD3) { var sc: i64 = dbg_shift_cnt; if sc > 2 { sc = 2; } c = 1 + 2 * sc + ea_premium(op); }
    else if op < 0x40 { c = cyc_alu(op); }
    else if op == 0x69 || op == 0x6B { if d_isreg { c = 3; } else { c = 4 + ea_premium(op); } }
    else if op == 0x84 || op == 0x85 { if d_isreg { c = 1; } else { c = 2 + ea_premium(op); } }
    else if op == 0x86 || op == 0x87 { if d_isreg { c = 3; } else { c = 5 + ea_premium(op); } }
    else if op == 0x8E { if d_isreg { c = 2; } else { c = 3 + ea_premium(op); } }
    else if op == 0x8F { if d_isreg { c = 1; } else { c = 3 + ea_premium(op); } }
    else if op >= 0x80 && op <= 0x83 { if d_isreg { c = 1; } else { c = 3 + ea_premium(op); } }
    else if op == 0xC4 || op == 0xC5 { if d_isreg { c = 8; } else { c = 6 + ea_premium(op); } }
    else {
        c = cyc_tab[op] + ea_premium(op);
        if (op == 0xE9 || op == 0xEB) && dbg_odd { c += 1; }
        if op == 0xE8 || op == 0xE9 || op == 0xEA || op == 0xEB || op == 0x9A || op == 0xC2 || op == 0xC3 || op == 0xCA || op == 0xCB || op == 0xCF { sets_xfer = true; }
    }
    if is_tail { if xfer_flag { c += 2; } else if op >= 0x70 && op <= 0x7F && 0 - dbg_disp <= 4 { c -= 1; } xfer_flag = false; }
    else if sets_xfer { xfer_flag = true; }
    return c;
}

fn phys(s: u16, off: u16) -> i64 { (((s as i64) << 4) + (off as i64)) & 0xFFFFF }
fn rb16(p: i64) -> u16 { (rd8(p) as u16) | ((rd8((p + 1) & 0xFFFFF) as u16) << 8) }
// Word access through a segment: the second byte wraps at the 64 KB offset
// boundary (offset 0xFFFF is followed by offset 0x0000), as on real hardware.
fn seg_rd16(base: i64, off: i64) -> u16 { (rd8((base + off) & 0xFFFFF) as u16) | ((rd8((base + ((off + 1) & 0xFFFF)) & 0xFFFFF) as u16) << 8) }
fn seg_wr16(base: i64, off: i64, v: u16) { wb8((base + off) & 0xFFFFF, v as! u8); wb8((base + ((off + 1) & 0xFFFF)) & 0xFFFFF, (v >> 8) as! u8); }
// Flat-memory mode (ws_mode off) is the CPU test bus the
// SingleStepTests harness drives: writes are recorded so a case can
// restore RAM afterwards; recording is on only while a case executes.
var touched: i64[>..<] = [];
var recording: bool = false;

fn wb8(p: i64, v: u8) {
    if ws_mode {
        if p < 0x10000 { mem[p] = v; }
        else if p < 0x20000 { if sram_size > 0 { sram[((ram_bank() << 16) | (p & 0xFFFF)) % sram_size] = v; } }
        return;  // writes into the ROM windows are ignored
    }
    mem[p] = v; if recording { touched.push(p); }
}
fn wb16(p: i64, v: u16) { wb8(p, v as! u8); wb8((p + 1) & 0xFFFFF, (v >> 8) as! u8); }

fn fetch8() -> u8 { let v = rd8(phys(seg[1], ip)); ip = ip + 1; v }
fn fetch16() -> u16 { let lo = fetch8(); let hi = fetch8(); ((hi as u16) << 8) | (lo as u16) }

fn get_r8(i: i64) -> u8 {
    if i < 4 { (r[i] & 0xFF) as! u8 } else { (r[i - 4] >> 8) as! u8 }
}
fn set_r8(i: i64, v: u8) {
    if i < 4 { r[i] = (r[i] & 0xFF00) | (v as u16); }
    else { r[i - 4] = (r[i - 4] & 0x00FF) | ((v as u16) << 8); }
}

// ---- ModRM decode (16-bit addressing) ----
var seg_override: i64 = -1;  // segment override prefix, -1 = none
var rep_prefix: i64 = 0;  // 0 = none, 2 = REPNE (F2), 3 = REP/REPE (F3), 4 = V20 rep-while-CF=0 (64), 5 = V20 rep-while-CF=1 (65)
var cpu_v20: bool = false;  // NEC V20 profile, selected by the "v20" CLI argument
var cpu_mz: bool = false;   // V30MZ deltas on top of the V20 profile (WSCpuTest authority), set by the WS runner
var dbg_op: i64 = 0;        // last opcode byte executed (after prefixes), for runner diagnostics
var dbg_ip: i64 = 0;        // ip at which it started
var d_reg: i64 = 0;
var d_isreg: bool = false;
var d_regidx: i64 = 0;
var d_addr: i64 = 0;
var d_segbase: i64 = 0;
var d_off: i64 = 0;

fn decode_modrm() {
    let m = fetch8();
    let mod: i64 = m >> 6;
    d_reg = (m >> 3) & 7;
    let rm: i64 = m & 7;
    d_rm = rm; d_valid = true;
    if mod == 3 { d_isreg = true; d_regidx = rm; d_off = 0; d_segbase = 0;
        if cpu_mz {
            // V30MZ quirk (WSCpuTest): with mod=3 the EA adder still runs,
            // fed with the form's first register and the rm register itself
            // (LEA DX,[BX+AX] = BX+AX; LES with mod=3 reads at that EA).
            // Form-first registers by rm: BX,BX,BP,BP,SI,DI,BP,BX.
            var ff: i64 = 3;
            if rm == 2 || rm == 3 || rm == 6 { ff = 5; }
            else if rm == 4 { ff = 6; }
            else if rm == 5 { ff = 7; }
            else if rm == 7 { ff = 3; }
            d_off = ((r[ff] as i64) + (r[rm] as i64)) & 0xFFFF;
            var msidx: i64 = if rm == 2 || rm == 3 || rm == 6 { 2 } else { 3 };
            if seg_override >= 0 { msidx = seg_override; }
            d_segbase = (seg[msidx] as i64) << 4;
            d_addr = (d_segbase + d_off) & 0xFFFFF;
        }
        return; }
    d_isreg = false;
    var base: i64 = 0;
    var sidx: i64 = 3;  // DS by default
    if rm == 0 { base = (r[3] as i64) + (r[6] as i64); }              // bx+si
    else if rm == 1 { base = (r[3] as i64) + (r[7] as i64); }         // bx+di
    else if rm == 2 { base = (r[5] as i64) + (r[6] as i64); sidx = 2; }  // bp+si
    else if rm == 3 { base = (r[5] as i64) + (r[7] as i64); sidx = 2; }  // bp+di
    else if rm == 4 { base = r[6] as i64; }                           // si
    else if rm == 5 { base = r[7] as i64; }                           // di
    else if rm == 6 {
        if mod == 0 { let ds: i64 = if seg_override >= 0 { seg_override } else { 3 }; d_segbase = (seg[ds] as i64) << 4; d_off = fetch16() as i64; d_addr = (d_segbase + d_off) & 0xFFFFF; return; }  // direct disp16
        base = r[5] as i64; sidx = 2;                                 // bp
    }
    else { base = r[3] as i64; }                                      // bx
    if seg_override >= 0 { sidx = seg_override; }
    var disp: i64 = 0;
    if mod == 1 { let d8 = fetch8(); let d8i: i64 = d8; disp = if d8i > 127 { d8i - 256 } else { d8i }; }
    else if mod == 2 { disp = fetch16() as i64; }
    let ea: i64 = (base + disp) & 0xFFFF;
    d_segbase = (seg[sidx] as i64) << 4;
    d_off = ea;
    d_addr = (d_segbase + ea) & 0xFFFFF;
}

fn read_rm(size16: bool) -> i64 {
    if d_isreg { if size16 { r[d_regidx] as i64 } else { get_r8(d_regidx) as i64 } }
    else if size16 { seg_rd16(d_segbase, d_off) as i64 } else { rd8(d_addr) as i64 }
}
fn write_rm(size16: bool, v: i64) {
    if d_isreg {
        if size16 { r[d_regidx] = v as! u16; } else { set_r8(d_regidx, v as! u8); }
    } else {
        if size16 { seg_wr16(d_segbase, d_off, v as! u16); } else { wb8(d_addr, v as! u8); }
    }
}

// ---- Flags ----
fn parity_even(v: i64) -> bool {
    var p: i64 = 0; var x: i64 = v;
    for i in 8 { p += x & 1; x = x >> 1; }
    p % 2 == 0
}
fn alu_op(kind: i64, a: i64, b: i64, bits: i64) -> i64 {
    // kind: 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP
    // a and b are unsigned values already masked to the operand width.
    let mask: i64 = if bits == 16 { 0xFFFF } else { 0xFF };
    let sign: i64 = if bits == 16 { 0x8000 } else { 0x80 };
    let cf_in: i64 = if (flags & 1) != 0 { 1 } else { 0 };
    var res: i64 = 0; var cf_out: i64 = 0; var af: i64 = 0; var of: i64 = 0;
    if kind == 0 || kind == 2 {  // ADD / ADC
        let c: i64 = if kind == 2 { cf_in } else { 0 };
        let full: i64 = a + b + c;
        res = full & mask;
        cf_out = if full > mask { 1 } else { 0 };
        af = if ((a & 0xF) + (b & 0xF) + c) > 0xF { 1 } else { 0 };
        of = if ((a ^ res) & (b ^ res) & sign) != 0 { 1 } else { 0 };
    } else if kind == 5 || kind == 3 || kind == 7 {  // SUB / SBB / CMP
        let c: i64 = if kind == 3 { cf_in } else { 0 };
        res = (a - b - c) & mask;
        cf_out = if a < b + c { 1 } else { 0 };
        af = if (a & 0xF) < (b & 0xF) + c { 1 } else { 0 };
        of = if ((a ^ b) & (a ^ res) & sign) != 0 { 1 } else { 0 };
    } else {  // OR / AND / XOR (and TEST via AND)
        if kind == 1 { res = a | b; } else if kind == 4 { res = a & b; } else { res = a ^ b; }
        res = res & mask;
    }
    var f: i64 = (flags as i64) & 0xF72A;  // keep non-arithmetic bits
    if cf_out == 1 { f |= 0x0001; }
    if parity_even(res & 0xFF) { f |= 0x0004; }
    if af == 1 { f |= 0x0010; }
    if res == 0 { f |= 0x0040; }
    if (res & sign) != 0 { f |= 0x0080; }
    if of == 1 { f |= 0x0800; }
    flags = f as! u16;
    return res;
}


fn incdec_flags(a: i64, res: i64, dec: bool, bits: i64) {
    let sign: i64 = if bits == 16 { 0x8000 } else { 0x80 };
    var f: i64 = (flags as i64) & 0xF72B;  // INC/DEC preserve CF
    if parity_even(res & 0xFF) { f |= 0x0004; }
    if dec { if (a & 0xF) == 0 { f |= 0x0010; } } else { if (a & 0xF) == 0xF { f |= 0x0010; } }
    if res == 0 { f |= 0x0040; }
    if (res & sign) != 0 { f |= 0x0080; }
    if dec { if a == sign { f |= 0x0800; } } else { if res == sign { f |= 0x0800; } }
    flags = f as! u16;
}
fn do_incdec(v: i64, dec: bool, bits: i64) -> i64 {
    let mask: i64 = if bits == 16 { 0xFFFF } else { 0xFF };
    let res: i64 = if dec { (v - 1) & mask } else { (v + 1) & mask };
    incdec_flags(v, res, dec, bits);
    return res;
}
fn push16(v: i64) { r[4] = r[4] - 2; seg_wr16((seg[2] as i64) << 4, r[4] as i64, v as! u16); }
fn pop16() -> i64 { let v: i64 = seg_rd16((seg[2] as i64) << 4, r[4] as i64); r[4] = r[4] + 2; v }


fn cond(c: i64) -> bool {
    let f: i64 = flags;
    let cf = f & 1; let pf = (f >> 2) & 1; let zf = (f >> 6) & 1;
    let sf = (f >> 7) & 1; let of = (f >> 11) & 1;
    if c == 0 { of == 1 } else if c == 1 { of == 0 }
    else if c == 2 { cf == 1 } else if c == 3 { cf == 0 }
    else if c == 4 { zf == 1 } else if c == 5 { zf == 0 }
    else if c == 6 { cf == 1 || zf == 1 } else if c == 7 { cf == 0 && zf == 0 }
    else if c == 8 { sf == 1 } else if c == 9 { sf == 0 }
    else if c == 10 { pf == 1 } else if c == 11 { pf == 0 }
    else if c == 12 { sf != of } else if c == 13 { sf == of }
    else if c == 14 { zf == 1 || sf != of } else { zf == 0 && sf == of }
}
fn disp8s() -> i64 { let b = fetch8(); let bi: i64 = b; if bi > 127 { bi - 256 } else { bi } }
fn disp16s() -> i64 { let v = fetch16(); let vi: i64 = v; if vi > 32767 { vi - 65536 } else { vi } }
fn rel_jump(d: i64) { ip = (((ip as i64) + d) & 0xFFFF) as! u16; dbg_head = ip as i64; dbg_odd = ((ip as i64) & 1) != 0; dbg_disp = d; }
// Interrupt acceptance (after Swanium's cpu): an instruction that
// sets IF (STI, POPF/IRET turning IF on) or loads SS (POP SS, MOV SS)
// holds maskable IRQs off for one more instruction; POPF/IRET turning
// TF on likewise defer the first trap by one instruction. An IRQ that
// lands right after a long REP string instruction (>= 256 cycles)
// returns to that instruction's first prefix byte, as hardware
// restarts it (ws-test-suite prefixes: REP:ESx8:MOVSB(IRQ)).
var irq_inhibit: i64 = 0;
var trap_inhibit: i64 = 0;
var irq_ret_override: i64 = -1;

fn do_int(n: i64) { do_int_at(n, ip as i64); }
fn do_int_at(n: i64, ret_ip: i64) {
    if cyc_in_exec && dbg_op != 0xCC && dbg_op != 0xCD && dbg_op != 0xF1 { fault_chg = 44; fault_base = cyc_fault_base(); }  // fault/interrupt-entry charge for the cycle estimator (INT opcodes carry theirs in cyc_tab)
    push16(flags as i64);
    push16(seg[1] as i64);
    push16(ret_ip);
    flags = flags & 0xFCFF;  // clear TF and IF after pushing the original flags
    ip = seg_rd16(0, n * 4);
    seg[1] = seg_rd16(0, n * 4 + 2);
}


fn s8(v: i64) -> i64 { if v > 127 { v - 256 } else { v } }
fn s16(v: i64) -> i64 { if v > 32767 { v - 65536 } else { v } }
fn s32(v: i64) -> i64 { if v > 2147483647 { v - 4294967296 } else { v } }
fn set_szp(res: i64, bits: i64) {
    let sign: i64 = if bits == 16 { 0x8000 } else { 0x80 };
    var f: i64 = (flags as i64) & 0xFF3B;  // clear SF/ZF/PF only
    if parity_even(res & 0xFF) { f |= 0x0004; }
    if res == 0 { f |= 0x0040; }
    if (res & sign) != 0 { f |= 0x0080; }
    flags = f as! u16;
}
fn shift_op(kind: i64, v: i64, count: i64, bits: i64) -> i64 {
    // kind: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 7 SAR (6 is SETMO, handled by the caller)
    // On this CPU the flags behave as if latched from the final 1-bit step.
    var cnt: i64 = count;
    if cpu_mz { cnt = cnt & 0x1F; }  // V30MZ masks the count to 5 bits before shifting (WSCpuTest)
    dbg_shift_cnt = cnt;
    if kind <= 3 && cpu_mz && cnt == 0 {
        // V30MZ (per WSCpuTest): a rotate whose count is a multiple of 32
        // leaves the operand and CF untouched but still recomputes OF.
        let msbz = (v >> (bits - 1)) & 1;
        var ofz: i64 = 0;
        if kind == 0 || kind == 2 { ofz = ((flags as i64) & 1) ^ msbz; } else { ofz = msbz ^ ((v >> (bits - 2)) & 1); }
        var fz: i64 = (flags as i64) & 0xF7FF;
        if ofz == 1 { fz |= 0x0800; }
        flags = fz as! u16;
        return v;
    }
    if cnt == 0 && !(cpu_mz && kind >= 4) { return v; }
    let mask: i64 = if bits == 16 { 0xFFFF } else { 0xFF };
    let top: i64 = bits - 1;
    if cnt == 0 {
        // V30MZ: a shift whose masked count is 0 keeps the operand and
        // CF, latches SZP from the operand, clears AF, and recomputes OF
        // with the one-bit formula (MSB XOR CF for SHL) (WSCpuTest).
        var f0: i64 = (flags as i64) & 0xF72B;
        if parity_even(v & 0xFF) { f0 |= 0x0004; }
        if v == 0 { f0 |= 0x0040; }
        if (v & (1 << top)) != 0 { f0 |= 0x0080; }
        if kind == 4 { if (((v >> top) & 1) ^ ((flags as i64) & 1)) == 1 { f0 |= 0x0800; } }
        else if kind == 5 || kind == 7 { if (((v >> top) & 1) ^ ((v >> (top - 1)) & 1)) == 1 { f0 |= 0x0800; } }  // SHR/SAR: OF = top two bits XORed
        flags = f0 as! u16;
        return v;
    }
    var cf: i64 = (flags as i64) & 1;
    var res: i64 = v;
    if kind <= 3 {  // rotates: only CF and OF change
        for i in cnt {
            if kind == 0 { let nb = (res >> top) & 1; res = ((res << 1) & mask) | nb; cf = nb; }
            else if kind == 1 { let nb = res & 1; res = (res >> 1) | (nb << top); cf = nb; }
            else if kind == 2 { let nb = (res >> top) & 1; res = ((res << 1) & mask) | cf; cf = nb; }
            else { let nb = res & 1; res = (res >> 1) | (cf << top); cf = nb; }
        }
        var f: i64 = (flags as i64) & 0xF7FE;
        if cf == 1 { f |= 1; }
        let msb = (res >> top) & 1;
        var of: i64 = 0;
        if kind == 0 || kind == 2 { of = cf ^ msb; } else { of = msb ^ ((res >> (top - 1)) & 1); }
        if of == 1 { f |= 0x0800; }
        flags = f as! u16;
        return res;
    }
    for i in cnt {
        if kind == 4 { cf = (res >> top) & 1; res = (res << 1) & mask; }
        else if kind == 5 { cf = res & 1; res = res >> 1; }
        else { cf = res & 1; res = (res >> 1) | (res & (1 << top)); }
    }
    var f: i64 = (flags as i64) & 0xF72A;
    if cf == 1 { f |= 1; }
    if parity_even(res & 0xFF) { f |= 0x0004; }
    if res == 0 { f |= 0x0040; }
    if (res & (1 << top)) != 0 { f |= 0x0080; }
    if kind == 4 {  // SHL: AF is bit 3 of the pre-final value (= bit 4 of the result); OF as for one bit
        if !cpu_v20 && ((res >> 4) & 1) == 1 { f |= 0x0010; }
        if (cf ^ ((res >> top) & 1)) == 1 { f |= 0x0800; }
    } else if kind == 5 {  // SHR: OF is the pre-final value's top bit (= result bit top-1); AF = 0
        if ((res >> (top - 1)) & 1) == 1 { f |= 0x0800; }
    }  // SAR: OF = 0, AF = 0
    flags = f as! u16;
    return res;
}
var unit_cfof: i64 = 0;  // V30MZ multiply/divide unit's stale CF/OF: set by MUL/IMUL, latched into FLAGS by DIV8 and by faulting DIV8/IDIV8/AAM (WSCpuTest calcs set it up with a preceding mul/imul)
fn mz_mul_flags(ov: i64) { unit_cfof = ov; flags = (((flags as i64) & 0xF700) | (if ov != 0 { 0x0801 } else { 0 }) | 0x0042) as! u16; }
fn mz_div_flags(cfof: i64, zf: i64) { flags = (((flags as i64) & 0xF700) | (if cfof != 0 { 0x0801 } else { 0 }) | (if zf != 0 { 0x40 } else { 0 }) | 0x02) as! u16; }
fn divu8_err_zf(dvd: i64, dvs: i64) -> i64 {
    if dvs == 0 { if (dvd & 0x3FC0) == 0 { return 1; } return 0; }
    let bx: i64 = ((256 - dvs) & 0xFF) << 6;
    var dx: i64 = dvd & 0xFFC0;
    dx = (dx + bx) & 0xFFFF; if dx == 0 { return 1; }
    dx = (dx + bx) & 0xFFFF; dx = (dx + bx) & 0xFFFF; if dx == 0 { return 1; }
    return 0;
}
fn divu16_err_zf(dxh: i64, axv: i64, dvs: i64) -> i64 {
    if dvs == 0 { if (dxh & 0x3FFF) == 0 && (axv & 0xC000) == 0 { return 1; } return 0; }
    let nb: i64 = (0 - dvs) & 0xFFFF;
    let al: i64 = ((nb & 0xFF) << 6) & 0xFF;
    let bx: i64 = nb >> 2;
    var ah: i64 = (axv >> 8) & 0xC0;
    var dx: i64 = dxh;
    var s: i64 = ah + al; var c: i64 = if s > 0xFF { 1 } else { 0 }; ah = s & 0xFF; dx = (dx + bx + c) & 0xFFFF;
    if (((dx >> 8) & 0xFF) | (dx & 0xFF) | ah) == 0 { return 1; }
    s = ah + al; c = if s > 0xFF { 1 } else { 0 }; ah = s & 0xFF; dx = (dx + bx + c) & 0xFFFF;
    s = ah + al; c = if s > 0xFF { 1 } else { 0 }; ah = s & 0xFF;
    if ah != 0 { return 0; }
    dx = (dx + bx + c) & 0xFFFF; if dx == 0 { return 1; }
    return 0;
}  // V30MZ (colour): MUL/IMUL status is constant apart from CF/OF: SF=0 ZF=1 AF=0 PF=0
fn mul_flags(high: i64, bits: i64) {
    if cpu_mz { mz_mul_flags(if high != 0 { 1 } else { 0 }); return; }
    var f: i64 = (flags as i64) & 0xF72A;
    if high != 0 { f |= 0x0801; }  // CF and OF
    if parity_even(high & 0xFF) { f |= 0x0004; }
    if high == 0 { f |= 0x0040; }
    let sign: i64 = if bits == 16 { 0x8000 } else { 0x80 };
    if (high & sign) != 0 { f |= 0x0080; }
    flags = f as! u16;
}
fn set_cf_of(cf: i64, of: i64) {
    var f: i64 = (flags as i64) & 0xF7FE;  // MUL/IMUL define CF and OF only
    if cf == 1 { f |= 1; }
    if of == 1 { f |= 0x0800; }
    flags = f as! u16;
}
fn flag_inhibits(old: i64) {
    if (old & 0x0200) == 0 && (flags & 0x0200) != 0 { irq_inhibit = 1; }
    if (old & 0x0100) == 0 && (flags & 0x0100) != 0 { trap_inhibit = 1; }
}
fn load_flags(v: i64) { flags = (((v & 0x0FD5) | 0xF002) as! u16); }  // bits 12-15 read as 1, bit 1 as 1, bits 3/5 as 0
fn src_seg_base(def: i64) -> i64 { let s: i64 = if seg_override >= 0 { seg_override } else { def }; (seg[s] as i64) << 4 }
fn trunc_divmod(a: i64, b: i64) -> i64, i64 {
    let aa: i64 = if a < 0 { 0 - a } else { a };
    let bb: i64 = if b < 0 { 0 - b } else { b };
    let qa: i64 = aa / bb;
    let neg: bool = (a < 0 && b > 0) || (a > 0 && b < 0);
    let q: i64 = if neg { 0 - qa } else { qa };
    return q, a - q * b;
}


fn str_step(op: i64) {
    let size16: bool = (op & 1) == 1;
    let step: i64 = if size16 { 2 } else { 1 };
    let delta: i64 = if (flags & 0x0400) != 0 { 0 - step } else { step };
    let sbase: i64 = src_seg_base(3);              // DS, override-aware
    let dbase: i64 = (seg[0] as i64) << 4;         // ES is never overridden
    if op == 0xA4 || op == 0xA5 {  // MOVS
        if size16 { seg_wr16(dbase, r[7] as i64, seg_rd16(sbase, r[6] as i64)); } else { wb8((dbase + (r[7] as i64)) & 0xFFFFF, rd8((sbase + (r[6] as i64)) & 0xFFFFF)); }
        r[6] = (((r[6] as i64) + delta) & 0xFFFF) as! u16;
        r[7] = (((r[7] as i64) + delta) & 0xFFFF) as! u16;
    } else if op == 0xA6 || op == 0xA7 {  // CMPS
        let a: i64 = if size16 { seg_rd16(sbase, r[6] as i64) as i64 } else { rd8((sbase + (r[6] as i64)) & 0xFFFFF) as i64 };
        let b: i64 = if size16 { seg_rd16(dbase, r[7] as i64) as i64 } else { rd8((dbase + (r[7] as i64)) & 0xFFFFF) as i64 };
        alu_op(5, a, b, if size16 { 16 } else { 8 });
        r[6] = (((r[6] as i64) + delta) & 0xFFFF) as! u16;
        r[7] = (((r[7] as i64) + delta) & 0xFFFF) as! u16;
    } else if op == 0xAA || op == 0xAB {  // STOS
        if size16 { seg_wr16(dbase, r[7] as i64, r[0]); } else { wb8((dbase + (r[7] as i64)) & 0xFFFFF, get_r8(0)); }
        r[7] = (((r[7] as i64) + delta) & 0xFFFF) as! u16;
    } else if op == 0xAC || op == 0xAD {  // LODS
        if size16 { r[0] = seg_rd16(sbase, r[6] as i64); } else { set_r8(0, rd8((sbase + (r[6] as i64)) & 0xFFFFF)); }
        r[6] = (((r[6] as i64) + delta) & 0xFFFF) as! u16;
    } else if op == 0x6C || op == 0x6D {  // INS: the port value (open bus) goes to ES:DI
        if size16 { seg_wr16(dbase, r[7] as i64, 0xFFFF); } else { wb8((dbase + (r[7] as i64)) & 0xFFFFF, 0xFF); }
        r[7] = (((r[7] as i64) + delta) & 0xFFFF) as! u16;
    } else if op == 0x6E || op == 0x6F {  // OUTS: only the pointer moves (the port write is unobservable)
        r[6] = (((r[6] as i64) + delta) & 0xFFFF) as! u16;
    } else {  // SCAS (AE/AF)
        let b: i64 = if size16 { seg_rd16(dbase, r[7] as i64) as i64 } else { rd8((dbase + (r[7] as i64)) & 0xFFFFF) as i64 };
        let a: i64 = if size16 { r[0] as i64 } else { get_r8(0) as i64 };
        alu_op(5, a, b, if size16 { 16 } else { 8 });
        r[7] = (((r[7] as i64) + delta) & 0xFFFF) as! u16;
    }
}


// ---- NEC V20/V30 extended instructions (0F-prefixed) ----
fn bcd4_step(d: i64, s: i64, cin: i64, sub: bool) -> i64, i64 {
    // One byte of an ADD4S/SUB4S/CMP4S string: a binary add/sub followed by a
    // DAA/DAS-style correction; the low digit's +6 carries into the high digit
    // like a binary carry, which is where it differs from per-digit BCD.
    if !sub {
        let t: i64 = d + s + cin;
        let lo: i64 = (d & 0xF) + (s & 0xF) + cin;
        var adj: i64 = 0;
        if lo > 9 { adj += 6; }
        let hi: i64 = (d >> 4) + (s >> 4) + (if lo > 9 { 1 } else { 0 });
        if hi > 9 { adj += 0x60; }
        let res: i64 = t + adj;
        return res & 0xFF, if hi > 9 { 1 } else { 0 };
    }
    let t: i64 = d - s - cin;
    let lo: i64 = (d & 0xF) - (s & 0xF) - cin;
    var adj: i64 = 0;
    if lo < 0 || lo > 9 { adj += 6; }
    let hi: i64 = (d >> 4) - (s >> 4) - (if lo < 0 { 1 } else { 0 });
    let a60: bool = hi < 0 || hi > 9 || (hi == 9 && lo > 9);
    if a60 { adj += 0x60; }
    let res: i64 = t - adj;
    return res & 0xFF, if a60 { 1 } else { 0 };
}

fn op_bcd4(op2: i64) {
    let sub: bool = op2 != 0x20;
    let cnt: i64 = get_r8(1) as i64;  // digit count is CL; bytes processed = ceil(cnt/2), last one in full
    let sbase: i64 = src_seg_base(3);
    let dbase: i64 = (seg[0] as i64) << 4;
    let soff: i64 = r[6] as i64;
    let doff: i64 = r[7] as i64;
    var carry: i64 = 0;
    var allzero: bool = true;
    let nb: i64 = (cnt + 1) / 2;
    var i: i64 = 0;
    while i < nb {
        let db: i64 = rd8((dbase + ((doff + i) & 0xFFFF)) & 0xFFFFF) as i64;
        let sb: i64 = rd8((sbase + ((soff + i) & 0xFFFF)) & 0xFFFFF) as i64;
        let res, cout = bcd4_step(db, sb, carry, sub);
        if op2 != 0x26 { wb8((dbase + ((doff + i) & 0xFFFF)) & 0xFFFFF, res as! u8); }
        if res != 0 { allzero = false; }
        carry = cout;
        i += 1;
    }
    var f: i64 = (flags as i64) & 0xF72A;
    if carry == 1 { f |= 1; }
    if cnt > 0 && allzero { f |= 0x0040; }
    flags = f as! u16;
}

fn str_digit(base: i64, off: i64, i: i64) -> i64 {
    let b: i64 = rd8((base + ((off + (i >> 1)) & 0xFFFF)) & 0xFFFFF) as i64;
    if (i & 1) == 0 { b & 0xF } else { (b >> 4) & 0xF }
}
fn set_str_digit(base: i64, off: i64, i: i64, v: i64) {
    let a: i64 = (base + ((off + (i >> 1)) & 0xFFFF)) & 0xFFFFF;
    let b: i64 = mem[a] as i64;
    if (i & 1) == 0 { wb8(a, ((b & 0xF0) | v) as! u8); } else { wb8(a, ((b & 0x0F) | (v << 4)) as! u8); }
}

fn op_rol4(op2: i64) {
    decode_modrm();
    let cnt: i64 = get_r8(1) as i64;  // digit count is CL
    if d_isreg || cnt <= 2 {
        let v = read_rm(false);
        write_rm(false, (((v << 4) | (v >> 4)) & 0xFF) as! i64);
        return;
    }
    if op2 == 0x28 {  // ROL4: each digit takes the next-higher digit; the top digit wraps to the bottom
        let save: i64 = str_digit(d_segbase, d_off, 0);
        var i: i64 = 0;
        while i < cnt - 1 { set_str_digit(d_segbase, d_off, i, str_digit(d_segbase, d_off, i + 1)); i += 1; }
        set_str_digit(d_segbase, d_off, cnt - 1, save);
    } else {  // ROR4
        let save: i64 = str_digit(d_segbase, d_off, cnt - 1);
        var i: i64 = cnt - 1;
        while i > 0 { set_str_digit(d_segbase, d_off, i, str_digit(d_segbase, d_off, i - 1)); i -= 1; }
        set_str_digit(d_segbase, d_off, 0, save);
    }
}

fn op_bins_ext(op2: i64) {
    // reg field = bit count minus one; r/m = the running bit offset register.
    // BINS inserts the low bits of AX into the string at ES:DI; BEXT extracts
    // a field from the string at DS:SI into AX.
    decode_modrm();
    let is_bins: bool = op2 == 0x31 || op2 == 0x39;
    let offv: i64 = read_rm(false);
    let cnt: i64 = if op2 == 0x39 || op2 == 0x3B { (fetch8() as i64) + 1 } else { (get_r8(d_reg) as i64) + 1 };
    // The pointer is word-oriented: the offset register holds a bit position
    // within the current word (0-15); SI/DI advance by 2 per full word crossed.
    let adv: i64 = 2 * ((offv + cnt) >> 4);
    if is_bins {
        let axv: i64 = r[0] as i64;
        let dbase: i64 = (seg[0] as i64) << 4;
        let doff: i64 = r[7] as i64;
        var k: i64 = 0;
        while k < cnt {
            let pos: i64 = offv + k;
            let a: i64 = (dbase + ((doff + (pos >> 3)) & 0xFFFF)) & 0xFFFFF;
            let b: i64 = rd8(a) as i64;
            let nb: i64 = if ((axv >> k) & 1) == 1 { b | (1 << (pos & 7)) } else { b & ~(1 << (pos & 7)) };
            wb8(a, nb as! u8);
            k += 1;
        }
        r[7] = ((doff + adv) & 0xFFFF) as! u16;
    } else {
        let sbase: i64 = src_seg_base(3);
        let soff: i64 = r[6] as i64;
        var res: i64 = 0;
        var k: i64 = 0;
        while k < cnt {
            let pos: i64 = offv + k;
            let b: i64 = rd8((sbase + ((soff + (pos >> 3)) & 0xFFFF)) & 0xFFFFF) as i64;
            if ((b >> (pos & 7)) & 1) == 1 { res |= 1 << k; }
            k += 1;
        }
        r[0] = res as! u16;
        r[6] = ((soff + adv) & 0xFFFF) as! u16;
    }
    write_rm(false, (offv + cnt) & 15);
    var f: i64 = (flags as i64) & 0xF72A;
    if ((offv + cnt) & 15) == 0 { f |= 0x0040; }
    flags = f as! u16;
}

// ---- Instruction slice ----
// FF /2-/5 (and FE /2-/5 on the MZ): CALL / CALL far / JMP / JMP far
// through a word operand; ModRM already decoded.
fn ff_xfer() -> bool {
    if d_reg == 2 { let t = read_rm(true); push16(ip as i64); ip = t as! u16; return true; }  // CALL Ev
    if d_reg == 3 { if d_isreg && !cpu_mz { return false; } let nip: i64 = seg_rd16(d_segbase, d_off); let ncs: i64 = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); push16(seg[1] as i64); push16(ip as i64); ip = nip as! u16; seg[1] = ncs as! u16; return true; }  // CALL far Ev (mod=3 on the MZ reads at the adder EA)
    if d_reg == 4 { ip = read_rm(true) as! u16; return true; }  // JMP Ev
    if d_isreg && !cpu_mz { return false; } ip = seg_rd16(d_segbase, d_off); seg[1] = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); return true;  // JMP far Ev (mod=3 on the MZ reads at the adder EA)
}

fn exec_one() -> bool {
    seg_override = -1;
    rep_prefix = 0;
    dbg_ip = ip as i64;
    var op = fetch8();
    while op == 0x26 || op == 0x2E || op == 0x36 || op == 0x3E || op == 0xF0 || op == 0xF2 || op == 0xF3 || (cpu_v20 && !cpu_mz && (op == 0x64 || op == 0x65)) {
        if op == 0xF0 { }
        else if op == 0xF2 { rep_prefix = 2; }
        else if op == 0xF3 { rep_prefix = 3; }
        else if op == 0x64 { rep_prefix = 4; }
        else if op == 0x65 { rep_prefix = 5; }
        else { seg_override = (op >> 3) & 3; }
        op = fetch8();
    }
    dbg_op = op;
    d_valid = false; dbg_taken = false; dbg_back = false; dbg_odd = false; dbg_shift_cnt = 0;
    // 8086 decoder aliases: 60-6F execute as Jcc (70-7F); C0/C1/C8/C9 as C2/C3/CA/CB.
    if !cpu_v20 {
        if op >= 0x60 && op <= 0x6F { op = op + 0x10; }
        if op == 0xC0 || op == 0xC1 || op == 0xC8 || op == 0xC9 { op = op + 2; }
    }
    if cpu_mz && (op == 0x0F || op == 0x63 || op == 0x64 || op == 0x65 || op == 0x66 || op == 0x67) { return true; }  // undefined on the V30MZ: 1-byte NOPs, no exception, no ModRM eaten (WSCpuTest)
    if cpu_v20 && op >= 0x60 && op <= 0x6B {  // 80186 additions on the V20 (6C-6F are string ops, handled below)
        if op == 0x60 { let sp0: i64 = r[4] as i64; push16(r[0] as i64); push16(r[1] as i64); push16(r[2] as i64); push16(r[3] as i64); push16(sp0); push16(r[5] as i64); push16(r[6] as i64); push16(r[7] as i64); return true; }  // PUSHA
        if op == 0x61 { r[7] = pop16() as! u16; r[6] = pop16() as! u16; r[5] = pop16() as! u16; r[4] = r[4] + 2; r[3] = pop16() as! u16; r[2] = pop16() as! u16; r[1] = pop16() as! u16; r[0] = pop16() as! u16; return true; }  // POPA
        if op == 0x62 { decode_modrm(); if !d_isreg { let lo: i64 = s16(seg_rd16(d_segbase, d_off) as i64); let hi: i64 = s16(seg_rd16(d_segbase, (d_off + 2) & 0xFFFF) as i64); let v: i64 = s16(r[d_reg] as i64); if v < lo || v > hi { do_int(5); } } return true; }  // BOUND
        if op == 0x63 || op == 0x66 || op == 0x67 { decode_modrm(); return true; }  // undefined on the V20: decode and discard
        if op == 0x68 { let v = fetch16(); push16(v as i64); return true; }  // PUSH imm16
        if op == 0x6A { push16(s8(fetch8() as i64)); return true; }  // PUSH imm8 (sign-extended)
        if op == 0x69 || op == 0x6B { decode_modrm(); let imm: i64 = if op == 0x69 { s16(fetch16() as i64) } else { s8(fetch8() as i64) }; let prod: i64 = s16(read_rm(true)) * imm; r[d_reg] = (prod & 0xFFFF) as! u16; let cfo: i64 = if prod != s16(prod & 0xFFFF) { 1 } else { 0 }; if cpu_mz { mz_mul_flags(cfo); } else { set_cf_of(cfo, cfo); } return true; }  // IMUL reg, r/m, imm
        return false;
    }
    if cpu_v20 && op == 0x0F {  // NEC extended instructions
        let op2 = fetch8();
        if op2 >= 0x10 && op2 <= 0x1F {  // TEST1/CLR1/SET1/NOT1: bit (idx mod size) of the operand
            let which: i64 = (op2 >> 1) & 3;  // 0 TEST1, 1 CLR1, 2 SET1, 3 NOT1
            let size16: bool = (op2 & 1) == 1;
            decode_modrm();
            let idx: i64 = if op2 >= 0x18 { fetch8() as i64 } else { get_r8(1) as i64 };
            let bit: i64 = idx & (if size16 { 15 } else { 7 });
            let v = read_rm(size16);
            let m: i64 = 1 << bit;
            if which == 0 {
                let res: i64 = v & m;
                var f: i64 = (flags as i64) & 0xF72A;
                if parity_even(res & 0xFF) { f |= 0x0004; }
                if res == 0 { f |= 0x0040; }
                if (res & (if size16 { 0x8000 } else { 0x80 })) != 0 { f |= 0x0080; }
                flags = f as! u16;
            } else if which == 1 { write_rm(size16, v & ~m); }
            else if which == 2 { write_rm(size16, v | m); }
            else { write_rm(size16, v ^ m); }
            return true;
        }
        if op2 == 0x20 || op2 == 0x22 || op2 == 0x26 { op_bcd4(op2); return true; }  // ADD4S/SUB4S/CMP4S
        if op2 == 0x28 || op2 == 0x2A { op_rol4(op2); return true; }  // ROL4/ROR4
        if op2 == 0x31 || op2 == 0x33 || op2 == 0x39 || op2 == 0x3B { op_bins_ext(op2); return true; }  // BINS/BEXT
        return false;
    }
    if cpu_v20 && (op == 0xC0 || op == 0xC1) { decode_modrm(); let cnt: i64 = fetch8(); let size16: bool = (op & 1) == 1;
        if cpu_mz && d_reg == 6 {
            // V30MZ "SAL" (WSCpuTest): the operand always ends up zero,
            // with flags as for an exhausted shift (SZP of zero, CF/OF/AF
            // clear). Only imm 2 and 3 are exercised by the ROM, both with
            // operands whose exiting bits are 0, so the exact effective
            // count (imm+size is the natural reading) cannot be pinned
            // down further from this data.
            read_rm(size16);
            write_rm(size16, 0);
            flags = (((flags as i64) & 0xF72A) | 0x0044) as! u16;
            return true;
        }
        let kind2: i64 = if d_reg == 6 { 4 } else { d_reg }; let v = read_rm(size16); let res = shift_op(kind2, v, cnt, if size16 { 16 } else { 8 }); write_rm(size16, res); return true; }  // shift by imm8
    if cpu_v20 && op == 0xC8 { let disp = fetch16(); let level: i64 = (fetch8() as i64) & 0x1F; push16(r[5] as i64); let frame: i64 = r[4] as i64; if level > 0 { var bp2: i64 = r[5] as i64; for i in 1..level { bp2 -= 2; push16(seg_rd16((seg[2] as i64) << 4, bp2 & 0xFFFF) as i64); } push16(frame); } r[5] = frame as! u16; r[4] = ((frame - 2 * level - (disp as i64)) & 0xFFFF) as! u16; return true; }  // ENTER (V20: SP drops by the display size on top of disp)
    if cpu_v20 && op == 0xC9 { r[4] = r[5]; r[5] = pop16() as! u16; return true; }  // LEAVE
    if op == 0x88 { decode_modrm(); write_rm(false, get_r8(d_reg) as i64); return true; }
    if op == 0x89 { decode_modrm(); write_rm(true, r[d_reg] as i64); return true; }
    if op == 0x8A { decode_modrm(); set_r8(d_reg, read_rm(false) as! u8); return true; }
    if op == 0x8B { decode_modrm(); r[d_reg] = read_rm(true) as! u16; return true; }
    if op == 0xC6 { decode_modrm(); let v = fetch8(); write_rm(false, v as i64); return true; }
    if op == 0xC7 { decode_modrm(); let v = fetch16(); write_rm(true, v as i64); return true; }
    if op >= 0xB0 && op <= 0xB7 { let v = fetch8(); set_r8(op - 0xB0, v); return true; }
    if op >= 0xB8 && op <= 0xBF { r[op - 0xB8] = fetch16(); return true; }
    if op <= 0x3D && (op & 7) <= 5 {  // ALU family: opcodes 00-3D, forms 0-5
        let kind: i64 = (op >> 3) & 7;
        let form: i64 = op & 7;
        if form == 0 { decode_modrm(); let dst = read_rm(false); let srcv: i64 = get_r8(d_reg); let res = alu_op(kind, dst, srcv, 8); if kind != 7 { write_rm(false, res); } return true; }
        if form == 1 { decode_modrm(); let dst = read_rm(true); let srcv: i64 = r[d_reg]; let res = alu_op(kind, dst, srcv, 16); if kind != 7 { write_rm(true, res); } return true; }
        if form == 2 { decode_modrm(); let srcv = read_rm(false); let dst: i64 = get_r8(d_reg); let res = alu_op(kind, dst, srcv, 8); if kind != 7 { set_r8(d_reg, res as! u8); } return true; }
        if form == 3 { decode_modrm(); let srcv = read_rm(true); let dst: i64 = r[d_reg]; let res = alu_op(kind, dst, srcv, 16); if kind != 7 { r[d_reg] = res as! u16; } return true; }
        if form == 4 { let srcv: i64 = fetch8(); let dst: i64 = get_r8(0); let res = alu_op(kind, dst, srcv, 8); if kind != 7 { set_r8(0, res as! u8); } return true; }
        let srcv: i64 = fetch16(); let dst: i64 = r[0]; let res = alu_op(kind, dst, srcv, 16); if kind != 7 { r[0] = res as! u16; } return true;
    }
    if op == 0x84 { decode_modrm(); let dst = read_rm(false); let srcv: i64 = get_r8(d_reg); alu_op(4, dst, srcv, 8); return true; }  // TEST Eb,Gb
    if op == 0x85 { decode_modrm(); let dst = read_rm(true); let srcv: i64 = r[d_reg]; alu_op(4, dst, srcv, 16); return true; }  // TEST Ev,Gv
    if op == 0xA8 { let srcv: i64 = fetch8(); let dst: i64 = get_r8(0); alu_op(4, dst, srcv, 8); return true; }  // TEST AL,imm8
    if op == 0xA9 { let srcv: i64 = fetch16(); let dst: i64 = r[0]; alu_op(4, dst, srcv, 16); return true; }  // TEST AX,imm16
    if op == 0x80 || op == 0x82 { decode_modrm(); let dst = read_rm(false); let srcv: i64 = fetch8(); let res = alu_op(d_reg, dst, srcv, 8); if d_reg != 7 { write_rm(false, res); } return true; }
    if op == 0x81 { decode_modrm(); let dst = read_rm(true); let srcv: i64 = fetch16(); let res = alu_op(d_reg, dst, srcv, 16); if d_reg != 7 { write_rm(true, res); } return true; }
    if op == 0x83 { decode_modrm(); let dst = read_rm(true); let b8 = fetch8(); let b8i: i64 = b8; let srcv: i64 = (if b8i > 127 { b8i - 256 } else { b8i }) & 0xFFFF; let res = alu_op(d_reg, dst, srcv, 16); if d_reg != 7 { write_rm(true, res); } return true; }
    if op >= 0x40 && op <= 0x47 { let i = op - 0x40; r[i] = do_incdec(r[i] as i64, false, 16) as! u16; return true; }  // INC r16
    if op >= 0x48 && op <= 0x4F { let i = op - 0x48; r[i] = do_incdec(r[i] as i64, true, 16) as! u16; return true; }  // DEC r16
    if op == 0xFE { decode_modrm(); if d_reg == 0 { let v = read_rm(false); write_rm(false, do_incdec(v, false, 8)); return true; } if d_reg == 1 { let v = read_rm(false); write_rm(false, do_incdec(v, true, 8)); return true; } if d_reg == 6 { r[4] = r[4] - 2; let v = read_rm(true); seg_wr16((seg[2] as i64) << 4, r[4] as i64, v as! u16); return true; } if cpu_mz && d_reg >= 2 && d_reg <= 5 { return ff_xfer(); } if cpu_mz && d_reg == 7 { return true; } return false; }  // FE /2-/5 mirror the FF group on the MZ (word operand; Swanium, Wizardry/SD Gundam); FE /6 = PUSH (word operand, SP first) as in the FF group; /7 is a NOP on the MZ
    if op == 0xFF { decode_modrm();
        if d_reg == 0 { let v = read_rm(true); write_rm(true, do_incdec(v, false, 16)); return true; }
        if d_reg == 1 { let v = read_rm(true); write_rm(true, do_incdec(v, true, 16)); return true; }
        if d_reg >= 2 && d_reg <= 5 { return ff_xfer(); }
        if d_reg == 7 && cpu_mz { return true; }  // V30MZ: FF /7 is a NOP, not a PUSH (WSCpuTest)
        if d_reg == 6 || d_reg == 7 { r[4] = r[4] - 2; let v = read_rm(true); seg_wr16((seg[2] as i64) << 4, r[4] as i64, v as! u16); return true; }  // PUSH Ev (/7 aliases /6 except on the MZ; SP decremented before the operand is read)
        return false; }
    
    if op == 0x86 { decode_modrm(); let t = read_rm(false); write_rm(false, get_r8(d_reg) as i64); set_r8(d_reg, t as! u8); return true; }  // XCHG Eb,Gb
    if op == 0x87 { decode_modrm(); let t = read_rm(true); write_rm(true, r[d_reg] as i64); r[d_reg] = t as! u16; return true; }  // XCHG Ev,Gv
    if op == 0x90 { return true; }  // NOP (XCHG AX,AX)
    if op >= 0x91 && op <= 0x97 { let i = op - 0x90; let t = r[0]; r[0] = r[i]; r[i] = t; return true; }  // XCHG AX,r16
    if op >= 0x50 && op <= 0x57 { r[4] = r[4] - 2; seg_wr16((seg[2] as i64) << 4, r[4] as i64, r[op - 0x50]); return true; }  // PUSH r16 (reg read after decrement: 8086 PUSH SP pushes the new SP)
    if op >= 0x58 && op <= 0x5F { let v = pop16(); r[op - 0x58] = v as! u16; return true; }  // POP r16
    if op == 0x06 || op == 0x0E || op == 0x16 || op == 0x1E { push16(seg[(op >> 3) & 3] as i64); return true; }  // PUSH seg
    if op == 0x07 || op == 0x0F || op == 0x17 || op == 0x1F { let v = pop16(); seg[(op >> 3) & 3] = v as! u16; if op == 0x17 { irq_inhibit = 1; } return true; }  // POP seg (0F = POP CS, 8086 only)
    if op == 0x8F { decode_modrm(); let v = pop16(); write_rm(true, v); return true; }  // POP Ev
    if (op >= 0xA4 && op <= 0xAF && op != 0xA8 && op != 0xA9) || (cpu_v20 && op >= 0x6C && op <= 0x6F) {  // string operations
        let is_cmp: bool = op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF;
        if rep_prefix == 0 { str_step(op); }
        else {
            while r[1] != 0 {
                str_step(op);
                r[1] = r[1] - 1;
                if is_cmp {
                    let zf: i64 = (flags >> 6) & 1;
                    if rep_prefix == 3 && zf == 0 { break; }
                    if rep_prefix == 2 && zf == 1 { break; }
                    if rep_prefix == 4 && (flags & 1) == 1 { break; }
                    if rep_prefix == 5 && (flags & 1) == 0 { break; }
                }
            }
        }
        return true;
    }
    if op == 0x8D { decode_modrm(); r[d_reg] = d_off as! u16; return true; }  // LEA (mod=3: d_off holds the MZ adder value)
    if op == 0xC4 { decode_modrm(); if d_isreg && !cpu_mz { return false; } let lo = seg_rd16(d_segbase, d_off); let hi = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); r[d_reg] = lo; seg[0] = hi; return true; }  // LES (mod=3 on the MZ reads at the adder EA)
    if op == 0xC5 { decode_modrm(); if d_isreg && !cpu_mz { return false; } let lo = seg_rd16(d_segbase, d_off); let hi = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); r[d_reg] = lo; seg[3] = hi; return true; }  // LDS (mod=3 on the MZ reads at the adder EA)
    if op == 0xCF { ip = pop16() as! u16; seg[1] = pop16() as! u16; let f0: i64 = flags as i64; load_flags(pop16()); flag_inhibits(f0); return true; }  // IRET
    if op == 0x98 { if (r[0] & 0x80) != 0 { r[0] = (r[0] & 0xFF) | 0xFF00; } else { r[0] = r[0] & 0xFF; } return true; }  // CBW
    if op == 0x99 { r[2] = if (r[0] & 0x8000) != 0 { 0xFFFF } else { 0 }; return true; }  // CWD
    if op == 0x9C { push16(flags as i64); return true; }  // PUSHF
    if op == 0x9D { let f0: i64 = flags as i64; load_flags(pop16()); flag_inhibits(f0); return true; }  // POPF
    if op == 0x9E { flags = (((flags as i64) & 0xFF00) | ((flags as i64) & 0x2A) | ((get_r8(4) as i64) & 0xD5)) as! u16; return true; }  // SAHF
    if op == 0x9F { set_r8(4, (flags & 0xFF) as! u8); return true; }  // LAHF
    if op == 0xA0 { let off = fetch16(); set_r8(0, rd8((src_seg_base(3) + (off as i64)) & 0xFFFFF)); return true; }  // MOV AL,moffs8
    if op == 0xA1 { let off = fetch16(); r[0] = seg_rd16(src_seg_base(3), off as i64); return true; }  // MOV AX,moffs16
    if op == 0xA2 { let off = fetch16(); wb8((src_seg_base(3) + (off as i64)) & 0xFFFFF, get_r8(0)); return true; }  // MOV moffs8,AL
    if op == 0xA3 { let off = fetch16(); seg_wr16(src_seg_base(3), off as i64, r[0]); return true; }  // MOV moffs16,AX
    if op >= 0xD0 && op <= 0xD3 { decode_modrm(); if d_reg == 6 && !cpu_v20 { if (op & 2) == 2 && get_r8(1) == 0 { return true; } let sm: bool = (op & 1) == 1; write_rm(sm, if sm { 0xFFFF } else { 0xFF }); flags = (((flags as i64) & 0xF72A) | 0x0084) as! u16; return true; } let size16: bool = (op & 1) == 1; let cnt: i64 = if (op & 2) == 0 { 1 } else { get_r8(1) as i64 }; let v = read_rm(size16); let res = shift_op(if d_reg == 6 { 4 } else { d_reg }, v, cnt, if size16 { 16 } else { 8 }); write_rm(size16, res); return true; }  // shifts/rotates; /6 = SETMO (8086) or SAL (V20)
    if op == 0xD4 { let base: i64 = fetch8(); if base == 0 { if cpu_mz { mz_div_flags(unit_cfof, if (get_r8(0) & 0xC0) == 0 { 1 } else { 0 }); } do_int(0); } else { let al: i64 = get_r8(0); let q: i64 = al / base; set_r8(4, q as! u8); set_r8(0, (al - q * base) as! u8); set_szp(al - q * base, 8); flags = flags & 0xF7EE; } return true; }  // AAM
    if op == 0xD5 { let base: i64 = fetch8(); let ub: i64 = if cpu_v20 && !cpu_mz { 10 } else { base }; let lo: i64 = ((get_r8(4) as i64) * ub) & 0xFF; let v = alu_op(0, lo, get_r8(0) as i64, 8); set_r8(0, v as! u8); set_r8(4, 0); return true; }  // AAD
    if op == 0xD6 { if cpu_v20 && !cpu_mz { let off: i64 = ((r[3] as i64) + (get_r8(0) as i64)) & 0xFFFF; set_r8(0, rd8((src_seg_base(3) + off) & 0xFFFFF)); } else { set_r8(0, if (flags & 1) != 0 { 0xFF } else { 0 }); } return true; }  // SALC (8086 and V30MZ) / XLAT (V20)
    if op == 0xD7 { let off: i64 = ((r[3] as i64) + (get_r8(0) as i64)) & 0xFFFF; set_r8(0, rd8((src_seg_base(3) + off) & 0xFFFFF)); return true; }  // XLAT
    if op >= 0xD8 && op <= 0xDF { decode_modrm(); return true; }  // ESC: no coprocessor, no architectural effect
    if op == 0xE4 { let pt: i64 = fetch8() as i64; set_r8(0, if ws_mode { port_rd(pt) as! u8 } else { 0xFF }); return true; }  // IN AL,imm8 (SST rig: open bus reads as FF)
    if op == 0xE5 { let pt: i64 = fetch8() as i64; if ws_mode { let lo = port_rd(pt); let hi = port_rd(pt + 1); r[0] = ((hi << 8) | lo) as! u16; } else { r[0] = 0xFFFF; } return true; }  // IN AX,imm8
    if op == 0xE6 { let pt: i64 = fetch8() as i64; if ws_mode { port_wr(pt, get_r8(0) as i64); } return true; }  // OUT imm8,AL
    if op == 0xE7 { let pt: i64 = fetch8() as i64; if ws_mode { port_wr(pt, r[0] & 0xFF); port_wr(pt + 1, (r[0] >> 8) & 0xFF); } return true; }  // OUT imm8,AX
    if op == 0xEC { set_r8(0, if ws_mode { port_rd(r[2] & 0xFF) as! u8 } else { 0xFF }); return true; }  // IN AL,DX
    if op == 0xED { if ws_mode { let pt: i64 = r[2] & 0xFF; let lo = port_rd(pt); let hi = port_rd(pt + 1); r[0] = ((hi << 8) | lo) as! u16; } else { r[0] = 0xFFFF; } return true; }  // IN AX,DX
    if op == 0xEE { if ws_mode { port_wr(r[2] & 0xFF, get_r8(0) as i64); } return true; }  // OUT DX,AL
    if op == 0xEF { if ws_mode { let pt: i64 = r[2] & 0xFF; port_wr(pt, r[0] & 0xFF); port_wr(pt + 1, (r[0] >> 8) & 0xFF); } return true; }  // OUT DX,AX
    if op == 0x9B { return true; }  // WAIT: no coprocessor attached, a NOP
    if op == 0xF4 && ws_mode { cpu_halted = true; return true; }  // HLT: the runner wakes the CPU on interrupts
    if op == 0xF5 { flags = flags ^ 1; return true; }  // CMC
    if op == 0xF8 { flags = flags & 0xFFFE; return true; }  // CLC
    if op == 0xF9 { flags = flags | 1; return true; }  // STC
    if op == 0xFA { flags = flags & 0xFDFF; return true; }  // CLI
    if op == 0xFB { if (flags & 0x0200) == 0 { irq_inhibit = 1; } flags = flags | 0x0200; return true; }  // STI
    if op == 0xFC { flags = flags & 0xFBFF; return true; }  // CLD
    if op == 0xFD { flags = flags | 0x0400; return true; }  // STD
    if op == 0x27 { let oa: i64 = get_r8(0); var adj: i64 = 0; var af: i64 = 0; if ((oa & 0xF) > 9) || ((flags >> 4) & 1) == 1 { adj += 6; af = 1; } var cf: i64 = 0; if (cpu_mz && (oa > 0x99 || (flags & 1) == 1)) || (!cpu_mz && (oa >= 0xA0 || (flags & 1) == 1 || (oa > 0x99 && ((flags >> 4) & 1) == 0))) { adj += 0x60; cf = 1; } let res: i64 = (oa + adj) & 0xFF; set_r8(0, res as! u8); var nf: i64 = (flags as i64) & 0xF72A; if cf == 1 { nf |= 1; } if af == 1 { nf |= 0x10; } if ((oa ^ res) & (adj ^ res) & 0x80) != 0 { nf |= 0x0800; } flags = nf as! u16; set_szp(res, 8); return true; }  // DAA
    if op == 0x2F { let oa: i64 = get_r8(0); var adj: i64 = 0; var af: i64 = 0; if ((oa & 0xF) > 9) || ((flags >> 4) & 1) == 1 { adj += 6; af = 1; } var cf: i64 = 0; if (cpu_mz && (oa > 0x99 || (flags & 1) == 1)) || (!cpu_mz && (oa >= 0xA0 || (flags & 1) == 1 || (oa > 0x99 && ((flags >> 4) & 1) == 0))) { adj += 0x60; cf = 1; } let res: i64 = (oa - adj) & 0xFF; set_r8(0, res as! u8); var nf: i64 = (flags as i64) & 0xF72A; if cf == 1 { nf |= 1; } if af == 1 { nf |= 0x10; } if ((oa ^ adj) & (oa ^ res) & 0x80) != 0 { nf |= 0x0800; } flags = nf as! u16; set_szp(res, 8); return true; }  // DAS
    if op == 0x37 { if cpu_mz { let ax0: i64 = r[0]; let adjz: bool = ((ax0 & 0xF) > 9) || ((flags >> 4) & 1) == 1; let nib: i64 = ax0 & 0xF; if adjz { r[0] = ((((ax0 >> 8) + 1) & 0xFF) << 8 | ((nib + 6) & 0xF)) as! u16; } else { r[0] = ((ax0 & 0xFF00) | nib) as! u16; } flags = (((flags as i64) & 0xF700) | (if adjz { 0x57 } else { 0x86 })) as! u16; return true; } let ax0: i64 = r[0]; let adj: bool = ((ax0 & 0xF) > 9) || ((flags >> 4) & 1) == 1; let al0: i64 = ax0 & 0xFF; let ah0: i64 = (ax0 >> 8) & 0xFF; var szp: i64 = al0; if adj { szp = (al0 + 6) & 0xFF; r[0] = ((((ah0 + 1) & 0xFF) << 8) | (szp & 0xF)) as! u16; } else { r[0] = ((ax0 & 0xFF00) | (ax0 & 0xF)) as! u16; } var nf: i64 = (flags as i64) & 0xF72A; if adj { nf |= 0x11; if ((al0 ^ szp) & (6 ^ szp) & 0x80) != 0 { nf |= 0x0800; } } flags = nf as! u16; set_szp(szp, 8); return true; }  // AAA
    if op == 0x3F { if cpu_mz { let ax0: i64 = r[0]; let adjz: bool = ((ax0 & 0xF) > 9) || ((flags >> 4) & 1) == 1; let nib: i64 = ax0 & 0xF; if adjz { r[0] = ((((ax0 >> 8) - 1) & 0xFF) << 8 | ((nib - 6) & 0xF)) as! u16; } else { r[0] = ((ax0 & 0xFF00) | nib) as! u16; } flags = (((flags as i64) & 0xF700) | (if adjz { 0x57 } else { 0x86 })) as! u16; return true; } let ax0: i64 = r[0]; let adj: bool = ((ax0 & 0xF) > 9) || ((flags >> 4) & 1) == 1; let al0: i64 = ax0 & 0xFF; let ah0: i64 = (ax0 >> 8) & 0xFF; var szp: i64 = al0; if adj { szp = (al0 - 6) & 0xFF; r[0] = ((((ah0 - 1) & 0xFF) << 8) | (szp & 0xF)) as! u16; } else { r[0] = ((ax0 & 0xFF00) | (ax0 & 0xF)) as! u16; } var nf: i64 = (flags as i64) & 0xF72A; if adj { nf |= 0x11; if ((al0 ^ 6) & (al0 ^ szp) & 0x80) != 0 { nf |= 0x0800; } } flags = nf as! u16; set_szp(szp, 8); return true; }  // AAS
    if op == 0xF6 { decode_modrm();
        if cpu_mz && d_reg == 1 { return true; }  // V30MZ: F6 /1 is undefined, a 2-byte NOP; the imm8 is NOT eaten (WSCpuTest)
        if d_reg == 0 || d_reg == 1 { let imm: i64 = fetch8(); let dst = read_rm(false); alu_op(4, dst, imm, 8); return true; }
        if d_reg == 2 { let v = read_rm(false); write_rm(false, (~v) & 0xFF); return true; }
        if d_reg == 3 { let v = read_rm(false); let res = alu_op(5, 0, v, 8); write_rm(false, res); return true; }
        if d_reg == 4 { let b = read_rm(false); let prod: i64 = (get_r8(0) as i64) * b; r[0] = prod as! u16; mul_flags(prod >> 8, 8); return true; }
        if d_reg == 5 { let b = read_rm(false); let prod: i64 = s8(get_r8(0) as i64) * s8(b); r[0] = (prod & 0xFFFF) as! u16; let cfo: i64 = if prod != s8(prod & 0xFF) { 1 } else { 0 }; if cpu_mz { mz_mul_flags(cfo); } else { set_cf_of(cfo, cfo); } return true; }
        if d_reg == 6 { let b = read_rm(false); let dvd: i64 = r[0]; if cpu_mz { var fault: bool = b == 0; if !fault { fault = dvd / b > 0xFF; } if fault { mz_div_flags(unit_cfof, divu8_err_zf(dvd, b)); do_int(0); } else { let q: i64 = dvd / b; let rem: i64 = dvd - q * b; set_r8(0, q as! u8); set_r8(4, rem as! u8); mz_div_flags(unit_cfof, if rem == 0 && (q & 1) == 1 { 1 } else { 0 }); } return true; } if b == 0 { do_int(0); } else if dvd / b > 0xFF { do_int(0); } else { set_r8(0, (dvd / b) as! u8); set_r8(4, (dvd - (dvd / b) * b) as! u8); } return true; }
        if d_reg == 7 { let b = read_rm(false); let dvd: i64 = s16(r[0] as i64); if cpu_mz { if b == 0 && (r[0] as i64) == 0x8000 { r[0] = 0x0081; flags = (((flags as i64) & 0xF700) | 0x02) as! u16; set_szp(0x81, 8); return true; } var fault: bool = b == 0; var q: i64 = 0; var rem: i64 = 0; if !fault { let qq, rr = trunc_divmod(dvd, s8(b)); q = qq; rem = rr; fault = q > 127 || q < (0 - 127); } if fault { mz_div_flags(unit_cfof, 0); do_int(0); } else { set_r8(0, (q & 0xFF) as! u8); set_r8(4, (rem & 0xFF) as! u8); flags = (((flags as i64) & 0xF700) | 0x02) as! u16; set_szp(q & 0xFF, 8); } return true; } if b == 0 { do_int(0); } else { let q, rem = trunc_divmod(dvd, s8(b)); if q > 127 || q < (0 - 128) { do_int(0); } else { set_r8(0, (q & 0xFF) as! u8); set_r8(4, (rem & 0xFF) as! u8); } } return true; }
        return false; }
    if op == 0xF7 { decode_modrm();
        if cpu_mz && d_reg == 1 { return true; }  // V30MZ: F7 /1 is undefined, a 2-byte NOP; the imm16 is NOT eaten (WSCpuTest)
        if d_reg == 0 || d_reg == 1 { let imm: i64 = fetch16(); let dst = read_rm(true); alu_op(4, dst, imm, 16); return true; }
        if d_reg == 2 { let v = read_rm(true); write_rm(true, (~v) & 0xFFFF); return true; }
        if d_reg == 3 { let v = read_rm(true); let res = alu_op(5, 0, v, 16); write_rm(true, res); return true; }
        if d_reg == 4 { let b = read_rm(true); let prod: i64 = (r[0] as i64) * b; r[0] = (prod & 0xFFFF) as! u16; r[2] = ((prod >> 16) & 0xFFFF) as! u16; mul_flags((prod >> 16) & 0xFFFF, 16); return true; }
        if d_reg == 5 { let b = read_rm(true); let prod: i64 = s16(r[0] as i64) * s16(b); r[0] = (prod & 0xFFFF) as! u16; r[2] = ((prod >> 16) & 0xFFFF) as! u16; let cfo: i64 = if prod != s16(prod & 0xFFFF) { 1 } else { 0 }; if cpu_mz { mz_mul_flags(cfo); } else { set_cf_of(cfo, cfo); } return true; }
        if d_reg == 6 { let b = read_rm(true); let dvd: i64 = ((r[2] as i64) << 16) | (r[0] as i64); if cpu_mz { var fault: bool = b == 0; if !fault { fault = dvd / b > 0xFFFF; } if fault { mz_div_flags(0, divu16_err_zf(r[2] as i64, r[0] as i64, b)); do_int(0); } else { let q: i64 = dvd / b; let rem: i64 = dvd - q * b; r[0] = q as! u16; r[2] = rem as! u16; mz_div_flags(0, if rem == 0 && (q & 1) == 1 { 1 } else { 0 }); } return true; } if b == 0 { do_int(0); } else if dvd / b > 0xFFFF { do_int(0); } else { r[0] = (dvd / b) as! u16; r[2] = (dvd - (dvd / b) * b) as! u16; } return true; }
        if d_reg == 7 { let b = read_rm(true); let dvd: i64 = s32(((r[2] as i64) << 16) | (r[0] as i64)); if cpu_mz { if b == 0 && (r[2] as i64) == 0x8000 && (r[0] as i64) == 0 { r[0] = 0x8001; r[2] = 0; mz_div_flags(0, 1); return true; } var fault: bool = b == 0; var q: i64 = 0; var rem: i64 = 0; if !fault { let qq, rr = trunc_divmod(dvd, s16(b)); q = qq; rem = rr; fault = q > 32767 || q < (0 - 32767); } if fault { mz_div_flags(0, 0); do_int(0); } else { r[0] = (q & 0xFFFF) as! u16; r[2] = (rem & 0xFFFF) as! u16; mz_div_flags(0, if rem == 0 && (q & 1) == 1 { 1 } else { 0 }); } return true; } if b == 0 { do_int(0); } else { let q, rem = trunc_divmod(dvd, s16(b)); if q > 32767 || q < (0 - 32768) { do_int(0); } else { r[0] = (q & 0xFFFF) as! u16; r[2] = (rem & 0xFFFF) as! u16; } } return true; }
        return false; }
    if op == 0x8C { decode_modrm(); write_rm(true, seg[d_reg & 3] as i64); return true; }  // MOV Ev,seg
    if op == 0x8E { decode_modrm(); let v = read_rm(true); seg[d_reg & 3] = v as! u16; if (d_reg & 3) == 2 { irq_inhibit = 1; } return true; }  // MOV seg,Ev
    if op >= 0x70 && op <= 0x7F { let d = disp8s(); if cond(op & 0xF) { dbg_taken = true; dbg_back = d < 0; rel_jump(d); } return true; }  // Jcc rel8
    if op == 0xEB { rel_jump(disp8s()); return true; }  // JMP rel8
    if op == 0xE9 { rel_jump(disp16s()); return true; }  // JMP rel16
    if op == 0xE8 { let d = disp16s(); push16(ip as i64); rel_jump(d); return true; }  // CALL rel16
    if op == 0x9A { let nip = fetch16(); let ncs = fetch16(); push16(seg[1] as i64); push16(ip as i64); ip = nip; seg[1] = ncs; return true; }  // CALL far ptr
    if op == 0xEA { let nip = fetch16(); let ncs = fetch16(); ip = nip; seg[1] = ncs; return true; }  // JMP far ptr
    if op == 0xC3 { ip = pop16() as! u16; return true; }  // RET
    if op == 0xC2 { let n = fetch16(); ip = pop16() as! u16; r[4] = r[4] + n; return true; }  // RET imm16
    if op == 0xCB { ip = pop16() as! u16; seg[1] = pop16() as! u16; return true; }  // RETF
    if op == 0xCA { let n = fetch16(); ip = pop16() as! u16; seg[1] = pop16() as! u16; r[4] = r[4] + n; return true; }  // RETF imm16
    if op >= 0xE0 && op <= 0xE3 {  // LOOPNE/LOOPE/LOOP/JCXZ
        let d = disp8s();
        var take: bool = false;
        if op == 0xE3 { take = r[1] == 0; }
        else {
            r[1] = r[1] - 1;
            if op == 0xE2 { take = r[1] != 0; }
            else if op == 0xE1 { take = r[1] != 0 && ((flags as i64 >> 6) & 1) == 1; }
            else { take = r[1] != 0 && ((flags as i64 >> 6) & 1) == 0; }
        }
        dbg_taken = take; dbg_back = d < 0;
        if take { rel_jump(d); }
        return true;
    }
    if op == 0xCC { do_int(3); return true; }  // INT3
    if op == 0xF1 && cpu_mz { do_int(1); return true; }  // V30MZ: one-byte INT 1 (Swanium; SD Gundam, Wizardry, Riviera)
    if op == 0xCD { let n = fetch8(); do_int(n as i64); return true; }  // INT imm8
    if op == 0xCE { if ((flags as i64 >> 11) & 1) == 1 { do_int(4); } return true; }  // INTO

    return false;
}
