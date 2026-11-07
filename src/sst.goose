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

// ---- WonderSwan machine mode (selected by the "ws" CLI argument) ----
// The SST harness keeps using the flat 1 MB array; in WS mode the physical
// address goes through the WonderSwan memory map instead: 64 KB internal
// RAM, a cartridge SRAM window, two banked ROM windows and the linear ROM
// window, all with (bank << 16 | offset) % rom_size addressing, matching
// Swanium's bus. Internal RAM stays in mem[0..0x10000) so the screen map
// and variables can be read back directly by the runner.
var ws_mode: bool = false;
var rom: u8[>..] = [];
var sram: u8[65536] = [0; 65536];
var bk_ram: i64 = 0xFF;    // port C1
var bk_rom0: i64 = 0xFF;   // port C2
var bk_rom1: i64 = 0xFF;   // port C3
var bk_linear: i64 = 0;    // port C0
var io_ports: u8[256] = [0; 256];
var int_cause: i64 = 0;
var sys_ctrl1: i64 = 0x02;  // SYSTEM_CTRL1: bits 0,1,7 are sticky identity bits (bit1 = colour-capable), bits 2,3 writable
var lfsr: i64 = 0;          // APU noise LFSR (15-bit, XNOR feedback), read back through ports 92/93
var noise_acc: i64 = 0;     // cycles accumulated towards the next LFSR step
var last_tick: i64 = 0;     // ws_cycles value at the previous ws_line_events call
var key_select: i64 = 0;
var keys_state: i64 = 0;   // Y1-4 bits 0-3, X1-4 bits 4-7, Start bit 9, A bit 10, B bit 11
var cpu_halted: bool = false;
var ws_cycles: i64 = 0;     // total CPU cycles since reset (WS mode): drives the scanline model
var last_line: i64 = 0;     // scanline the model has advanced to (0..158)
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
var io_wmask_m: i64[256] = [0; 256];   // SPHINX mono-mode port write masks (WSHWTest ioRegMasksSPHINXMono)
var io_always_m: i64[256] = [0; 256];  // SPHINX mono-mode port always-set read bits
var io_wmask_c: i64[256] = [0; 256];   // SPHINX colour-mode port write masks (WSHWTest ioRegMasksSPHINX)
var io_always_c: i64[256] = [0; 256];  // SPHINX colour-mode port always-set read bits

fn rd8(p: i64) -> u8 {
    if !ws_mode { return mem[p]; }
    if p < 0x10000 { return mem[p]; }
    if p < 0x20000 { return sram[(((bk_ram << 16) | (p & 0xFFFF)) % 65536) as i64]; }
    if rom.len == 0 { return 0xFF; }
    if p < 0x30000 { return rom[(((bk_rom0 << 16) | (p & 0xFFFF)) % rom.len) as i64]; }
    if p < 0x40000 { return rom[(((bk_rom1 << 16) | (p & 0xFFFF)) % rom.len) as i64]; }
    // The linear window is top-aligned: at reset the ROM's last bytes (the
    // footer with the entry jump) sit at the top of the address space. For
    // power-of-two sizes up to 1 MB this equals the plain modulo decode;
    // WSHWTest's 768 KB image (address space 0x40000-0xFFFFF) needs the shift.
    return rom[(((bk_linear << 20) + (p & 0xFFFFF) + rom.len - 0x100000) % rom.len) as i64];
}

fn port_rd(p: i64) -> i64 {
    if ws_mode && sweep_prepaid == 0 && (dbg_op == 0xE4 || dbg_op == 0xE5 || dbg_op == 0xEC || dbg_op == 0xED) { var pre: i64 = 2; if dbg_op == 0xE4 || dbg_op == 0xE5 { pre = 4; } sweep_advance(pre); sweep_prepaid += pre; }  // IN: sweep runs until the sample point (once per instruction)
    if p == 0x02 { return (ws_cycles % 40704) / 256; }  // LCD_LINE: current scanline (159 lines x 256 cycles)
    if p == 0xA0 { return sys_ctrl1; }  // SYSTEM_CTRL1 (drives the SPHINX flag variants in test ROMs)
    if p == 0x91 { return (io_ports[0x91] as i64) & 0x0F; }  // SND_OUT_CTRL: only the low 4 bits exist (bit 7 is a status bit, unread here)
    if p >= 0x96 && p <= 0x9B { return apu_out_port(p); }  // SND_CH_OUT: current mixer levels
    if p == 0x92 { return lfsr & 0xFF; }  // SND_RANDOM low
    if p == 0x93 { return (lfsr >> 8) & 0xFF; }  // SND_RANDOM high
    if p == 0xB0 { return (io_ports[0xB0] as i64) & 0xF8; }  // INT_VECTOR: low 3 bits do not exist
    if p == 0xB1 { return 0; }  // SERIAL_DATA: receive buffer, empty
    if p == 0xB4 { return int_cause; }  // INT_CAUSE
    if p == 0xB5 {  // KEYPAD: selector echoed back, selected scan groups OR-ed into the low nibble
        var v: i64 = key_select;
        if (key_select & 0x10) != 0 { v |= keys_state & 0x0F; }
        if (key_select & 0x20) != 0 { v |= (keys_state >> 4) & 0x0F; }
        if (key_select & 0x40) != 0 { v |= (keys_state >> 8) & 0x0F; }
        return v;
    }
    if p == 0xC0 { return bk_linear; }
    if p == 0xC1 { return bk_ram; }
    if p == 0xC2 { return bk_rom0; }
    if p == 0xC3 { return bk_rom1; }
    if p >= 0xB8 { return io_ports[p] as i64; }
    if ((io_ports[0x60] as i64) & 0x80) != 0 { return ((io_ports[p] as i64) & io_wmask_c[p]) | io_always_c[p]; }  // SYSTEM_CTRL2 VMODE_COLOR selects the mask set
    return ((io_ports[p] as i64) & io_wmask_m[p]) | io_always_m[p];
}
fn hexval(c: i64) -> i64 {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    return 0;
}
fn init_io_masks() {
    for i in 256 { io_wmask_m[i] = 0xFF; io_wmask_c[i] = 0xFF; }
    let mono = "3f000700ff00ff001f007f00ff007700ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff003f00ff00ff00ff000000ff000000ff00ff00ff00ff007700770077007700770077007700770070007700700077007000770070007700770077007700770077007700770077007000770070007700700077007000770000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff000000ff000000000000000000000000000000ff006f0000000000000000000000000000000000000000000000000000000000000000000000000000000000ff000700ff000700ff000700ff000700ff00ff00ff00ff00ff001f001700ff00ef00ff00ff00ff000f00ff00ff00ff00ff00ff00ff00ff00ff00ff0003000000ff0000000f000f00ff00ff00ff00ff00ff00ff00ff00ff00ff00000000000000ff00ff00ff00c400ff00ff0000001000";
    let colp = "3f00ff00ff00ff003f007f00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff003f00ff00ff00ff000000ff000000ff00ff00ff00ff0077007700770077007700770077007700700077007000770070007700700077007700770077007700770077007700770070007700700077007000770070007700fe00ff000f000000fe00ff00fe00ff0040000000ff00ff000f000000ff00ff000f0000005f000000000000000000000000000000000000000000000000000000ff000000ff000000000000000000000000000000ff006f0000000000000000000000000000000000000000000000000000000000000000000000000000000000ff000700ff000700ff000700ff000700ff00ff00ff00ff00ff001f001700ff00ef00ff00ff00ff000f00ff00ff00ff00ff00ff00ff00ff00ff00ff0003000000ff0000000f000f00ff00ff00ff00ff00ff00ff00ff00ff00ff00000000000000ff00ff00ff00c400ff00ff0000001000";
    for i in 184 {
        io_wmask_m[i] = hexval(mono[i * 4]) * 16 + hexval(mono[i * 4 + 1]);
        io_always_m[i] = hexval(mono[i * 4 + 2]) * 16 + hexval(mono[i * 4 + 3]);
        io_wmask_c[i] = hexval(colp[i * 4]) * 16 + hexval(colp[i * 4 + 1]);
        io_always_c[i] = hexval(colp[i * 4 + 2]) * 16 + hexval(colp[i * 4 + 3]);
    }
}
fn port_wr(p: i64, v: i64) {
    if ws_mode && sweep_prepaid == 0 && (dbg_op == 0xE6 || dbg_op == 0xE7 || dbg_op == 0xEE || dbg_op == 0xEF) { let pre: i64 = est_cycles(r[1] as i64) - 2; if pre > 0 { sweep_advance(pre); sweep_prepaid += pre; } }  // OUT: sweep runs until the write lands (once per instruction)
    if p >= 0xA8 && p <= 0xAB { return; }  // HBL/VBL timer counters are read-only
    io_ports[p] = v as! u8;
    if p == 0xA4 { io_ports[0xA8] = v as! u8; }        // writing a timer period also resets its counter (per byte)
    else if p == 0xA5 { io_ports[0xA9] = v as! u8; }
    else if p == 0xA6 { io_ports[0xAA] = v as! u8; }
    else if p == 0xA7 { io_ports[0xAB] = v as! u8; }
    if p == 0x8E && (v & 0x08) != 0 { lfsr = 0; noise_acc = 0; io_ports[0x8E] = (v & 0xF7) as! u8; }  // SND_NOISE_CTRL reset: reseed LFSR, bit self-clears
    if p == 0x8C || p == 0x8D { sweep_ctr = 0; sweep_step = 0; }  // sweep register writes reset the sweep timer
    if p == 0x48 && (v & 0x80) != 0 { run_gdma(); }  // GDMA trigger: synchronous burst on the enable write
    if p == 0xA0 { sys_ctrl1 = (sys_ctrl1 & 0x87) | (v & 0x0C); }
    else if p == 0xB5 { key_select = v & 0x70; }  // KEYPAD: only select bits 4-6 exist
    else if p == 0xB6 { int_cause = int_cause & ~v; }  // INT_CAUSE_CLEAR
    else if p == 0xC0 { bk_linear = v & 0x3F; }
    else if p == 0xC1 { bk_ram = v; }
    else if p == 0xC2 { bk_rom0 = v; }
    else if p == 0xC3 { bk_rom1 = v; }
}

fn hbl_count() -> i64 { (io_ports[0xA8] as i64) | ((io_ports[0xA9] as i64) << 8) }
fn set_hbl_count(v: i64) { io_ports[0xA8] = (v & 0xFF) as! u8; io_ports[0xA9] = ((v >> 8) & 0xFF) as! u8; }
fn vbl_count() -> i64 { (io_ports[0xAA] as i64) | ((io_ports[0xAB] as i64) << 8) }
fn set_vbl_count(v: i64) { io_ports[0xAA] = (v & 0xFF) as! u8; io_ports[0xAB] = ((v >> 8) & 0xFF) as! u8; }
fn tick_hbl() {
    let cnt: i64 = hbl_count();
    if cnt == 0 { return; }
    let ctrl: i64 = io_ports[0xA2] as i64;
    let irqen: bool = ((io_ports[0xB2] as i64) & 0x80) != 0;
    if (ctrl & 1) == 0 && !(cnt == 1 && irqen) { return; }  // disabled, except the counter=1 latch quirk (Swanium)
    if cnt == 1 {
        if irqen { int_cause |= 0x80; }
        if (ctrl & 2) != 0 { set_hbl_count((io_ports[0xA4] as i64) | ((io_ports[0xA5] as i64) << 8)); } else { set_hbl_count(0); }
    } else { set_hbl_count(cnt - 1); }
}
fn tick_vbl() {
    int_cause |= 0x40 & (io_ports[0xB2] as i64);  // VBLANK_START latches into INT_CAUSE only when enabled (WSHWTest verifies this)
    let ctrl: i64 = io_ports[0xA2] as i64;
    if (ctrl & 4) == 0 { return; }
    let cnt: i64 = vbl_count();
    if cnt == 0 { return; }
    if cnt == 1 {
        if ((io_ports[0xB2] as i64) & 0x20) != 0 { int_cause |= 0x20; }
        if (ctrl & 8) != 0 { set_vbl_count((io_ports[0xA6] as i64) | ((io_ports[0xA7] as i64) << 8)); } else { set_vbl_count(0); }
    } else { set_vbl_count(cnt - 1); }
}
fn step_lfsr() {
    let mode: i64 = (io_ports[0x8E] as i64) & 7;
    var tap: i64 = 14;
    if mode == 1 { tap = 10; } else if mode == 2 { tap = 13; } else if mode == 3 { tap = 4; } else if mode == 4 { tap = 8; } else if mode == 5 { tap = 6; } else if mode == 6 { tap = 9; } else if mode == 7 { tap = 11; }
    let fb: i64 = 1 ^ ((lfsr >> 7) & 1) ^ ((lfsr >> tap) & 1);
    lfsr = ((lfsr << 1) | fb) & 0x7FFF;
}
fn noise_tick(dc: i64) {
    if ((io_ports[0x8E] as i64) & 0x10) == 0 { return; }        // NOISE_ENABLE
    if ((io_ports[0x90] as i64) & 0x88) != 0x88 { return; }     // channel 4 on + noise mode
    let pitch: i64 = (io_ports[0x86] as i64) | (((io_ports[0x87] as i64) & 7) << 8);
    let period: i64 = 2048 - pitch;
    noise_acc += dc;
    while noise_acc >= period { noise_acc -= period; step_lfsr(); }
}

// ---- PPU: background rendering (SCR1/SCR2 + windows, mono and colour) ----
// Model follows Swanium's ppu module: the framebuffer holds one RGB444
// value per pixel (224x144). Lines are rendered as they complete in
// ws_line_events, from live ports/RAM. Sprites are not rendered yet.
var fb: u16[32256] = [0; 32256];

fn ppu_color_mode() -> bool { return ((io_ports[0x60] as i64) & 0x80) != 0; }

fn ppu_tile_pixel(tile: i64, tx: i64, ty: i64) -> i64 {
    let vm: i64 = io_ports[0x60] as i64;
    if (vm & 0x80) != 0 && (vm & 0x40) != 0 {
        let base: i64 = 0x4000 + tile * 32 + ty * 4;
        if (vm & 0x20) != 0 {
            let b: i64 = mem[base + (tx >> 1)] as i64;
            if (tx & 1) == 0 { return (b >> 4) & 15; }
            return b & 15;
        }
        var px: i64 = 0;
        let bit: i64 = 7 - tx;
        for pl in 4 { px |= (((mem[base + pl] as i64) >> bit) & 1) << pl; }
        return px;
    }
    let a: i64 = 0x2000 + tile * 16 + ty * 2;
    let bit2: i64 = 7 - tx;
    let lo: i64 = ((mem[a] as i64) >> bit2) & 1;
    let hi: i64 = ((mem[a + 1] as i64) >> bit2) & 1;
    return (hi << 1) | lo;
}

fn ppu_shade(idx: i64) -> i64 {
    let b: i64 = io_ports[0x1C + (idx >> 1)] as i64;
    if (idx & 1) == 0 { return b & 15; }
    return (b >> 4) & 15;
}

fn ppu_grey(shade: i64) -> i64 { let n: i64 = 15 - (shade & 15); return (n << 8) | (n << 4) | n; }

fn ppu_resolve_mono(pal: i64, pixel: i64) -> i64 {
    let b: i64 = io_ports[0x20 + pal * 2 + (pixel >> 1)] as i64;
    var pool: i64 = (b >> 4) & 7;
    if (pixel & 1) == 0 { pool = b & 7; }
    return ppu_grey(ppu_shade(pool));
}

fn ppu_resolve_color(pal: i64, pixel: i64) -> i64 {
    let a: i64 = 0xFE00 + (pal * 16 + pixel) * 2;
    return ((mem[a] as i64) | ((mem[a + 1] as i64) << 8)) & 0xFFF;
}

fn ppu_resolve(pal: i64, pixel: i64) -> i64 {
    if ppu_color_mode() { return ppu_resolve_color(pal, pixel); }
    return ppu_resolve_mono(pal, pixel);
}

fn ppu_transparent(pal: i64, pixel: i64) -> bool {
    if pixel != 0 { return false; }
    if ppu_color_mode() { return true; }
    return !((pal >= 0 && pal <= 3) || (pal >= 8 && pal <= 11));
}

fn ppu_backdrop() -> i64 {
    let b: i64 = io_ports[0x01] as i64;
    if ppu_color_mode() { return ppu_resolve_color(b >> 4, b & 15); }
    return ppu_grey(ppu_shade(b & 7));
}

fn ppu_bg_sample(layer: i64, x: i64, y: i64) -> i64, i64 {
    var sx: i64 = io_ports[0x10] as i64;
    var sy: i64 = io_ports[0x11] as i64;
    var nib: i64 = (io_ports[0x07] as i64) & 0x0F;
    if layer == 1 { sx = io_ports[0x12] as i64; sy = io_ports[0x13] as i64; nib = ((io_ports[0x07] as i64) >> 4) & 0x0F; }
    if !ppu_color_mode() { nib = nib & 7; }
    let base: i64 = nib << 11;
    let bgx: i64 = (x + sx) & 0xFF;
    let bgy: i64 = (y + sy) & 0xFF;
    let ea: i64 = base + (((bgy >> 3) * 32) + (bgx >> 3)) * 2;
    let w: i64 = (mem[ea] as i64) | ((mem[ea + 1] as i64) << 8);
    var tile: i64 = w & 0x1FF;
    if ppu_color_mode() && (w & 0x2000) != 0 { tile += 512; }
    let pal: i64 = (w >> 9) & 0x0F;
    var tx: i64 = bgx & 7;
    var ty: i64 = bgy & 7;
    if (w & 0x4000) != 0 { tx = 7 - tx; }
    if (w & 0x8000) != 0 { ty = 7 - ty; }
    return ppu_tile_pixel(tile, tx, ty), pal;
}

fn ppu_scr2_visible(x: i64, y: i64) -> bool {
    let dc: i64 = io_ports[0x00] as i64;
    if (dc & 0x20) == 0 { return true; }
    let inside: bool = x >= (io_ports[0x08] as i64) && x <= (io_ports[0x0A] as i64) && y >= (io_ports[0x09] as i64) && y <= (io_ports[0x0B] as i64);
    if (dc & 0x10) != 0 { return !inside; }
    return inside;
}

// Sprite line buffers: the first opaque sprite pixel per column (any
// priority) and the first opaque priority-1 (in front of SCR2) pixel.
var spr_any_c: i64[224] = [0; 224];
var spr_any_on: bool[224] = [false; 224];
var spr_front_c: i64[224] = [0; 224];
var spr_front_on: bool[224] = [false; 224];

// Fill the sprite line buffers for line y from the live attribute table
// (Swanium latches the table per frame; sampling it per line is the
// documented simplification here). At most 32 sprites per line count,
// in table order starting at SPR_FIRST; X wraps at 256.
fn ppu_sprite_line(y: i64) {
    for i in 224 { spr_any_on[i] = false; spr_front_on[i] = false; }
    let base: i64 = ((io_ports[0x04] as i64) & 0x3F) << 9;
    let first: i64 = io_ports[0x05] as i64;
    var count: i64 = io_ports[0x06] as i64; if count > 128 { count = 128; }
    let dc: i64 = io_ports[0x00] as i64;
    var used: i64 = 0;
    var n: i64 = 0;
    while n < count && used < 32 {
        let idx: i64 = (first + n) & 127; n += 1;
        let ea: i64 = base + idx * 4;
        let w: i64 = (mem[ea] as i64) | ((mem[ea + 1] as i64) << 8);
        let sy: i64 = mem[ea + 2] as i64;
        let sx: i64 = mem[ea + 3] as i64;
        var dy: i64 = y - sy; if dy < 0 { dy += 256; }
        if dy >= 8 { continue; }
        used += 1;
        var ty: i64 = dy; if (w & 0x8000) != 0 { ty = 7 - ty; }
        let tile: i64 = w & 0x1FF;
        let pal: i64 = ((w >> 9) & 7) + 8;
        let prio: bool = (w & 0x2000) != 0;
        let wattr: bool = (w & 0x1000) != 0;
        for dx in 8 {
            var x: i64 = sx + dx; if x >= 256 { x -= 256; }
            if x >= 224 { continue; }
            if spr_any_on[x] && (!prio || spr_front_on[x]) { continue; }
            if (dc & 8) != 0 && wattr && x >= (io_ports[0x0C] as i64) && x <= (io_ports[0x0E] as i64) && y >= (io_ports[0x0D] as i64) && y <= (io_ports[0x0F] as i64) { continue; }
            var tx: i64 = dx; if (w & 0x4000) != 0 { tx = 7 - tx; }
            let px: i64 = ppu_tile_pixel(tile, tx, ty);
            if ppu_transparent(pal, px) { continue; }
            let c: i64 = ppu_resolve(pal, px);
            if !spr_any_on[x] { spr_any_on[x] = true; spr_any_c[x] = c; }
            if prio && !spr_front_on[x] { spr_front_on[x] = true; spr_front_c[x] = c; }
        }
    }
}

fn render_line(y: i64) {
    if y < 0 || y >= 144 { return; }
    let dc: i64 = io_ports[0x00] as i64;
    let bd: i64 = ppu_backdrop();
    let row: i64 = y * 224;
    if (dc & 4) != 0 { ppu_sprite_line(y); }
    for x in 224 {
        var c: i64 = bd;
        if (dc & 1) != 0 { let px, pal = ppu_bg_sample(0, x, y); if !ppu_transparent(pal, px) { c = ppu_resolve(pal, px); } }
        var s2_on: bool = false;
        var s2_c: i64 = 0;
        if (dc & 2) != 0 && ppu_scr2_visible(x, y) { let px2, pal2 = ppu_bg_sample(1, x, y); if !ppu_transparent(pal2, px2) { s2_on = true; s2_c = ppu_resolve(pal2, px2); } }
        if (dc & 4) != 0 {
            if s2_on { if spr_front_on[x] { c = spr_front_c[x]; } else { c = s2_c; } }
            else if spr_any_on[x] { c = spr_any_c[x]; }
        } else if s2_on { c = s2_c; }
        fb[row + x] = c as! u16;
    }
}

fn fb_hash() -> i64 {
    var h: i64 = 5381;
    for i in 32256 { h = ((h << 5) + h) ^ (fb[i] as i64); }
    return h;
}

fn fb_write_ppm() {
    var ppm: u8[>..] = [];
    let hdr = "P6\n224 144\n255\n";
    for i in hdr.len { ppm.push(hdr[i]); }
    for i in 32256 {
        let c: i64 = fb[i] as i64;
        ppm.push((((c >> 8) & 15) * 17) as! u8);
        ppm.push((((c >> 4) & 15) * 17) as! u8);
        ppm.push(((c & 15) * 17) as! u8);
    }
    write_file("framebuffer.ppm", ppm);
}


// ---- APU: wave channels, sweep, mixer readback, GDMA ----
// Channel/sweep state follows Swanium's apu module. The audible sample
// stream is not generated (no frontend yet); what is modelled is every
// CPU-visible surface: channel sample state behind the SND_CH_OUT
// readback ports 0x96-0x9B, the sweep's pitch write-back, and GDMA.
var ch_period: i64[4] = [0; 4];
var ch_idx: i64[4] = [0; 4];
var ch_sample: i64[4] = [0; 4];
var sweep_ctr: i64 = 0;
var sweep_step: i64 = 0;
var fast_primed: bool = false;

fn apu_pitch(ch: i64) -> i64 {
    return ((io_ports[0x80 + ch * 2] as i64) | ((io_ports[0x81 + ch * 2] as i64) << 8)) & 0x7FF;
}

fn apu_read_wave(ch: i64) {
    let base: i64 = ((io_ports[0x8F] as i64) << 6) + ch * 16;
    let b: i64 = mem[base + (ch_idx[ch] >> 1)] as i64;
    if (ch_idx[ch] & 1) == 0 { ch_sample[ch] = b & 0x0F; } else { ch_sample[ch] = (b >> 4) & 0x0F; }
}

fn apu_chan_advance(ch: i64, dc: i64) {
    let period: i64 = 2048 - apu_pitch(ch);
    var rem: i64 = dc;
    var first: i64 = ch_period[ch]; if first == 0 { first = 1; }
    if rem < first { ch_period[ch] -= rem; return; }
    rem -= first;
    ch_idx[ch] = (ch_idx[ch] + 1) & 0x1F;
    apu_read_wave(ch);
    if rem == 0 { ch_period[ch] = period; return; }
    let extra: i64 = rem / period;
    if extra != 0 { ch_idx[ch] = (ch_idx[ch] + extra) & 0x1F; apu_read_wave(ch); }
    ch_period[ch] = period - (rem % period);
}

fn apu_sweep_apply() {
    var delta: i64 = io_ports[0x8C] as i64; if delta >= 128 { delta -= 256; }
    var np: i64 = apu_pitch(2) + delta;
    if np > 2047 { np = 0; } else if np < 0 { np = 2047; }
    io_ports[0x84] = (np & 0xFF) as! u8;
    io_ports[0x85] = ((np >> 8) & 0xFF) as! u8;
}

fn apu_sweep_tick() {
    if sweep_step > 0 { sweep_step -= 1; return; }
    sweep_step = (io_ports[0x8D] as i64) & 0x1F;
    apu_sweep_apply();
}

var sweep_prepaid: i64 = 0;

fn sweep_advance(dc: i64) {
    if dc <= 0 { return; }
    let ctrl: i64 = io_ports[0x90] as i64;
    if (ctrl & 0x40) == 0 || (ctrl & 0x04) == 0 { fast_primed = false; return; }
    if ((io_ports[0x95] as i64) & 0x02) != 0 {
        var ticks: i64 = dc;
        if !fast_primed { fast_primed = true; ticks -= 1; }
        var i: i64 = 0;
        while i < ticks { apu_sweep_tick(); i += 1; }
    } else {
        sweep_ctr += dc;
        while sweep_ctr > 8192 { sweep_ctr -= 8193; apu_sweep_tick(); }
    }
}

fn apu_tick(dc: i64) {
    if dc <= 0 { return; }
    let ctrl: i64 = io_ports[0x90] as i64;
    for ch in 4 { if (ctrl & (1 << ch)) != 0 { apu_chan_advance(ch, dc); } }
    var sdc: i64 = dc - sweep_prepaid;
    sweep_prepaid = 0;
    if sdc > 0 { sweep_advance(sdc); }
}

// Port accesses land partway through an IN/OUT instruction, not at
// its end: WSHWTest's fast-sweep CPU-cycle case pins the pitch write
// to 2 cycles before the end of OUT imm8 (7 cycles, so 5 cycles run
// before the write takes effect) and the pitch sample to 4 cycles
// into IN imm8. port_rd/port_wr therefore pre-charge the sweep for
// the cycles that elapse before the access, and apu_tick skips the
// prepaid part of the next delta. Only the sweep is cycle-sensitive
// at this granularity; channel phase and the noise LFSR are not
// pre-charged (their test suites pass without it).

fn apu_out_port(p: i64) -> i64 {
    let ctrl: i64 = io_ports[0x90] as i64;
    var left: i64 = 0;
    var right: i64 = 0;
    for ch in 4 {
        if (ctrl & (1 << ch)) == 0 { continue; }
        if ch == 1 && (ctrl & 0x20) != 0 { continue; }
        var s: i64 = ch_sample[ch];
        if ch == 3 && (ctrl & 0x80) != 0 && ((io_ports[0x8E] as i64) & 0x10) != 0 && (ctrl & 0x88) == 0x88 { if (lfsr & 1) != 0 { s = 15; } else { s = 0; } }
        let vol: i64 = io_ports[0x88 + ch] as i64;
        left += s * (vol >> 4);
        right += s * (vol & 0x0F);
    }
    if (ctrl & 0x20) != 0 { let vv: i64 = io_ports[0x89] as i64; left += vv; right += vv; }
    var v: i64 = left + right;
    if (p & 0xFE) == 0x96 { v = right; }
    if (p & 0xFE) == 0x98 { v = left; }
    return (v >> ((p & 1) * 8)) & 0xFF;
}

fn run_gdma() {
    var src: i64 = (((io_ports[0x42] as i64) & 0x0F) << 16) | ((io_ports[0x40] as i64) | ((io_ports[0x41] as i64) << 8));
    var dst: i64 = (io_ports[0x44] as i64) | ((io_ports[0x45] as i64) << 8);
    var len: i64 = (io_ports[0x46] as i64) | ((io_ports[0x47] as i64) << 8);
    let dec: bool = ((io_ports[0x48] as i64) & 0x40) != 0;
    var moved: i64 = 0;
    while len > 0 {
        if src >= 0x10000 && src < 0x20000 { break; }
        if src >= 0x80000 && src < 0x90000 && (sys_ctrl1 & 0x08) != 0 { break; }
        mem[dst & 0xFFFF] = rd8(src);
        if dec { src -= 1; dst -= 1; } else { src += 1; dst += 1; }
        src &= 0xFFFFF; dst &= 0xFFFF;
        len -= 1;
        moved += 1;
    }
    io_ports[0x40] = (src & 0xFF) as! u8;
    io_ports[0x41] = ((src >> 8) & 0xFF) as! u8;
    io_ports[0x42] = ((src >> 16) & 0x0F) as! u8;
    io_ports[0x44] = (dst & 0xFF) as! u8;
    io_ports[0x45] = ((dst >> 8) & 0xFF) as! u8;
    io_ports[0x46] = (len & 0xFF) as! u8;
    io_ports[0x47] = ((len >> 8) & 0xFF) as! u8;
    io_ports[0x48] = ((io_ports[0x48] as i64) & 0x7F) as! u8;
    int_cause |= 0x08 & (io_ports[0xB2] as i64);
    if moved > 0 { ws_cycles += 5 + moved; }
}

fn ws_line_events() {
    let apu_dc: i64 = ws_cycles - last_tick;
    noise_tick(apu_dc);
    apu_tick(apu_dc);
    last_tick = ws_cycles;
    let line: i64 = (ws_cycles % 40704) / 256;
    while last_line != line {
        last_line += 1; if last_line >= 159 { last_line = 0; }
        tick_hbl();
        if last_line == 144 { tick_vbl(); }
        if last_line == (io_ports[0x03] as i64) && last_line < 159 { int_cause |= 0x10 & (io_ports[0xB2] as i64); }
        var completed: i64 = last_line - 1; if completed < 0 { completed += 159; }
        if completed < 144 { render_line(completed); }
    }
}
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
    cyc_tab[0xF1] = 1; cyc_tab[0xF5] = 4; cyc_tab[0xF6] = 5; cyc_tab[0xF7] = 5; cyc_tab[0xFE] = 3; cyc_tab[0xFF] = 5;
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
    else if op == 0xFE { c = cyc_fe() + ea_premium(op); }
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

// Deliver the highest-priority pending hardware interrupt, if any is
// enabled and IF is set. Cause bits stay set until software clears them
// through port B6, as on hardware.
fn ws_deliver_int() {
    let pending: i64 = int_cause & (io_ports[0xB2] as i64);
    if pending == 0 { return; }
    cpu_halted = false;  // a pending enabled interrupt wakes HLT even with IF=0 (it just isn't serviced then; WSTimingTest's HLT case relies on this)
    if (flags & 0x0200) == 0 { return; }
    var bit: i64 = 7;
    while bit > 0 && ((pending >> bit) & 1) == 0 { bit -= 1; }
    do_int(((io_ports[0xB0] as i64) & 0xF8) + bit);
}

// Memory written during a case, so the next case can restore zeros.
var touched: i64[>..<] = [];
var recording: bool = false;

fn phys(s: u16, off: u16) -> i64 { (((s as i64) << 4) + (off as i64)) & 0xFFFFF }
fn rb16(p: i64) -> u16 { (rd8(p) as u16) | ((rd8((p + 1) & 0xFFFFF) as u16) << 8) }
// Word access through a segment: the second byte wraps at the 64 KB offset
// boundary (offset 0xFFFF is followed by offset 0x0000), as on real hardware.
fn seg_rd16(base: i64, off: i64) -> u16 { (rd8((base + off) & 0xFFFFF) as u16) | ((rd8((base + ((off + 1) & 0xFFFF)) & 0xFFFFF) as u16) << 8) }
fn seg_wr16(base: i64, off: i64, v: u16) { wb8((base + off) & 0xFFFFF, v as! u8); wb8((base + ((off + 1) & 0xFFFF)) & 0xFFFFF, (v >> 8) as! u8); }
fn wb8(p: i64, v: u8) {
    if ws_mode {
        if p < 0x10000 { mem[p] = v; }
        else if p < 0x20000 { sram[(((bk_ram << 16) | (p & 0xFFFF)) % 65536) as i64] = v; }
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
fn do_int(n: i64) {
    if cyc_in_exec && dbg_op != 0xCC && dbg_op != 0xCD { fault_chg = 44; fault_base = cyc_fault_base(); }  // fault/interrupt-entry charge for the cycle estimator (INT opcodes carry theirs in cyc_tab)
    push16(flags as i64);
    push16(seg[1] as i64);
    push16(ip as i64);
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
    if op == 0xFE { decode_modrm(); if d_reg == 0 { let v = read_rm(false); write_rm(false, do_incdec(v, false, 8)); return true; } if d_reg == 1 { let v = read_rm(false); write_rm(false, do_incdec(v, true, 8)); return true; } if d_reg == 6 { r[4] = r[4] - 2; let v = read_rm(true); seg_wr16((seg[2] as i64) << 4, r[4] as i64, v as! u16); return true; } if cpu_mz && d_reg == 7 { return true; } return false; }  // FE /6 = PUSH (word operand, SP first) as in the FF group; /7 is a NOP on the MZ
    if op == 0xFF { decode_modrm();
        if d_reg == 0 { let v = read_rm(true); write_rm(true, do_incdec(v, false, 16)); return true; }
        if d_reg == 1 { let v = read_rm(true); write_rm(true, do_incdec(v, true, 16)); return true; }
        if d_reg == 2 { let t = read_rm(true); push16(ip as i64); ip = t as! u16; return true; }  // CALL Ev
        if d_reg == 3 { if d_isreg && !cpu_mz { return false; } let nip: i64 = seg_rd16(d_segbase, d_off); let ncs: i64 = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); push16(seg[1] as i64); push16(ip as i64); ip = nip as! u16; seg[1] = ncs as! u16; return true; }  // CALL far Ev (mod=3 on the MZ reads at the adder EA)
        if d_reg == 4 { ip = read_rm(true) as! u16; return true; }  // JMP Ev
        if d_reg == 5 { if d_isreg && !cpu_mz { return false; } ip = seg_rd16(d_segbase, d_off); seg[1] = seg_rd16(d_segbase, (d_off + 2) & 0xFFFF); return true; }  // JMP far Ev (mod=3 on the MZ reads at the adder EA)
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
    if op == 0x07 || op == 0x0F || op == 0x17 || op == 0x1F { let v = pop16(); seg[(op >> 3) & 3] = v as! u16; return true; }  // POP seg (0F = POP CS, 8086 only)
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
    if op == 0xCF { ip = pop16() as! u16; seg[1] = pop16() as! u16; load_flags(pop16()); return true; }  // IRET
    if op == 0x98 { if (r[0] & 0x80) != 0 { r[0] = (r[0] & 0xFF) | 0xFF00; } else { r[0] = r[0] & 0xFF; } return true; }  // CBW
    if op == 0x99 { r[2] = if (r[0] & 0x8000) != 0 { 0xFFFF } else { 0 }; return true; }  // CWD
    if op == 0x9C { push16(flags as i64); return true; }  // PUSHF
    if op == 0x9D { load_flags(pop16()); return true; }  // POPF
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
    if op == 0xFB { flags = flags | 0x0200; return true; }  // STI
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
    if op == 0x8E { decode_modrm(); let v = read_rm(true); seg[d_reg & 3] = v as! u16; return true; }  // MOV seg,Ev
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
    if op == 0xCD { let n = fetch8(); do_int(n as i64); return true; }  // INT imm8
    if op == 0xCE { if ((flags as i64 >> 11) & 1) == 1 { do_int(4); } return true; }  // INTO

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

// Render the background map as text: the low byte of each map entry is the
// character code (that is how test ROMs print), the BG scroll Y register
// gives the first visible map row.
fn ws_screen_text(buf: u8[:]) -> i64 {
    let mapbase: i64 = ((io_ports[0x07] as i64) & 0x0F) << 11;
    let top: i64 = ((io_ports[0x11] as i64) >> 3) & 31;
    var n: i64 = 0;
    for y in 18 {
        let row: i64 = (top + y) & 31;
        for x in 28 {
            let c = mem[mapbase + (row * 32 + x) * 2];
            buf[n] = if c >= 32 && c < 127 { c } else { 46 };  // '.' for non-printables
            n += 1;
        }
        buf[n] = 10; n += 1;
    }
    n
}

fn count_ok(buf: u8[:], n: i64) -> i64 {
    var cnt: i64 = 0;
    var i: i64 = 0;
    while i + 1 < n {
        if buf[i] == 79 && buf[i + 1] == 107 { cnt += 1; }  // "Ok"
        i += 1;
    }
    cnt
}

// Run a WonderSwan ROM headlessly: reset to CS=FFFF:0000 (the linear
// window's modulo decode lands on the cartridge footer), raise VBlank
// once per frame of executed steps, and script a single A press so menu
// driven test ROMs start their "Test All". Stops when the screen shows
// "Ok" at least 7 times (one per suite), when the screen has been frozen
// for 600 frames (a failure stop inside the ROM), or at the frame cap.

// ---- PPU synthetic self-test (sst ppu_test) ----
// Hand-built scenes with hand-computed expected pixels: mono palettes and
// transparency, scroll, hflip, SCR2 windowing, colour palette RAM, the
// tile-bank bit and 4bpp packed tiles.
var ppu_pass: i64 = 0;
var ppu_fail: i64 = 0;

fn ppu_check(name: u8[:], got: i64, exp: i64) {
    if got == exp { ppu_pass += 1; } else { ppu_fail += 1; print("PPU FAIL ", name, ": got ", got, " expected ", exp); }
}

fn ppu_clear() {
    for i in 256 { io_ports[i] = 0; }
    for i in 65536 { mem[i] = 0; }
    for i in 32256 { fb[i] = 0; }
}

fn ppu_set16(addr: i64, w: i64) { mem[addr] = (w & 0xFF) as! u8; mem[addr + 1] = ((w >> 8) & 0xFF) as! u8; }

fn ppu_set_sprite(ea: i64, w: i64, yy: i64, xx: i64) { ppu_set16(ea, w); mem[ea + 2] = yy as! u8; mem[ea + 3] = xx as! u8; }

fn ppu_setup_sprite_common() {
    io_ports[0x30] = 0x10; io_ports[0x31] = 0x32;
    io_ports[0x38] = 0x02; io_ports[0x39] = 0x13;
    mem[0x2000 + 32] = 0xFF; mem[0x2000 + 33] = 0x00;
    for i in 6 { ppu_set16(i * 2, 2); }
}

fn ppu_setup_mono() {
    io_ports[0x1C] = 0x0F;
    io_ports[0x1D] = 0x37;
    io_ports[0x01] = 2;
    io_ports[0x20] = 0x10; io_ports[0x21] = 0x32;
    io_ports[0x28] = 0x10; io_ports[0x29] = 0x32;
    mem[0x2000 + 16] = 0xAA; mem[0x2000 + 17] = 0xCC;
}

fn ppu_test() {
    // Scene 1: mono SCR1 (tile 1 row 0 = pixels 3,2,1,0,3,2,1,0)
    ppu_clear();
    ppu_setup_mono();
    ppu_set16(0, 1);
    ppu_set16(2, 1 | (4 << 9) | (1 << 14));
    io_ports[0x00] = 1;
    io_ports[0x07] = 0;
    render_line(0);
    ppu_check("s1 x0 pix3", fb[0] as i64, 0xCCC);
    ppu_check("s1 x1 pix2", fb[1] as i64, 0x888);
    ppu_check("s1 x2 pix1", fb[2] as i64, 0xFFF);
    ppu_check("s1 x3 pix0 pal0 opaque", fb[3] as i64, 0x000);
    ppu_check("s1 x8 pal4 flipped pix0 transparent", fb[8] as i64, 0x888);
    ppu_check("s1 x11 pal4 flipped pix3", fb[11] as i64, 0xCCC);
    ppu_check("s1 x100 empty entry", fb[100] as i64, 0x000);
    io_ports[0x10] = 8;
    render_line(0);
    ppu_check("s1 scroll x0", fb[0] as i64, 0x888);
    ppu_check("s1 scroll x3", fb[3] as i64, 0xCCC);
    ppu_check("s1 scroll x8", fb[8] as i64, 0x000);
    // Scene 2: SCR2 window (tile 2 = all pixel 1 -> 0xFFF)
    ppu_clear();
    ppu_setup_mono();
    mem[0x2000 + 32] = 0xFF; mem[0x2000 + 33] = 0x00;
    ppu_set16(0, 1);
    io_ports[0x07] = 0x10;
    ppu_set16(0x800, 2);
    io_ports[0x08] = 0; io_ports[0x09] = 0; io_ports[0x0A] = 3; io_ports[0x0B] = 0;
    io_ports[0x00] = 1 | 2 | 0x20;
    render_line(0);
    ppu_check("s2 x0 scr2 inside", fb[0] as i64, 0xFFF);
    ppu_check("s2 x1 scr2 inside", fb[1] as i64, 0xFFF);
    ppu_check("s2 x4 scr1 outside", fb[4] as i64, 0xCCC);
    io_ports[0x00] = 1 | 2 | 0x20 | 0x10;
    render_line(0);
    ppu_check("s2 x0 scr1 outside-mode", fb[0] as i64, 0xCCC);
    ppu_check("s2 x4 scr2 outside-mode", fb[4] as i64, 0xFFF);
    // Scene 3: colour mode
    ppu_clear();
    io_ports[0x60] = 0x80;
    io_ports[0x01] = 0x05;
    ppu_set16(0xFE00 + 2, 0x123);
    ppu_set16(0xFE00 + 4, 0x0F0);
    ppu_set16(0xFE00 + 6, 0xF00);
    ppu_set16(0xFE00 + 10, 0xABC);
    mem[0x2000 + 16] = 0xAA; mem[0x2000 + 17] = 0xCC;
    ppu_set16(0, 1);
    io_ports[0x00] = 1;
    io_ports[0x07] = 0;
    render_line(0);
    ppu_check("s3 x0 color3", fb[0] as i64, 0xF00);
    ppu_check("s3 x1 color2", fb[1] as i64, 0x0F0);
    ppu_check("s3 x2 color1", fb[2] as i64, 0x123);
    ppu_check("s3 x3 transparent backdrop", fb[3] as i64, 0xABC);
    mem[0x2000 + 513 * 16] = 0xFF; mem[0x2000 + 513 * 16 + 1] = 0xFF;
    ppu_set16(2, 1 | (1 << 13));
    render_line(0);
    ppu_check("s3 x8 bank tile", fb[8] as i64, 0xF00);
    io_ports[0x60] = 0x80 | 0x40 | 0x20;
    mem[0x4000 + 32] = 0x12; mem[0x4000 + 33] = 0x34; mem[0x4000 + 34] = 0x56; mem[0x4000 + 35] = 0x78;
    for k in 8 { ppu_set16(0xFE00 + (k + 1) * 2, (k + 1) * 0x111); }
    ppu_set16(2, 0);
    render_line(0);
    ppu_check("s3 4bpp x0", fb[0] as i64, 0x111);
    ppu_check("s3 4bpp x1", fb[1] as i64, 0x222);
    ppu_check("s3 4bpp x6", fb[6] as i64, 0x777);
    ppu_check("s3 4bpp x7", fb[7] as i64, 0x888);
    // Scene 4: sprites
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x06] = 2;
    io_ports[0x00] = 1 | 4;
    ppu_set_sprite(0x800, 1, 0, 16);
    ppu_set_sprite(0x804, 1 | (4 << 9), 0, 20);
    render_line(0);
    ppu_check("s4 bg x0", fb[0] as i64, 0xFFF);
    ppu_check("s4 spr0 x16 pix3", fb[16] as i64, 0xCCC);
    ppu_check("s4 spr0 x17 pix2", fb[17] as i64, 0x888);
    ppu_check("s4 spr0 x19 pix0 pal8 opaque", fb[19] as i64, 0x000);
    ppu_check("s4 spr0 wins x20", fb[20] as i64, 0xCCC);
    ppu_check("s4 spr1 x25 pix2 pal12", fb[25] as i64, 0xCCC);
    ppu_check("s4 spr1 x27 pix0 transparent", fb[27] as i64, 0xFFF);
    // Priority vs SCR2 (sprites move to 0xC00; SCR2 takes base 0x800)
    io_ports[0x07] = 0x10;
    io_ports[0x04] = 6;
    io_ports[0x06] = 3;
    io_ports[0x00] = 1 | 2 | 4;
    mem[0x2000 + 48] = 0x00; mem[0x2000 + 49] = 0xFF;
    ppu_set16(0x800, 3);
    ppu_set16(0x802, 4 << 9);
    ppu_set_sprite(0xC00, 1, 0, 0);
    ppu_set_sprite(0xC04, 1 | (1 << 13), 0, 16);
    ppu_set_sprite(0xC08, 1, 0, 8);
    render_line(0);
    ppu_check("s4 prio0 behind scr2 x0", fb[0] as i64, 0x888);
    ppu_check("s4 prio0 through transparent scr2 x8", fb[8] as i64, 0xCCC);
    ppu_check("s4 prio1 front of scr2 x16", fb[16] as i64, 0xCCC);
    // Sprite window: sprite D (prio 1, window attr) at x32, window x 0..35
    ppu_set_sprite(0xC0C, 1 | (1 << 13) | (1 << 12), 0, 32);
    io_ports[0x06] = 4;
    io_ports[0x00] = 1 | 2 | 4 | 8;
    io_ports[0x0C] = 0; io_ports[0x0D] = 0; io_ports[0x0E] = 35; io_ports[0x0F] = 0;
    render_line(0);
    ppu_check("s4 sprwin hidden x32", fb[32] as i64, 0x000);
    ppu_check("s4 sprwin shown x36", fb[36] as i64, 0xCCC);
    // 32-per-line limit: 32 transparent sprites consume the line's slots
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x00] = 1 | 4;
    for i in 33 {
        if i < 32 { ppu_set_sprite(0x800 + i * 4, 4 << 9, 0, i * 8); }
        else { ppu_set_sprite(0x800 + i * 4, 1, 0, 16); }
    }
    io_ports[0x06] = 33;
    render_line(0);
    ppu_check("s4 limit 33rd ignored x16", fb[16] as i64, 0xFFF);
    ppu_set_sprite(0x800 + 5 * 4, 1, 0, 16);
    ppu_set_sprite(0x800 + 32 * 4, 4 << 9, 0, 128);
    render_line(0);
    ppu_check("s4 limit slot5 visible x16", fb[16] as i64, 0xCCC);
    // Y wrap: sprite at Y=254 covers line 1 at tile row 3 (all pixel 0)
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x06] = 1;
    io_ports[0x00] = 1 | 4;
    ppu_set_sprite(0x800, 1, 254, 48);
    render_line(1);
    ppu_check("s4 ywrap line1 x48", fb[224 + 48] as i64, 0x000);
    print("ppu_test: ", ppu_pass, " passed, ", ppu_fail, " failed");
}

fn run_ws(path: u8[:]) {
    ws_mode = true;
    cpu_v20 = true;
    cpu_mz = true;
    guard read_file(path, rom) else { print("cannot read ", path); exit(1); }
    print("rom loaded: ", rom.len, " bytes");
    for i in 1048576 { mem[i] = 0; }
    for i in 256 { io_ports[i] = 0; }
    bk_ram = 0xFF; bk_rom0 = 0xFF; bk_rom1 = 0xFF; bk_linear = 0;
    int_cause = 0; key_select = 0; keys_state = 0; cpu_halted = false; sys_ctrl1 = 0x02;
    ws_cycles = 0; last_line = 0; lfsr = 0; noise_acc = 0; last_tick = 0; init_cyc(); init_io_masks();
    for i in 8 { r[i] = 0; }
    for i in 4 { seg[i] = 0; }
    seg[1] = 0xFFFF; ip = 0; flags = 0;
    var screen: u8[1024] = [0; 1024];
    var last: u8[1024] = [0; 1024];
    var lastn: i64 = 0;
    var frozen: i64 = 0;
    var total: i64 = 0;
    var menu_idx: i64 = 0;
    let argv2 = args();
    var survey: bool = false;
    var page_target: i64 = 0;
    if argv2.len > 3 {
        let a3 = argv2[3];
        if a3.len > 0 && a3[a3.len - 1] == 43 { survey = true; }
        if a3 == "logic" || a3 == "logic+" { menu_idx = 1; }
        else if a3 == "arith" || a3 == "arith+" { menu_idx = 2; }
        else if a3 == "rot" || a3 == "rot+" { menu_idx = 3; }
        else if a3 == "misc" || a3 == "misc+" { menu_idx = 4; }
        else if a3 == "mul" || a3 == "mul+" { menu_idx = 5; }
        else if a3 == "div" || a3 == "div+" { menu_idx = 6; }
        else if a3 == "sdiv" || a3 == "sdiv+" { menu_idx = 7; }
        else if a3.len == 2 && a3[0] == 109 { menu_idx = (a3[1] as i64) - 48; }  // "m1".."m9": generic menu index (WSHWTest)
        else if a3.len >= 3 && a3[0] == 112 && a3[1] == 103 { page_target = (a3[2] as i64) - 48; if a3.len >= 4 { page_target = page_target * 10 + ((a3[3] as i64) - 48); } }  // "pgN": WSTimingTest page index
    }
    var skips: i64 = 0;
    var skip_hold: i64 = 0;
    var frame: i64 = 0;
    var done: bool = false;
    var prev_keys: i64 = 0;
    var dismiss: i64 = 0;
    var page_done: i64 = 0;
    var page_hold: i64 = 0;
    var fb_dump: bool = false;
    if argv2.len > 4 && argv2[4] == "fb" { fb_dump = true; }
    while frame < 2000000 && !done {
        keys_state = 0;
        if skip_hold > 0 { keys_state = 1 << 11; skip_hold -= 1; }
        if menu_idx > 0 {
            // tap X3 (down) menu_idx times, one tap per 4 frames, then A
            let rel: i64 = frame - 30;
            if rel >= 0 {
                let tap: i64 = rel / 4;
                if tap < menu_idx { if rel % 4 < 2 { keys_state = 1 << 6; } }
                else if rel - menu_idx * 4 < 4 { keys_state = 1 << 10; }
            }
        } else if frame >= 30 && frame < 45 { keys_state = 1 << 10; }  // hold A to pick "Test All"
        if dismiss > 0 { keys_state |= 1 << 10; dismiss -= 1; }  // auto-tap A to dismiss "press any key" HLT waits
        if page_hold > 0 { keys_state |= 1 << 5; page_hold -= 1; }  // WSTimingTest: X2 (right) advances the page
        if keys_state != 0 && prev_keys == 0 { int_cause |= 0x02 & (io_ports[0xB2] as i64); }  // KEY_PRESS cause latches on the press edge, only when enabled
        prev_keys = keys_state;
        var spent: i64 = 0;
        while spent < 40704 {
            ws_deliver_int();
            if (flags & 0x0100) != 0 && dbg_op != 0x9D && dbg_op != 0xCF { do_int(1); ws_cycles += 33; spent += 33; }  // TF single-step trap (entry charge fitted from WSTimingTest's trap case)
            if !cpu_halted {
                let pre_cx: i64 = r[1] as i64;
                fault_chg = 0; cyc_in_exec = true;
                let okc: bool = exec_one(); cyc_in_exec = false;
                if !okc { print("unsupported opcode ", dbg_op, " at cs:ip ", seg[1], ":", dbg_ip, " frame ", frame); let m = ws_screen_text(screen); write_stdout(screen[..m]); exit(1); }
                total += 1;
                let c: i64 = est_cycles(pre_cx);
                ws_cycles += c; spent += c;
            } else { ws_cycles += 32; spent += 32; }
            ws_line_events();
        }
        let n = ws_screen_text(screen);
        var same: bool = n == lastn;
        if same { for i in n { if screen[i] != last[i] { same = false; } } }
        if same { frozen += 1; } else { frozen = 0; for i in n { last[i] = screen[i]; } lastn = n; }
        if frozen == 200 && cpu_halted { dismiss = 6; }
        if page_target > 0 && frame > 60 && frozen == 90 && page_done < page_target { page_done += 1; page_hold = 4; frozen = 0; for i in n { last[i] = 0; } lastn = 0; }
        if survey && frozen >= 90 && skips < 40 { skips += 1; print("survey skip ", skips, " at frame ", frame, " after ", total, " instructions; screen was:"); write_stdout(screen[..n]); skip_hold = 6; frozen = 0; for i in n { last[i] = 0; } lastn = 0; }
        else if frozen >= 600 { print("screen frozen for 600 frames at frame ", frame, " after ", total, " instructions (waiting for a key: end of Test All or a failure stop)"); done = true; }
        else if frame % 2000 == 0 { print("frame ", frame, " oks=", count_ok(screen, n)); write_stdout(screen[..n]); }
        frame += 1;
    }
    print("final screen (frame ", frame, ", ", total, " instructions):");
    print("state: cs:ip=", seg[1], ":", ip, " ax=", r[0], " bx=", r[2], " cx=", r[1], " dx=", r[3], " sp=", r[4], " bp=", r[5], " si=", r[6], " di=", r[7], " flags=", flags, " halted=", cpu_halted, " line=", (ws_cycles % 40704) / 256, " cause=", int_cause, " enable=", io_ports[0xB2], " scr_area=", io_ports[0x07], " p60=", io_ports[0x60], " p01raw=", io_ports[0x01], " p01rd=", port_rd(1));
    let m = ws_screen_text(screen);
    write_stdout(screen[..m]);
    if fb_dump { print("fbhash=", fb_hash()); fb_write_ppm(); print("framebuffer written to framebuffer.ppm"); }
}

var apu_pass: i64 = 0;
var apu_fail: i64 = 0;

fn apu_check(name: u8[:], got: i64, exp: i64) {
    if got == exp { apu_pass += 1; } else { apu_fail += 1; print("APU FAIL ", name, ": got ", got, ", expected ", exp); }
}

fn apu_reset_state() {
    for i in 1048576 { mem[i] = 0; }
    for i in 256 { io_ports[i] = 0; }
    for ch in 4 { ch_period[ch] = 0; ch_idx[ch] = 0; ch_sample[ch] = 0; }
    sweep_ctr = 0; sweep_step = 0; fast_primed = false;
    lfsr = 0; noise_acc = 0; int_cause = 0; ws_cycles = 0;
    init_io_masks();
}

fn apu_test() {
    // Channel advance, period 1 pitch (0x7FF): one sample per tick
    apu_reset_state();
    mem[0] = 0x10; mem[1] = 0x32; mem[2] = 0x54;
    io_ports[0x80] = 0xFF; io_ports[0x81] = 0x07;
    io_ports[0x90] = 0x01;
    apu_tick(3);
    apu_check("chan idx after 3 ticks", ch_idx[0], 3);
    apu_check("chan sample after 3 ticks", ch_sample[0], 3);
    apu_tick(1);
    apu_check("chan sample after 4 ticks", ch_sample[0], 4);
    // Period 2048 pitch (0): first tick advances once, then it waits
    io_ports[0x80] = 0x00; io_ports[0x81] = 0x00;
    apu_tick(100);
    apu_check("chan idx period2048", ch_idx[0], 5);
    apu_check("chan counter period2048", ch_period[0], 1949);
    apu_tick(1949);
    apu_check("chan idx after wait", ch_idx[0], 6);
    // Mixer readback: constant sample 3, volume FF -> L/R 45, LR 90
    apu_reset_state();
    for i in 16 { mem[i] = 0x33; }
    io_ports[0x80] = 0xFF; io_ports[0x81] = 0x07;
    io_ports[0x88] = 0xFF;
    io_ports[0x90] = 0x01;
    apu_tick(1);
    apu_check("mixer R lo", apu_out_port(0x96), 45);
    apu_check("mixer L lo", apu_out_port(0x98), 45);
    apu_check("mixer LR lo", apu_out_port(0x9A), 90);
    // Voice: raw data byte added to both sides when voice mode is on
    io_ports[0x90] = 0x20;
    io_ports[0x89] = 200;
    apu_check("voice L lo", apu_out_port(0x98), 200);
    // Sweep: time 1 -> steps land every 2 sweep ticks (8193 cycles each)
    apu_reset_state();
    io_ports[0x90] = 0x40 | 0x04;
    io_ports[0x8C] = 5;
    io_ports[0x8D] = 1;
    io_ports[0x84] = 0x00; io_ports[0x85] = 0x01;
    apu_tick(8193);
    apu_check("sweep step1 pitch", apu_pitch(2), 0x105);
    apu_tick(8193);
    apu_check("sweep step held", apu_pitch(2), 0x105);
    apu_tick(8193);
    apu_check("sweep step2 pitch", apu_pitch(2), 0x10A);
    sweep_step = 0; sweep_ctr = 0;
    io_ports[0x84] = 0xFF; io_ports[0x85] = 0x07;
    apu_tick(8193);
    apu_check("sweep wrap to 0", apu_pitch(2), 0);
    io_ports[0x90] = 0x04;
    io_ports[0x84] = 0x00; io_ports[0x85] = 0x01;
    apu_tick(8193);
    apu_check("sweep disabled holds", apu_pitch(2), 0x100);
    // GDMA forward copy + completion cause
    apu_reset_state();
    mem[0x2000] = 1; mem[0x2001] = 2; mem[0x2002] = 3; mem[0x2003] = 4;
    io_ports[0x40] = 0x00; io_ports[0x41] = 0x20; io_ports[0x42] = 0;
    io_ports[0x44] = 0x00; io_ports[0x45] = 0x30;
    io_ports[0x46] = 4; io_ports[0x47] = 0;
    io_ports[0xB2] = 0x08;
    port_wr(0x48, 0x80);
    apu_check("gdma byte0", mem[0x3000] as i64, 1);
    apu_check("gdma byte3", mem[0x3003] as i64, 4);
    apu_check("gdma len drained", io_ports[0x46] as i64, 0);
    apu_check("gdma enable cleared", (io_ports[0x48] as i64) & 0x80, 0);
    apu_check("gdma cause latched", int_cause & 0x08, 0x08);
    // GDMA decrement copy
    io_ports[0x40] = 0x03; io_ports[0x41] = 0x20;
    io_ports[0x44] = 0x13; io_ports[0x45] = 0x30;
    io_ports[0x46] = 4;
    port_wr(0x48, 0xC0);
    apu_check("gdma dec byte0", mem[0x3010] as i64, 1);
    apu_check("gdma dec byte3", mem[0x3013] as i64, 4);
    // GDMA from SRAM aborts without moving anything
    mem[0x3020] = 0xEE;
    io_ports[0x40] = 0x00; io_ports[0x41] = 0x00; io_ports[0x42] = 1;
    io_ports[0x44] = 0x20; io_ports[0x45] = 0x30;
    io_ports[0x46] = 4;
    port_wr(0x48, 0x80);
    apu_check("gdma sram abort dst", mem[0x3020] as i64, 0xEE);
    apu_check("gdma sram abort len", io_ports[0x46] as i64, 4);
    // Fast sweep CPU-cycle replica (WSHWTest "With Sweep Test Bit
    // On"): emulate the runner's per-instruction cycle charges with
    // the real opcodes so the port pre-charge hooks engage.
    apu_reset_state();
    init_cyc();
    ws_mode = true;
    io_ports[0x90] = 0x40 | 0x04;
    dbg_op = 0xEE; port_wr(0x8C, 1); apu_tick(est_cycles(r[1] as i64));
    dbg_op = 0xE6; port_wr(0x95, 2); apu_tick(est_cycles(r[1] as i64));
    apu_tick(1);
    dbg_op = 0xE7; port_wr(0x84, 0); port_wr(0x85, 0); apu_tick(est_cycles(r[1] as i64));
    apu_tick(10);
    dbg_op = 0xE5;
    apu_check("fast sweep meas1", port_rd(0x84) | (port_rd(0x85) << 8), 16);
    apu_tick(est_cycles(r[1] as i64));
    dbg_op = 0xE7; port_wr(0x84, 0); port_wr(0x85, 0); apu_tick(est_cycles(r[1] as i64));
    for i in 26 { apu_tick(10); }
    dbg_op = 0xE5;
    apu_check("fast sweep meas2", port_rd(0x84) | (port_rd(0x85) << 8), 266);
    ws_mode = false;
    print("apu_test: ", apu_pass, " passed, ", apu_fail, " failed");
}

fn main() {
    let argv = args();
    if argv.len < 2 { print("usage: sst [v20] <case-file.json> [more files...] | sst ws <rom.ws|wsc>"); exit(1); }
    if argv[1] == "ws" { run_ws(argv[2]); return; }
    if argv[1] == "ppu_test" { ppu_test(); return; }
    if argv[1] == "apu_test" { apu_test(); return; }
    var start: i64 = 1;
    if argv[1] == "v20" { cpu_v20 = true; start = 2; }
    for i in start..argv.len { run_file(argv[i]); }
}
