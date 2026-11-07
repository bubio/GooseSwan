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
    if aud_enabled {
        aud_acc += dc;
        while aud_acc >= 128 { aud_acc -= 128; audio_emit(); }
    }
}

// ---- Audio sample stream (M5): one stereo sample per 128 CPU
// cycles (24 kHz), following Swanium's apu output model. mix_waves
// sums sample x volume nibbles per side and scales by 32; the voice
// channel contributes its low-passed level routed by port 0x94 and
// scaled by 64; HyperVoice sums into the same domain; port 0x91
// then selects stereo (bit 7) or the mono speaker sum with its
// volume shift. Emission is gated by aud_enabled so the headless
// test runners pay nothing; the frontend will drain aud_buf.
var aud_enabled: bool = false;
var aud_acc: i64 = 0;
var aud_buf: i64[>..] = [];
var voice_lp_prev: i64 = 0;
var voice_level: i64 = 0;

fn voice_feed(v: i64) {
    if ((io_ports[0x90] as i64) & 0x20) != 0 {
        let x: i64 = v - 0x80;
        voice_level = (x + voice_lp_prev) / 2;
        voice_lp_prev = x;
    }
}

fn clamp16(v: i64) -> i64 { if v > 32767 { return 32767; } if v < -32768 { return -32768; } return v; }

fn audio_emit() {
    let ctrl: i64 = io_ports[0x90] as i64;
    var wl: i64 = 0; var wr: i64 = 0;
    for ch in 4 {
        if (ctrl & (1 << ch)) == 0 { continue; }
        if ch == 1 && (ctrl & 0x20) != 0 { continue; }
        var s: i64 = ch_sample[ch];
        if ch == 3 && (ctrl & 0x80) != 0 && ((io_ports[0x8E] as i64) & 0x10) != 0 && (ctrl & 0x88) == 0x88 { if (lfsr & 1) != 0 { s = 15; } else { s = 0; } }
        let vol: i64 = io_ports[0x88 + ch] as i64;
        wl += s * (vol >> 4); wr += s * (vol & 0x0F);
    }
    wl *= 32; wr *= 32;
    var vl: i64 = 0; var vr: i64 = 0;
    if (ctrl & 0x20) != 0 {
        let vv: i64 = io_ports[0x94] as i64;
        if (vv & 0x04) != 0 { vl = voice_level; } else if (vv & 0x08) != 0 { vl = voice_level >> 1; }
        if (vv & 0x01) != 0 { vr = voice_level; } else if (vv & 0x02) != 0 { vr = voice_level >> 1; }
        vl *= 64; vr *= 64;
    } else { voice_lp_prev = 0; voice_level = 0; }
    let hl, hr = hv_output();
    var l: i64 = wl + vl + hl; var r: i64 = wr + vr + hr;
    let oc: i64 = io_ports[0x91] as i64;
    if (oc & 0x80) != 0 { l = clamp16(l); r = clamp16(r); }
    else { let m: i64 = clamp16((l + r) >> ((oc >> 1) & 3)); l = m; r = m; }
    aud_buf.push(l); aud_buf.push(r);
}

fn wav_write() {
    var w: u8[>..] = [];
    let data_bytes: i64 = aud_buf.len * 2;
    let riff = "RIFF"; for i in riff.len { w.push(riff[i]); }
    let chunk: i64 = 36 + data_bytes;
    w.push((chunk & 0xFF) as! u8); w.push(((chunk >> 8) & 0xFF) as! u8); w.push(((chunk >> 16) & 0xFF) as! u8); w.push(((chunk >> 24) & 0xFF) as! u8);
    let wave = "WAVE"; for i in wave.len { w.push(wave[i]); }
    let fmt = "fmt "; for i in fmt.len { w.push(fmt[i]); }
    w.push(16); w.push(0); w.push(0); w.push(0);
    w.push(1); w.push(0); w.push(2); w.push(0);
    w.push(0xC0); w.push(0x5D); w.push(0); w.push(0);
    w.push(0x80); w.push(0xBB); w.push(0); w.push(0);
    w.push(4); w.push(0); w.push(16); w.push(0);
    let data = "data"; for i in data.len { w.push(data[i]); }
    w.push((data_bytes & 0xFF) as! u8); w.push(((data_bytes >> 8) & 0xFF) as! u8); w.push(((data_bytes >> 16) & 0xFF) as! u8); w.push(((data_bytes >> 24) & 0xFF) as! u8);
    for i in aud_buf.len { let v: i64 = aud_buf[i]; w.push((v & 0xFF) as! u8); w.push(((v >> 8) & 0xFF) as! u8); }
    write_file("audio.wav", w);
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

// ---- HyperVoice (colour only): the 8-bit data latch (port 0x69) or
// the signed 16-bit direct words (ports 0x64-0x67) as an extra PCM
// source, following Swanium's apu model (after Mednafen). The sample
// expansion is CPU-invisible today — the audible mix lands with the
// M5 frontend — but the maths is pinned here by Swanium's own test
// vectors in apu_test.
fn hv_sample(ctrl: i64, data: i64) -> i64 {
    let shift: i64 = ctrl & 3;
    let mode: i64 = ctrl & 0x0C;
    var expanded: i64 = 0;
    if mode == 0 { expanded = data << (8 - shift); }
    else if mode == 4 { expanded = (data - 256) << (8 - shift); }
    else if mode == 8 { expanded = s8(data) << (8 - shift); }
    else { expanded = data << 8; }
    var t: i64 = expanded;
    if t > 32767 { t -= 65536; }
    if t < -32768 { t += 65536; }
    return t >> 5;
}

fn hv_output() -> i64, i64 {
    let ctrl: i64 = io_ports[0x6A] as i64;
    if ws_mono_cart || !ppu_color_mode() || (ctrl & 0x80) == 0 { return 0, 0; }
    let dl: i64 = s16((io_ports[0x64] as i64) | ((io_ports[0x65] as i64) << 8));
    let dr: i64 = s16((io_ports[0x66] as i64) | ((io_ports[0x67] as i64) << 8));
    if dl != 0 || dr != 0 { return dl, dr; }
    let s: i64 = hv_sample(ctrl, io_ports[0x69] as i64) * 32;
    let chan: i64 = io_ports[0x6B] as i64;
    let l: i64 = if (chan & 0x40) != 0 { s } else { 0 };
    let r: i64 = if (chan & 0x20) != 0 { s } else { 0 };
    return l, r;
}

fn apu_check(name: u8[:], got: i64, exp: i64) {
    if got == exp { apu_pass += 1; } else { apu_fail += 1; print("APU FAIL ", name, ": got ", got, ", expected ", exp); }
}

fn apu_reset_state() {
    for i in 1048576 { mem[i] = 0; }
    for i in 256 { io_ports[i] = 0; }
    for ch in 4 { ch_period[ch] = 0; ch_idx[ch] = 0; ch_sample[ch] = 0; }
    sweep_ctr = 0; sweep_step = 0; fast_primed = false;
    sdma_running = false; sdma_clock = 0;
    aud_acc = 0; voice_lp_prev = 0; voice_level = 0; aud_buf = [];
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
    // Sound DMA (colour): cadence, writeback, decrement, repeat, hold
    ws_mono_cart = false;
    apu_reset_state();
    mem[0x2000] = 0x11; mem[0x2001] = 0x22; mem[0x2002] = 0x33;
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x4C, 0x00);
    port_wr(0x4E, 0x03); port_wr(0x4F, 0x00); port_wr(0x50, 0x00);
    port_wr(0x52, 0x83);
    sdma_tick(127);
    apu_check("sdma waits for period", io_ports[0x89] as i64, 0);
    sdma_tick(1);
    apu_check("sdma byte 0", io_ports[0x89] as i64, 0x11);
    apu_check("sdma source writeback", (io_ports[0x4A] as i64) | ((io_ports[0x4B] as i64) << 8), 0x2001);
    apu_check("sdma counter writeback", io_ports[0x4E] as i64, 2);
    sdma_tick(128);
    apu_check("sdma byte 1", io_ports[0x89] as i64, 0x22);
    sdma_tick(128);
    apu_check("sdma byte 2", io_ports[0x89] as i64, 0x33);
    apu_check("sdma enable self-clears", (io_ports[0x52] as i64) & 0x80, 0);
    apu_reset_state();
    mem[0x2000] = 0x77;
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x4E, 0x01); port_wr(0x52, 0x80);
    sdma_tick(767);
    apu_check("sdma rate0 waits", io_ports[0x89] as i64, 0);
    sdma_tick(1);
    apu_check("sdma rate0 byte", io_ports[0x89] as i64, 0x77);
    apu_reset_state();
    mem[0x2000] = 0x11; mem[0x2001] = 0x22; mem[0x2002] = 0x33;
    port_wr(0x4A, 0x02); port_wr(0x4B, 0x20); port_wr(0x4E, 0x02); port_wr(0x52, 0xC3);
    sdma_tick(128);
    apu_check("sdma decrement byte 0", io_ports[0x89] as i64, 0x33);
    sdma_tick(128);
    apu_check("sdma decrement byte 1", io_ports[0x89] as i64, 0x22);
    apu_check("sdma decrement source", (io_ports[0x4A] as i64) | ((io_ports[0x4B] as i64) << 8), 0x2000);
    apu_reset_state();
    mem[0x2000] = 0x11; mem[0x2001] = 0x22;
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x4E, 0x02); port_wr(0x52, 0x8B);
    sdma_tick(128); sdma_tick(128);
    apu_check("sdma repeat counter restored", io_ports[0x4E] as i64, 2);
    apu_check("sdma repeat stays enabled", (io_ports[0x52] as i64) & 0x80, 0x80);
    sdma_tick(128);
    apu_check("sdma repeat first byte again", io_ports[0x89] as i64, 0x11);
    apu_reset_state();
    mem[0x2000] = 0x11;
    io_ports[0x89] = 0x99;
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x4E, 0x02); port_wr(0x52, 0x87);
    sdma_tick(128);
    apu_check("sdma hold latches zero", io_ports[0x89] as i64, 0);
    apu_check("sdma hold counter stays", io_ports[0x4E] as i64, 2);
    apu_reset_state();
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x52, 0x83);
    sdma_tick(256);
    apu_check("sdma zero counter clears enable", (io_ports[0x52] as i64) & 0x80, 0);
    ws_mono_cart = true;
    apu_reset_state();
    mem[0x2000] = 0x11;
    port_wr(0x4A, 0x00); port_wr(0x4B, 0x20); port_wr(0x4E, 0x01); port_wr(0x52, 0x83);
    sdma_tick(256);
    apu_check("sdma silent on mono carts", io_ports[0x89] as i64, 0);
    ws_mono_cart = false;
    // HyperVoice port semantics and sample maths (Swanium's vectors)
    apu_reset_state();
    port_wr(0x64, 0xAA); port_wr(0x65, 0xBB);
    apu_check("hv direct stored", io_ports[0x64] as i64, 0xAA);
    port_wr(0x69, 0x55);
    apu_check("hv data stored", io_ports[0x69] as i64, 0x55);
    apu_check("hv data write clears direct", io_ports[0x64] as i64, 0);
    port_wr(0x66, 0xCC);
    apu_check("hv direct write clears data", io_ports[0x69] as i64, 0);
    apu_check("hv direct R stored", io_ports[0x66] as i64, 0xCC);
    apu_check("hv sample unsigned", hv_sample(0x00, 0x40), 512);
    apu_check("hv sample signed", hv_sample(0x08, 0x80), -1024);
    apu_check("hv sample shift", hv_sample(0x01, 0x40), 256);
    apu_check("hv sample negated wraps", hv_sample(0x04, 0x40), 512);
    apu_reset_state();
    io_ports[0x60] = 0x80;
    io_ports[0x6A] = 0x80; io_ports[0x69] = 0x40; io_ports[0x6B] = 0x40;
    let hl, hr = hv_output();
    apu_check("hv out left only", hl, 16384);
    apu_check("hv out right silent", hr, 0);
    io_ports[0x64] = 0x34; io_ports[0x65] = 0x12; io_ports[0x66] = 0xCC; io_ports[0x67] = 0xED;
    let dl, dr = hv_output();
    apu_check("hv direct out L", dl, 0x1234);
    apu_check("hv direct out R", dr, -0x1234);
    io_ports[0x6A] = 0x00;
    let zl, zr = hv_output();
    apu_check("hv disabled silent", zl + zr, 0);
    io_ports[0x6A] = 0xF0; io_ports[0x64] = 0; io_ports[0x65] = 0; io_ports[0x66] = 0; io_ports[0x67] = 0; io_ports[0x6B] = 0x60;
    let sl, sr = hv_output();
    apu_check("hv speed bits ignored L", sl, 16384);
    apu_check("hv speed bits ignored R", sr, 16384);
    // Audio sample stream: wave mix, output control, cadence (24 kHz)
    apu_reset_state();
    aud_enabled = true;
    for i in 16 { mem[i] = 0xFF; }
    io_ports[0x80] = 0xFF; io_ports[0x81] = 0x07;
    io_ports[0x88] = 0xFF;
    io_ports[0x90] = 0x01;
    io_ports[0x91] = 0x80;
    apu_tick(128);
    apu_check("aud one sample per 128 cycles", aud_buf.len, 2);
    apu_check("aud wave L", aud_buf[0], 7200);
    apu_check("aud wave R", aud_buf[1], 7200);
    io_ports[0x91] = 0x00;
    apu_tick(128);
    apu_check("aud speaker sums", aud_buf[2], 14400);
    io_ports[0x91] = 0x02;
    apu_tick(128);
    apu_check("aud speaker shift", aud_buf[4], 7200);
    apu_tick(5);
    apu_check("aud cadence holds remainder", aud_buf.len, 6);
    apu_tick(123);
    apu_check("aud cadence completes sample", aud_buf.len, 8);
    aud_enabled = false;
    // Voice channel: write-fed low-pass, port 0x94 routing, x64 scale
    apu_reset_state();
    aud_enabled = true;
    io_ports[0x90] = 0x20;
    port_wr(0x89, 0xFF);
    apu_check("voice lp first average", voice_level, 63);
    port_wr(0x89, 0xFF);
    apu_check("voice lp settles", voice_level, 127);
    io_ports[0x94] = 0x05;
    io_ports[0x91] = 0x80;
    apu_tick(128);
    apu_check("aud voice L", aud_buf[0], 8128);
    apu_check("aud voice R", aud_buf[1], 8128);
    aud_enabled = false;
    // HyperVoice in the stream, and the mono clamp
    apu_reset_state();
    aud_enabled = true;
    io_ports[0x60] = 0x80;
    io_ports[0x6A] = 0x80; io_ports[0x69] = 0x40; io_ports[0x6B] = 0x40;
    io_ports[0x91] = 0x80;
    apu_tick(128);
    apu_check("aud hv L", aud_buf[0], 16384);
    apu_check("aud hv R silent", aud_buf[1], 0);
    io_ports[0x64] = 0xFF; io_ports[0x65] = 0x7F; io_ports[0x66] = 0xFF; io_ports[0x67] = 0x7F;
    io_ports[0x91] = 0x00;
    apu_tick(128);
    apu_check("aud mono clamps L", aud_buf[2], 32767);
    apu_check("aud mono clamps R", aud_buf[3], 32767);
    aud_enabled = false;
    print("apu_test: ", apu_pass, " passed, ", apu_fail, " failed");
}
