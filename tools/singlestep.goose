// SingleStepTests harness (sst <case-file.json>...): loads each JSON
// case into the CPU's flat test bus, executes one instruction and
// compares the final registers and RAM.
namespace core;

import json;

// ---- Case state ----

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
