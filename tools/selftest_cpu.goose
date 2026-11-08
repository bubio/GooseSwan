// sst cpu_test: white-box self-test of CPU paths that only the WS
// machine bus exercises (the SingleStepTests corpora run on the flat
// test bus and never reach ports or the mono WRAM limit).
namespace core;

var cpu_pass: i64 = 0;
var cpu_fail: i64 = 0;

fn cpu_check(name: const u8[:], got: i64, want: i64) {
    if got == want { cpu_pass += 1; }
    else { cpu_fail += 1; print("CPU FAIL ", name, ": got ", got, " want ", want); }
}

// A V30MZ on the WS bus with zeroed RAM and ports; code goes at
// 0000:0100.
fn cpu_reset(mono: bool) {
    ws_mode = true; cpu_v20 = true; cpu_mz = true; model_mono = mono;
    for i in 0x10000 { mem[i] = 0; }
    for i in 256 { io_ports[i] = 0; }
    init_io_masks();
    sweep_prepaid = 0;
    for i in 8 { r[i] = 0; }
    for i in 4 { seg[i] = 0; }
    ip = 0x100; flags = 0xF002;
}

fn cpu_code(bytes: const u8[:]) { for i in bytes.len { mem[0x100 + i] = bytes[i]; } }

fn cpu_test() {
    // 16-bit port access at port 0xFF: the second byte wraps to port
    // 0x00 (8-bit port numbers, as Swanium's u8 wrapping_add), and must
    // not index past the 256-entry port file.
    cpu_reset(false);
    r[0] = 0x1234;
    cpu_code([0xE7, 0xFF]);  // OUT 0xFF,AX
    cpu_check("out imm8,ax ok", if exec_one() { 1 } else { 0 }, 1);
    cpu_check("out imm8,ax lo -> port ff", io_ports[0xFF], 0x34);
    cpu_check("out imm8,ax hi -> port 00", io_ports[0x00], 0x12);
    cpu_reset(false);
    r[0] = 0xBEEF; r[2] = 0x00FF;
    cpu_code([0xEF]);  // OUT DX,AX
    cpu_check("out dx,ax ok", if exec_one() { 1 } else { 0 }, 1);
    cpu_check("out dx,ax lo -> port ff", io_ports[0xFF], 0xEF);
    cpu_check("out dx,ax hi -> port 00", io_ports[0x00], 0xBE);
    cpu_reset(false);
    io_ports[0xFF] = 0x5A; io_ports[0x00] = 0x21;
    cpu_code([0xE5, 0xFF]);  // IN AX,0xFF
    cpu_check("in ax,imm8 ok", if exec_one() { 1 } else { 0 }, 1);
    cpu_check("in ax,imm8 value", r[0], (port_rd(0x00) << 8) | port_rd(0xFF));
    cpu_reset(false);
    io_ports[0xFF] = 0x5A; io_ports[0x00] = 0x21; r[2] = 0x00FF;
    cpu_code([0xED]);  // IN AX,DX
    cpu_check("in ax,dx ok", if exec_one() { 1 } else { 0 }, 1);
    cpu_check("in ax,dx value", r[0], (port_rd(0x00) << 8) | port_rd(0xFF));

    // GDMA writes go through the bus: a mono machine has 16 KB of WRAM,
    // so a destination above 0x4000 is dropped; colour lands it.
    for pass in 2 {
        let mono: bool = pass == 0;
        cpu_reset(mono);
        mem[0x0010] = 0xA5; mem[0x0011] = 0x5A;
        io_ports[0x40] = 0x10;                       // source 0:0010
        io_ports[0x44] = 0x00; io_ports[0x45] = 0x50;  // destination 0x5000
        io_ports[0x46] = 2;                          // 2 bytes
        io_ports[0x48] = 0x80;
        run_gdma();
        gdma_stall = 0;
        cpu_check(if mono { "gdma mono drops above 16 KB" } else { "gdma colour writes above 16 KB" }, mem[0x5000], if mono { 0 } else { 0xA5 });
    }

    print("cpu_test: ", cpu_pass, " passed, ", cpu_fail, " failed");
}
