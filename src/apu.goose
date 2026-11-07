// GooseSwan APU: noise LFSR, wave channels, sweep, mixer readback
// ports, plus the apu_test self-test.

var lfsr: i64 = 0;          // APU noise LFSR (15-bit, XNOR feedback), read back through ports 92/93
var noise_acc: i64 = 0;     // cycles accumulated towards the next LFSR step
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

// The serial TX-ready cause is a level, not a baud timer: with the
// serial port enabled (SERIAL_CTRL bit 7) and the SERIAL_SEND
// interrupt enabled, INT_CAUSE bit 0 reads as permanently pending
// (the UART is always ready to send). It is re-evaluated on writes
// to the serial data/enable/ctrl ports and cleared only via
// INT_CAUSE_CLEAR, matching Swanium's refresh model — and it is
// exactly what WSTimingTest's HLT and IRQ loops measure: their
// handler never acknowledges, so the cause must simply stay up.
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
    apu_check("gdma raises no cause", int_cause & 0x08, 0);
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
    // Serial TX-ready level: latches when serial + its IRQ are on (mono carts)
    ws_mono_cart = true;
    apu_reset_state();
    port_wr(0xB3, 0xC0);
    apu_check("serial no latch before enable", int_cause & 1, 0);
    port_wr(0xB2, 0x01);
    apu_check("serial latched by int enable", int_cause & 1, 1);
    port_wr(0xB6, 0xFF);
    apu_check("serial ack clears", int_cause & 1, 0);
    apu_reset_state();
    port_wr(0xB2, 0x01);
    apu_check("serial no latch before ctrl", int_cause & 1, 0);
    port_wr(0xB3, 0xC0);
    apu_check("serial latched by ctrl enable", int_cause & 1, 1);
    apu_check("serial ctrl mask", io_ports[0xB3] as i64, 0xC0);
    ws_mono_cart = false;
    apu_reset_state();
    port_wr(0xB3, 0xC0);
    port_wr(0xB2, 0x01);
    apu_check("serial no latch on colour carts", int_cause & 1, 0);
    print("apu_test: ", apu_pass, " passed, ", apu_fail, " failed");
}
