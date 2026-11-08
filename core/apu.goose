// Gooswan APU: noise LFSR, wave channels, sweep, voice / HyperVoice,
// mixer readback ports and the 24 kHz stereo sample stream.
namespace core;

var lfsr:      i64 = 0;     // APU noise LFSR (15-bit, XNOR feedback), read back through ports 92/93
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
    // The LFSR steps with channel 4's period counter whenever the counter
    // runs (0x90 bit 3), in wavetable mode too; noise mode (bit 7) only picks
    // the audible output (WSdev wiki, Mesen). Clock Tower relies on this: its
    // QUICK START shuffle polls port 92 with CH4 in wave mode and never ends
    // otherwise. ws-test-suite sound/quirks row 5 offset 2 disagrees.
    if ((io_ports[0x90] as i64) & 0x08) == 0 { return; }        // CH4_ENABLE
    let pitch:  i64 = io_ports[0x86] | (((io_ports[0x87] as i64) & 7) << 8);
    let period: i64 = 2048 - pitch;
    noise_acc += dc;
    while noise_acc >= period { noise_acc -= period; step_lfsr(); }
}

var ch_period:   i64[4] = [0; 4];
var ch_idx:      i64[4] = [0; 4];
var ch_sample:   i64[4] = [0; 4];
var sweep_ctr:   i64    = 0;
var sweep_step:  i64    = 0;
var fast_primed: bool   = false;

fn apu_pitch(ch: i64) -> i64 {
    return (io_ports[0x80 + ch * 2] | ((io_ports[0x81 + ch * 2] as i64) << 8)) & 0x7FF;
}

fn apu_read_wave(ch: i64) {
    let base: i64 = ((io_ports[0x8F] as i64) << 6) + ch * 16;
    let b:    i64 = mem[base + (ch_idx[ch] >> 1)];
    if (ch_idx[ch] & 1) == 0 { ch_sample[ch] = b & 0x0F; } else { ch_sample[ch] = (b >> 4) & 0x0F; }
}

fn apu_chan_advance(ch: i64, dc: i64) {
    let period: i64 = 2048 - apu_pitch(ch);
    var rem:   i64 = dc;
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
    var delta: i64 = io_ports[0x8C]; if delta >= 128 { delta -= 256; }
    var np:    i64 = apu_pitch(2) + delta;
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
    let ctrl: i64 = io_ports[0x90];
    if (ctrl & 0x40) == 0 || (ctrl & 0x04) == 0 { fast_primed = false; return; }
    if ((io_ports[0x95] as i64) & 0x02) != 0 {
        var ticks: i64 = dc;
        if !fast_primed { fast_primed = true; ticks -= 1; }
        var i: i64 = 0;
        while i < ticks { apu_sweep_tick(); i += 1; }
    } else {
        sweep_ctr += dc;
        while sweep_ctr >= 8193 { sweep_ctr -= 8193; apu_sweep_tick(); }  // one sweep tick per 8193 CPU cycles (WSHWTest sound sweep)
    }
}

fn apu_tick(dc: i64) {
    if dc <= 0 { return; }
    let ctrl: i64 = io_ports[0x90];
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
// test runners pay nothing; the frontend drains aud_buf every frame.
var aud_enabled:   bool     = false;
var aud_acc:       i64      = 0;
var aud_buf:       i64[>..] = [];
var voice_lp_prev: i64      = 0;
var voice_level:   i64      = 0;

fn voice_feed(v: i64) {
    if ((io_ports[0x90] as i64) & 0x20) != 0 {
        let x: i64 = v - 0x80;
        voice_level = (x + voice_lp_prev) / 2;
        voice_lp_prev = x;
    }
}

fn clamp16(v: i64) -> i64 { if v > 32767 { return 32767; } if v < -32768 { return -32768; } return v; }

// Channel ch's current 4-bit level: its wave sample, or for channel 4
// in noise mode (0x90 bit 7, with CH4 and NOISE_ENABLE on) the LFSR's
// low bit as 0 / 15.
fn apu_chan_level(ch: i64, ctrl: i64) -> i64 {
    if ch == 3 && (ctrl & 0x88) == 0x88 && ((io_ports[0x8E] as i64) & 0x10) != 0 { return if (lfsr & 1) != 0 { 15 } else { 0 }; }
    return ch_sample[ch];
}

fn audio_emit() {
    let ctrl: i64 = io_ports[0x90];
    var wl: i64 = 0; var wr: i64 = 0;
    for ch in 4 {
        if (ctrl & (1 << ch)) == 0 { continue; }
        if ch == 1 && (ctrl & 0x20) != 0 { continue; }
        let s:   i64 = apu_chan_level(ch, ctrl);
        let vol: i64 = io_ports[0x88 + ch];
        wl += s * (vol >> 4); wr += s * (vol & 0x0F);
    }
    wl *= 32; wr *= 32;
    var vl: i64 = 0; var vr: i64 = 0;
    if (ctrl & 0x20) != 0 {
        let vv: i64 = io_ports[0x94];
        if (vv & 0x04) != 0 { vl = voice_level; } else if (vv & 0x08) != 0 { vl = voice_level >> 1; }
        if (vv & 0x01) != 0 { vr = voice_level; } else if (vv & 0x02) != 0 { vr = voice_level >> 1; }
        vl *= 64; vr *= 64;
    } else { voice_lp_prev = 0; voice_level = 0; }
    let hl, hr = hv_output();
    var l: i64 = wl + vl + hl; var r: i64 = wr + vr + hr;
    let oc: i64 = io_ports[0x91];
    if (oc & 0x80) != 0 { l = clamp16(l); r = clamp16(r); }
    else { let m: i64 = clamp16((l + r) >> ((oc >> 1) & 3)); l = m; r = m; }
    aud_buf.push(l); aud_buf.push(r);
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
    let ctrl: i64 = io_ports[0x90];
    var left:  i64 = 0;
    var right: i64 = 0;
    for ch in 4 {
        if (ctrl & (1 << ch)) == 0 { continue; }
        if ch == 1 && (ctrl & 0x20) != 0 { continue; }
        let s:   i64 = apu_chan_level(ch, ctrl);
        let vol: i64 = io_ports[0x88 + ch];
        left += s * (vol >> 4);
        right += s * (vol & 0x0F);
    }
    if (ctrl & 0x20) != 0 { let vv: i64 = io_ports[0x89]; left += vv; right += vv; }
    var v: i64 = left + right;
    if (p & 0xFE) == 0x96 { v = right; }
    if (p & 0xFE) == 0x98 { v = left; }
    return (v >> ((p & 1) * 8)) & 0xFF;
}

// ---- HyperVoice (colour only): the 8-bit data latch (port 0x69) or
// the signed 16-bit direct words (ports 0x64-0x67) as an extra PCM
// source, following Swanium's apu model (after Mednafen), mixed into
// the sample stream by audio_emit. It is CPU-invisible (no readback
// port), so the maths is pinned by Swanium's own test vectors in
// apu_test.
fn hv_sample(ctrl: i64, data: i64) -> i64 {
    let shift: i64 = ctrl & 3;
    let mode:  i64 = ctrl & 0x0C;
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
    let ctrl: i64 = io_ports[0x6A];
    if model_mono || !ppu_color_mode() || (ctrl & 0x80) == 0 { return 0, 0; }
    let dl: i64 = s16(io_ports[0x64] | ((io_ports[0x65] as i64) << 8));
    let dr: i64 = s16(io_ports[0x66] | ((io_ports[0x67] as i64) << 8));
    if dl != 0 || dr != 0 { return dl, dr; }
    let s:    i64 = hv_sample(ctrl, io_ports[0x69]) * 32;
    let chan: i64 = io_ports[0x6B];
    let l:    i64 = if (chan & 0x40) != 0 { s } else { 0 };
    let r:    i64 = if (chan & 0x20) != 0 { s } else { 0 };
    return l, r;
}
