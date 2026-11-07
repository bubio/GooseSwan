// GooseSwan M0: SingleStepTests harness + minimal V30MZ (8086) core slice.
// Usage: sst <case-file.json> [more files...]
// Each case: load initial regs/RAM, execute exactly one instruction,
// compare the listed final regs/RAM. Reports pass/fail/unsupported counts.
import std;
import os;
import json;

// ---- CPU state ----
var mem: u8[1048576] = [0; 1048576];
var r: u16[8] = [0; 8];      // encoding order: ax cx dx bx sp bp si di
var seg: u16[4] = [0; 4];    // es cs ss ds
var ip: u16 = 0;
var flags: u16 = 0;

// Memory written during a case, so the next case can restore zeros.
var touched: i64[>..<] = [];
var recording: bool = false;

fn phys(s: u16, off: u16) -> i64 { (((s as i64) << 4) + (off as i64)) & 0xFFFFF }
fn rb16(p: i64) -> u16 { (mem[p] as u16) | ((mem[(p + 1) & 0xFFFFF] as u16) << 8) }
fn wb8(p: i64, v: u8) { mem[p] = v; if recording { touched.push(p); } }
fn wb16(p: i64, v: u16) { wb8(p, v as! u8); wb8((p + 1) & 0xFFFFF, (v >> 8) as! u8); }

fn fetch8() -> u8 { let v = mem[phys(seg[1], ip)]; ip = ip + 1; v }
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
var d_reg: i64 = 0;
var d_isreg: bool = false;
var d_regidx: i64 = 0;
var d_addr: i64 = 0;

fn decode_modrm() {
    let m = fetch8();
    let mod: i64 = m >> 6;
    d_reg = (m >> 3) & 7;
    let rm: i64 = m & 7;
    if mod == 3 { d_isreg = true; d_regidx = rm; return; }
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
        if mod == 0 { let ds: i64 = if seg_override >= 0 { seg_override } else { 3 }; d_addr = phys(seg[ds], fetch16()); return; }  // direct disp16
        base = r[5] as i64; sidx = 2;                                 // bp
    }
    else { base = r[3] as i64; }                                      // bx
    if seg_override >= 0 { sidx = seg_override; }
    var disp: i64 = 0;
    if mod == 1 { let d8 = fetch8(); let d8i: i64 = d8; disp = if d8i > 127 { d8i - 256 } else { d8i }; }
    else if mod == 2 { disp = fetch16() as i64; }
    let ea: i64 = (base + disp) & 0xFFFF;
    d_addr = phys(seg[sidx], ea as! u16);
}

fn read_rm(size16: bool) -> i64 {
    if d_isreg { if size16 { r[d_regidx] as i64 } else { get_r8(d_regidx) as i64 } }
    else if size16 { rb16(d_addr) as i64 } else { mem[d_addr] as i64 }
}
fn write_rm(size16: bool, v: i64) {
    if d_isreg {
        if size16 { r[d_regidx] = v as! u16; } else { set_r8(d_regidx, v as! u8); }
    } else {
        if size16 { wb16(d_addr, v as! u16); } else { wb8(d_addr, v as! u8); }
    }
}

// ---- Flags ----
fn parity_even(v: i64) -> bool {
    var p: i64 = 0; var x: i64 = v;
    for i in 8 { p += x & 1; x = x >> 1; }
    p % 2 == 0
}
fn add_flags(a: i64, b: i64, res: i64, bits: i64) {
    let mask: i64 = if bits == 16 { 0xFFFF } else { 0xFF };
    let sign: i64 = if bits == 16 { 0x8000 } else { 0x80 };
    let rr: i64 = res & mask;
    var f: i64 = (flags as i64) & 0xF72A;  // keep non-arithmetic bits
    if res > mask { f |= 0x0001; }                       // CF
    if parity_even(rr & 0xFF) { f |= 0x0004; }           // PF
    if ((a & 0xF) + (b & 0xF)) > 0xF { f |= 0x0010; }    // AF
    if rr == 0 { f |= 0x0040; }                          // ZF
    if (rr & sign) != 0 { f |= 0x0080; }                 // SF
    if ((a ^ rr) & (b ^ rr) & sign) != 0 { f |= 0x0800; }  // OF
    flags = f as! u16;
}

// ---- Instruction slice: MOV + ADD ----
fn exec_one() -> bool {
    seg_override = -1;
    var op = fetch8();
    while op == 0x26 || op == 0x2E || op == 0x36 || op == 0x3E {  // segment override prefixes
        seg_override = (op >> 3) & 3;
        op = fetch8();
    }
    if op == 0x88 { decode_modrm(); write_rm(false, get_r8(d_reg) as i64); return true; }
    if op == 0x89 { decode_modrm(); write_rm(true, r[d_reg] as i64); return true; }
    if op == 0x8A { decode_modrm(); set_r8(d_reg, read_rm(false) as! u8); return true; }
    if op == 0x8B { decode_modrm(); r[d_reg] = read_rm(true) as! u16; return true; }
    if op == 0xC6 { decode_modrm(); let v = fetch8(); write_rm(false, v as i64); return true; }
    if op == 0xC7 { decode_modrm(); let v = fetch16(); write_rm(true, v as i64); return true; }
    if op >= 0xB0 && op <= 0xB7 { let v = fetch8(); set_r8(op - 0xB0, v); return true; }
    if op >= 0xB8 && op <= 0xBF { r[op - 0xB8] = fetch16(); return true; }
    if op == 0x00 { decode_modrm(); let dst = read_rm(false); let src: i64 = get_r8(d_reg); let res = dst + src; write_rm(false, res); add_flags(dst, src, res, 8); return true; }
    if op == 0x01 { decode_modrm(); let dst = read_rm(true); let src: i64 = r[d_reg]; let res = dst + src; write_rm(true, res); add_flags(dst, src, res, 16); return true; }
    if op == 0x02 { decode_modrm(); let src = read_rm(false); let dst: i64 = get_r8(d_reg); let res = dst + src; set_r8(d_reg, res as! u8); add_flags(dst, src, res, 8); return true; }
    if op == 0x03 { decode_modrm(); let src = read_rm(true); let dst: i64 = r[d_reg]; let res = dst + src; r[d_reg] = res as! u16; add_flags(dst, src, res, 16); return true; }
    if op == 0x04 { let dst: i64 = get_r8(0); let src: i64 = fetch8(); let res = dst + src; set_r8(0, res as! u8); add_flags(dst, src, res, 8); return true; }
    if op == 0x05 { let dst: i64 = r[0]; let src: i64 = fetch16(); let res = dst + src; r[0] = res as! u16; add_flags(dst, src, res, 16); return true; }
    return false;
}

// ---- Case storage (regs indexed: 0-7 r, 8-11 seg es/cs/ss/ds, 12 ip, 13 flags) ----
var c_init_regs: i64[14] = [0; 14];
var c_init_present: bool[14] = [false; 14];
var c_fin_regs: i64[14] = [0; 14];
var c_fin_present: bool[14] = [false; 14];
var c_init_addr: i64[>..<] = [];
var c_init_val: i64[>..<] = [];
var c_fin_addr: i64[>..<] = [];
var c_fin_val: i64[>..<] = [];

fn reg_index(key: u8[:]) -> i64 {
    if key == "ax" { 0 } else if key == "cx" { 1 } else if key == "dx" { 2 } else if key == "bx" { 3 }
    else if key == "sp" { 4 } else if key == "bp" { 5 } else if key == "si" { 6 } else if key == "di" { 7 }
    else if key == "es" { 8 } else if key == "cs" { 9 } else if key == "ss" { 10 } else if key == "ds" { 11 }
    else if key == "ip" { 12 } else if key == "flags" { 13 } else { -1 }
}
fn get_reg_by_index(idx: i64) -> i64 {
    if idx < 8 { r[idx] as i64 } else if idx < 12 { seg[idx - 8] as i64 }
    else if idx == 12 { ip as i64 } else { flags as i64 }
}
fn set_reg_by_index(idx: i64, v: i64) {
    if idx < 8 { r[idx] = v as! u16; } else if idx < 12 { seg[idx - 8] = v as! u16; }
    else if idx == 12 { ip = v as! u16; } else { flags = v as! u16; }
}

fn read_state(rd: json::Reader&, initial: bool) {
    json::each_member(rd) { key =>
        if key == "regs" {
            json::each_member(rd) { rk =>
                let idx = reg_index(rk);
                let v = json::read_int(rd);
                if idx >= 0 {
                    if initial { c_init_regs[idx] = v; c_init_present[idx] = true; }
                    else { c_fin_regs[idx] = v; c_fin_present[idx] = true; }
                }
            };
        } else if key == "ram" {
            json::each_element(rd) {
                var pair: i64[2] = [0, 0];
                var k: i64 = 0;
                json::each_element(rd) { pair[k] = json::read_int(rd); k++; };
                if initial { c_init_addr.push(pair[0]); c_init_val.push(pair[1]); }
                else { c_fin_addr.push(pair[0]); c_fin_val.push(pair[1]); }
            };
        } else { json::skip(rd); }
    };
}

fn clear_case() {
    for i in 14 { c_init_present[i] = false; c_fin_present[i] = false; }
    while c_init_addr.len > 0 { c_init_addr.pop(); c_init_val.pop(); }
    while c_fin_addr.len > 0 { c_fin_addr.pop(); c_fin_val.pop(); }
}

// First-failure detail for reporting.
var f_kind: i64 = 0;  // 1 = register, 2 = ram
var f_idx: i64 = 0;
var f_addr: i64 = 0;
var f_exp: i64 = 0;
var f_got: i64 = 0;

fn run_case() -> i64 {  // 0 pass, 1 fail, 2 unsupported
    // restore memory dirtied by the previous case
    while touched.len > 0 { let a = touched.pop(); mem[a] = 0; }
    for i in 8 { r[i] = 0; }
    for i in 4 { seg[i] = 0; }
    ip = 0; flags = 0;
    for idx in 14 { if c_init_present[idx] { set_reg_by_index(idx, c_init_regs[idx]); } }
    recording = true;
    for i in c_init_addr.len { let a = c_init_addr[i]; mem[a] = c_init_val[i] as! u8; touched.push(a); }
    let ok = exec_one();
    recording = false;
    if !ok { return 2; }
    for idx in 14 {
        if c_fin_present[idx] {
            let got = get_reg_by_index(idx);
            if got != c_fin_regs[idx] { f_kind = 1; f_idx = idx; f_exp = c_fin_regs[idx]; f_got = got; return 1; }
        }
    }
    for i in c_fin_addr.len {
        let a = c_fin_addr[i];
        let got: i64 = mem[a];
        if got != c_fin_val[i] { f_kind = 2; f_addr = a; f_exp = c_fin_val[i]; f_got = got; return 1; }
    }
    return 0;
}

fn reg_name(idx: i64) -> u8[:] {
    if idx == 0 { "ax" } else if idx == 1 { "cx" } else if idx == 2 { "dx" } else if idx == 3 { "bx" }
    else if idx == 4 { "sp" } else if idx == 5 { "bp" } else if idx == 6 { "si" } else if idx == 7 { "di" }
    else if idx == 8 { "es" } else if idx == 9 { "cs" } else if idx == 10 { "ss" } else if idx == 11 { "ds" }
    else if idx == 12 { "ip" } else { "flags" }
}

fn run_file(path: u8[:]) {
    var text: u8[>..] = [];
    guard read_file(path, text) else { print("cannot read ", path); exit(1); }
    var rd = json::reader(text);
    var total: i64 = 0; var passed: i64 = 0; var failed: i64 = 0; var unsupported: i64 = 0;
    json::each_element(rd) {
        clear_case();
        json::each_member(rd) { key =>
            if key == "initial" { read_state(rd, true); }
            else if key == "final" { read_state(rd, false); }
            else { json::skip(rd); }
        };
        total++;
        let res = run_case();
        if res == 0 { passed++; }
        else if res == 2 { unsupported++; }
        else {
            failed++;
            if failed <= 5 {
                if f_kind == 1 { print("  FAIL case ", total - 1, ": reg ", reg_name(f_idx), " expected ", f_exp, " got ", f_got); }
                else { print("  FAIL case ", total - 1, ": ram[", f_addr, "] expected ", f_exp, " got ", f_got); }
            }
        }
    };
    if !json::finish(rd) { print(path, ": JSON parse problem: ", json::message(rd)); }
    print(path, ": total=", total, " passed=", passed, " failed=", failed, " unsupported=", unsupported);
}

fn main() {
    let argv = args();
    if argv.len < 2 { print("usage: sst <case-file.json> [more files...]"); exit(1); }
    for i in 1..argv.len { run_file(argv[i]); }
}
