// sst apu_test: white-box APU / DMA self-test.
namespace core;

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
