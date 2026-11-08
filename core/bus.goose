// GooseSwan bus/system: WonderSwan memory map, I/O ports, timers,
// interrupt latching and delivery, GDMA / sound DMA, the serial
// TX-ready level, and machine boot + one frame (ws_boot/ws_frame).
namespace core;

// ---- WonderSwan machine mode (selected by the "ws" CLI argument) ----
// The SST harness keeps using the flat 1 MB array; in WS mode the physical
// address goes through the WonderSwan memory map instead: 64 KB internal
// RAM, a cartridge SRAM window, two banked ROM windows and the linear ROM
// window, all with (bank << 16 | offset) % rom_size addressing, matching
// Swanium's bus. Internal RAM stays in mem[0..0x10000) so the screen map
// and variables can be read back directly by the runner.
var cpu_halted: bool = false;

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
var last_tick: i64 = 0;     // ws_cycles value at the previous ws_line_events call
var key_select: i64 = 0;
var keys_state: i64 = 0;   // Y1-4 bits 0-3, X1-4 bits 4-7, Start bit 9, A bit 10, B bit 11
var ws_cycles: i64 = 0;     // total CPU cycles since reset (WS mode): drives the scanline model
var last_line: i64 = 0;     // scanline the model has advanced to (0..158)
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
    if ws_mode && sweep_prepaid == 0 && (dbg_op == 0xE4 || dbg_op == 0xE5 || dbg_op == 0xEC || dbg_op == 0xED) { var pre: i64 = 2; if dbg_op == 0xE4 { pre = 4; } else if dbg_op == 0xE5 { pre = 5; } sweep_advance(pre); sweep_prepaid += pre; }  // IN: sweep runs until the sample point (once per instruction)
    if p == 0x02 { return (ws_cycles % 40704) / 256; }  // LCD_LINE: current scanline (159 lines x 256 cycles)
    if p == 0xA0 { return sys_ctrl1; }  // SYSTEM_CTRL1 (drives the SPHINX flag variants in test ROMs)
    if p == 0x91 { return (io_ports[0x91] as i64) & 0x0F; }  // SND_OUT_CTRL: only the low 4 bits exist (bit 7 is a status bit, unread here)
    if p >= 0x96 && p <= 0x9B { return apu_out_port(p); }  // SND_CH_OUT: current mixer levels
    if p == 0x92 { return lfsr & 0xFF; }  // SND_RANDOM low
    if p == 0x93 { return (lfsr >> 8) & 0xFF; }  // SND_RANDOM high
    if p == 0xB0 {  // INT_VECTOR: on mono the low 3 bits report the highest pending cause (ws-test-suite soc/interrupts); colour reads them as 0 (WSHWTest)
        var v: i64 = (io_ports[0xB0] as i64) & 0xF8;
        if model_mono { var bit: i64 = 7; while bit > 0 && ((int_cause >> bit) & 1) == 0 { bit -= 1; } v |= bit; }
        return v;
    }
    if p == 0xB1 { return 0; }  // SERIAL_DATA: receive buffer, empty
    if p == 0xB4 { refresh_serial(); return int_cause; }  // INT_CAUSE (the TX-ready level re-asserts on read)
    if p == 0xB5 {  // KEYPAD: selector echoed back, selected scan groups OR-ed into the low nibble
        var v: i64 = key_select;
        if (key_select & 0x10) != 0 { v |= keys_state & 0x0F; }
        if (key_select & 0x20) != 0 { v |= (keys_state >> 4) & 0x0F; }
        if (key_select & 0x40) != 0 { v |= (keys_state >> 8) & 0x0F; }
        return v;
    }
    if p == 0xBA { return ee_output[1] & 0xFF; }  // IEEPROM data: the READ output latch, not the input shadow
    if p == 0xBB { return (ee_output[1] >> 8) & 0xFF; }
    if p == 0xBE { return ie_status_read(); }  // IEEPROM status: ready | done | protect fault (reading polls the read delay)
    if p >= 0xC4 && p <= 0xC7 { if cart_eeprom { return io_ports[p] as i64; } return 0xFF; }  // cart EEPROM latches, else open bus
    if p == 0xC8 { if cart_eeprom { return 0x02 | ((io_ports[0xC8] as i64) & 1); } return 0xFF; }  // cart EEPROM status: ready | DONE
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
    if ws_mode && sweep_prepaid == 0 && (dbg_op == 0xE6 || dbg_op == 0xE7 || dbg_op == 0xEE || dbg_op == 0xEF) { let pre: i64 = est_cycles(r[1] as i64) - (if dbg_op == 0xE7 || dbg_op == 0xEF { 1 } else { 2 }); if pre > 0 { sweep_advance(pre); sweep_prepaid += pre; } }  // OUT: sweep runs until the write lands (once per instruction)
    if p >= 0xA8 && p <= 0xAB { return; }  // HBL/VBL timer counters are read-only
    io_ports[p] = v as! u8;
    if p == 0xA4 { io_ports[0xA8] = v as! u8; }        // writing a timer period also resets its counter (per byte)
    else if p == 0xA5 { io_ports[0xA9] = v as! u8; }
    else if p == 0xA6 { io_ports[0xAA] = v as! u8; }
    else if p == 0xA7 { io_ports[0xAB] = v as! u8; }
    if p == 0x8E && (v & 0x08) != 0 { lfsr = 0; noise_acc = 0; io_ports[0x8E] = (v & 0xF7) as! u8; }  // SND_NOISE_CTRL reset: reseed LFSR, bit self-clears
    if p == 0x8C || p == 0x8D { sweep_ctr = 0; sweep_step = 0; }  // sweep register writes reset the sweep timer
    if p == 0x89 { voice_feed(v); }  // voice data latch: feeds the reconstruction low-pass while voice mode is on
    if !model_mono && p >= 0x64 && p <= 0x67 { io_ports[0x69] = 0; }  // HyperVoice direct write clears the data latch (colour only)
    if !model_mono && p == 0x69 { io_ports[0x64] = 0; io_ports[0x65] = 0; io_ports[0x66] = 0; io_ports[0x67] = 0; }  // HyperVoice data write clears the direct words
    if p == 0xB3 { io_ports[0xB3] = (v & 0xC4) as! u8; }  // SERIAL_CTRL: only enable/speed/overrun bits exist
    if p == 0xB1 || p == 0xB2 || p == 0xB3 { refresh_serial(); }  // serial TX-ready level feeds INT_CAUSE bit 0
    if p == 0x48 && (v & 0x80) != 0 { run_gdma(); }  // GDMA trigger: synchronous burst on the enable write
    if p == 0xBE { ie_control(v); }  // IEEPROM control: execute the latched command (0xBC/0xBD)
    if p == 0xBF { io_ports[0xBF] = (v & 1) as! u8; }  // IEEPROM-adjacent control: only bit 0 exists
    if !cart_eeprom && p >= 0xC4 && p <= 0xC9 { io_ports[p] = 0; }  // no cart EEPROM: writes ignored
    if p == 0xC8 && cart_eeprom { ce_control(v); }  // cart EEPROM control: high nibble selects the operation
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

// The serial TX-ready cause is a level, not a baud timer: with the
// serial port enabled (SERIAL_CTRL bit 7) and the SERIAL_SEND
// interrupt enabled, INT_CAUSE bit 0 reads as permanently pending
// (the UART is always ready to send). It is re-evaluated on writes
// to the serial data/enable/ctrl ports and cleared only via
// INT_CAUSE_CLEAR, matching Swanium's refresh model — and it is
// exactly what WSTimingTest's HLT and IRQ loops measure: their
fn refresh_serial() {
    // The instant TX-ready latch is a mono-machine behaviour (Swanium
    // gates it the same way). On colour carts it must NOT fire:
    // WSHWTest's IO-register test pattern-writes INT_ENABLE = 0xFF
    // with the serial left enabled, and an instantly-pending
    // non-acknowledged IRQ would livelock that test on the spot.
    if model_mono && ((io_ports[0xB2] as i64) & 1) != 0 && ((io_ports[0xB3] as i64) & 0x80) != 0 { int_cause |= 0x01; }
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
    if moved > 0 { ws_cycles += 5 + moved; }
}

// ---- Sound DMA (colour only): feeds the voice data latch (port 0x89)
// from memory on the 24 kHz cadence (one sample per 128 CPU cycles x
// the rate divider), following Swanium's bus model. The register
// shadows live in ports 0x4A-0x52; source/counter latch into the
// engine (with shadows for REPEAT) when a stopped engine first ticks
// with ENABLE set, and are written back to the ports on every step.
var sdma_running: bool = false;
var sdma_clock: i64 = 0;
var sdma_source: i64 = 0;
var sdma_counter: i64 = 0;
var sdma_source_shadow: i64 = 0;
var sdma_counter_shadow: i64 = 0;

fn sdma_source_from_ports() -> i64 { (((io_ports[0x4C] as i64) & 0x0F) << 16) | (io_ports[0x4A] as i64) | ((io_ports[0x4B] as i64) << 8) }
fn sdma_counter_from_ports() -> i64 { (((io_ports[0x50] as i64) & 0x0F) << 16) | (io_ports[0x4E] as i64) | ((io_ports[0x4F] as i64) << 8) }

fn sdma_writeback() {
    io_ports[0x4A] = (sdma_source & 0xFF) as! u8; io_ports[0x4B] = ((sdma_source >> 8) & 0xFF) as! u8; io_ports[0x4C] = ((sdma_source >> 16) & 0x0F) as! u8;
    io_ports[0x4E] = (sdma_counter & 0xFF) as! u8; io_ports[0x4F] = ((sdma_counter >> 8) & 0xFF) as! u8; io_ports[0x50] = ((sdma_counter >> 16) & 0x0F) as! u8;
}

fn sdma_step() {
    let ctrl: i64 = io_ports[0x52] as i64;
    if (ctrl & 0x04) != 0 { io_ports[0x89] = 0; voice_feed(0); return; }  // HOLD: latch silence, pointers stay
    let sb: i64 = rd8(sdma_source);
    io_ports[0x89] = sb as! u8; voice_feed(sb);
    if (ctrl & 0x40) != 0 { sdma_source = (sdma_source - 1) & 0xFFFFF; } else { sdma_source = (sdma_source + 1) & 0xFFFFF; }
    sdma_counter = (sdma_counter - 1) & 0xFFFFF;
    if sdma_counter == 0 {
        if (ctrl & 0x08) != 0 { sdma_source = sdma_source_shadow; sdma_counter = sdma_counter_shadow; }
        else { io_ports[0x52] = ((io_ports[0x52] as i64) & 0x7F) as! u8; sdma_running = false; }
    }
    sdma_writeback();
}

fn sdma_tick(dc: i64) {
    if model_mono || ((io_ports[0x52] as i64) & 0x80) == 0 { sdma_running = false; sdma_clock = 0; return; }
    if !sdma_running {
        let counter: i64 = sdma_counter_from_ports();
        if counter == 0 { io_ports[0x52] = ((io_ports[0x52] as i64) & 0x7F) as! u8; return; }  // nothing to send: ENABLE self-clears
        sdma_source = sdma_source_from_ports();
        sdma_counter = counter;
        sdma_source_shadow = sdma_source;
        sdma_counter_shadow = sdma_counter;
        sdma_clock = 0;
        sdma_running = true;
    }
    sdma_clock += dc;
    let rate_bits: i64 = (io_ports[0x52] as i64) & 3;
    let rate: i64 = if rate_bits == 0 { 6 } else if rate_bits == 1 { 4 } else if rate_bits == 2 { 2 } else { 1 };
    let period: i64 = 128 * rate;
    while sdma_clock >= period {
        sdma_clock -= period;
        sdma_step();
        if !sdma_running { sdma_clock = 0; break; }
    }
}


fn ws_line_events() {
    let apu_dc: i64 = ws_cycles - last_tick;
    noise_tick(apu_dc);
    apu_tick(apu_dc);
    sdma_tick(apu_dc);
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
// Deliver the highest-priority pending hardware interrupt, if any is
// enabled and IF is set. Cause bits stay set until software clears them
// through port B6, as on hardware.
fn ws_deliver_int() -> bool {
    let pending: i64 = int_cause & (io_ports[0xB2] as i64);
    if pending == 0 { return false; }
    cpu_halted = false;  // a pending enabled interrupt wakes HLT even with IF=0 (it just isn't serviced then; WSTimingTest's HLT case relies on this)
    if (flags & 0x0200) == 0 { return false; }
    var bit: i64 = 7;
    while bit > 0 && ((pending >> bit) & 1) == 0 { bit -= 1; }
    let ret: i64 = if irq_ret_override >= 0 { irq_ret_override } else { ip as i64 };
    irq_ret_override = -1;
    do_int_at(((io_ports[0xB0] as i64) & 0xF8) + bit, ret);
    return true;
}

// ---- Machine boot + one frame, shared by the headless runner and
// the frontend. ws_boot expects the ROM in `rom` and a fresh
// process state; ws_frame runs exactly one 40,704-cycle frame with
// the current keys_state, delivering interrupts and the TF trap
// between instructions exactly as the runner always has.
var ws_prev_keys: i64 = 0;
var ws_total: i64 = 0;
var ws_unsupported: bool = false;

fn ws_boot() {
    ws_mode = true;
    cpu_v20 = true;
    cpu_mz = true;
    if rom.len > 16 { model_mono = (rom[rom.len - 9] as i64) == 0; }
    if model_forced >= 0 { model_mono = model_forced == 0; }
    if rom.len > 16 { ee_init_cart(rom[rom.len - 5] as i64); }
    for i in 1048576 { mem[i] = 0; }
    for i in 256 { io_ports[i] = 0; }
    bk_ram = 0xFF; bk_rom0 = 0xFF; bk_rom1 = 0xFF; bk_linear = 0;
    int_cause = 0; key_select = 0; keys_state = 0; cpu_halted = false; sys_ctrl1 = 0x02;
    irq_inhibit = 0; trap_inhibit = 0; irq_ret_override = -1;
    ws_cycles = 0; last_line = 0; lfsr = 0; noise_acc = 0; last_tick = 0; init_cyc(); init_io_masks();
    for i in 8 { r[i] = 0; }
    for i in 4 { seg[i] = 0; }
    seg[1] = 0xFFFF; ip = 0; flags = 0;
    ws_prev_keys = 0; ws_total = 0; ws_unsupported = false;
    sweep_prepaid = 0; sdma_running = false; sdma_clock = 0;
    aud_acc = 0; aud_buf = [];
}

fn ws_frame() {
    if keys_state != 0 && ws_prev_keys == 0 { int_cause |= 0x02 & (io_ports[0xB2] as i64); }  // KEY_PRESS cause latches on the press edge, only when enabled
    ws_prev_keys = keys_state;
    var spent: i64 = 0;
    while spent < 40704 {
        // Swanium's order: IRQ acceptance (unless held off by the previous
        // instruction), one instruction, then the TF trap for it.
        let inhibited: bool = irq_inhibit > 0;
        if inhibited { irq_inhibit -= 1; }
        if inhibited { if (int_cause & (io_ports[0xB2] as i64)) != 0 { cpu_halted = false; } }
        else if ws_deliver_int() { ws_cycles += 40; spent += 40; }  // hardware IRQ entry = 40 (fault entry is 44; the 4-cycle difference is what ExIrq measures)
        if !cpu_halted {
            let pre_cx: i64 = r[1] as i64;
            fault_chg = 0; cyc_in_exec = true; irq_ret_override = -1;
            let okc: bool = exec_one(); cyc_in_exec = false;
            if !okc { ws_unsupported = true; return; }
            ws_total += 1;
            let c: i64 = est_cycles(pre_cx);
            ws_cycles += c; spent += c;
            if c >= 256 && rep_prefix != 0 && ((dbg_op >= 0xA4 && dbg_op <= 0xAF) || (dbg_op >= 0x6C && dbg_op <= 0x6F)) { irq_ret_override = dbg_ip; }
            if trap_inhibit > 0 { trap_inhibit -= 1; }
            else if (flags & 0x0100) != 0 { do_int(1); ws_cycles += 33; spent += 33; }  // TF single-step trap (entry charge fitted from WSTimingTest's trap case)
        } else { ws_cycles += 32; spent += 32; }
        ws_line_events();
    }
}


// Hardware model: the monochrome WonderSwan (model_mono) or a Color-class
// machine. ws_boot picks it from the cartridge footer's colour flag, as
// Swanium's HardwareModel::from_color_flag does; model_forced (set via
// core::set_model before power_on) overrides that choice.
var model_mono: bool = false;
var model_forced: i64 = -1;  // -1 = from the footer, 0 = mono, 1 = colour
