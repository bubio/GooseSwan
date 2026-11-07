// GooseSwan bus/system: WonderSwan memory map, I/O ports, timers,
// interrupt latching and delivery, GDMA, serial TX-ready level,
// and the headless ROM runner.

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
    if ws_mode && sweep_prepaid == 0 && (dbg_op == 0xE6 || dbg_op == 0xE7 || dbg_op == 0xEE || dbg_op == 0xEF) { let pre: i64 = est_cycles(r[1] as i64) - 2; if pre > 0 { sweep_advance(pre); sweep_prepaid += pre; } }  // OUT: sweep runs until the write lands (once per instruction)
    if p >= 0xA8 && p <= 0xAB { return; }  // HBL/VBL timer counters are read-only
    io_ports[p] = v as! u8;
    if p == 0xA4 { io_ports[0xA8] = v as! u8; }        // writing a timer period also resets its counter (per byte)
    else if p == 0xA5 { io_ports[0xA9] = v as! u8; }
    else if p == 0xA6 { io_ports[0xAA] = v as! u8; }
    else if p == 0xA7 { io_ports[0xAB] = v as! u8; }
    if p == 0x8E && (v & 0x08) != 0 { lfsr = 0; noise_acc = 0; io_ports[0x8E] = (v & 0xF7) as! u8; }  // SND_NOISE_CTRL reset: reseed LFSR, bit self-clears
    if p == 0x8C || p == 0x8D { sweep_ctr = 0; sweep_step = 0; }  // sweep register writes reset the sweep timer
    if p == 0x89 { voice_feed(v); }  // voice data latch: feeds the reconstruction low-pass while voice mode is on
    if !ws_mono_cart && p >= 0x64 && p <= 0x67 { io_ports[0x69] = 0; }  // HyperVoice direct write clears the data latch (colour only)
    if !ws_mono_cart && p == 0x69 { io_ports[0x64] = 0; io_ports[0x65] = 0; io_ports[0x66] = 0; io_ports[0x67] = 0; }  // HyperVoice data write clears the direct words
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
fn refresh_serial() {
    // The instant TX-ready latch is a mono-machine behaviour (Swanium
    // gates it the same way). On colour carts it must NOT fire:
    // WSHWTest's IO-register test pattern-writes INT_ENABLE = 0xFF
    // with the serial left enabled, and an instantly-pending
    // non-acknowledged IRQ would livelock that test on the spot.
    if ws_mono_cart && ((io_ports[0xB2] as i64) & 1) != 0 && ((io_ports[0xB3] as i64) & 0x80) != 0 { int_cause |= 0x01; }
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
    if ws_mono_cart || ((io_ports[0x52] as i64) & 0x80) == 0 { sdma_running = false; sdma_clock = 0; return; }
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

// ---- Serial EEPROMs (93Cxx / Microwire), following Swanium's cart
// device: device 0 = cartridge EEPROM (ports 0xC4-0xC8, present only
// when the ROM footer's save type says so, 0xFF-filled and write-
// locked at power-on), device 1 = the console's internal EEPROM
// (ports 0xBA-0xBE, 2048 bytes, zero-filled, writes enabled, with a
// protected system range from byte 0x60). One backing store: the
// cartridge device at offset 0, the internal at offset 2048.
// A command word is: start bit at bits+2, 2-bit opcode at bits,
// word address in the low bits; opcode 0 is the extended group
// (EWDS / WRAL / ERAL / EWEN in the 2 bits below the opcode field).
var ee_data: u8[4096];
var ee_input: i64[2];
var ee_output: i64[2];
var ee_wen: bool[2];
var ee_size: i64[2];
var ee_bits: i64[2];
var cart_eeprom: bool = false;
var ie_done: bool = false;
var ie_delay: i64 = 0;
var ie_fault: bool = false;

fn ee_execute(dev: i64, comm: i64, bits: i64) {
    if (comm >> (bits + 3)) != 0 { return; }
    if ((comm >> (bits + 2)) & 1) == 0 { return; }
    let opcode: i64 = (comm >> bits) & 3;
    let base: i64 = dev * 2048;
    if opcode == 0 {
        let sub: i64 = (comm >> (bits - 2)) & 3;
        if sub == 0 { ee_wen[dev] = false; }
        else if sub == 3 { ee_wen[dev] = true; }
        else if sub == 1 && ee_wen[dev] {
            let lo: i64 = ee_input[dev] & 0xFF; let hi: i64 = (ee_input[dev] >> 8) & 0xFF;
            for i in ee_size[dev] { if i % 2 == 0 { ee_data[base + i] = lo as! u8; } else { ee_data[base + i] = hi as! u8; } }
        }
        else if sub == 2 && ee_wen[dev] { for i in ee_size[dev] { ee_data[base + i] = 0xFF; } }
        return;
    }
    let baddr: i64 = (comm & ((1 << bits) - 1)) * 2;
    if baddr + 1 >= ee_size[dev] { return; }
    if opcode == 1 && ee_wen[dev] { ee_data[base + baddr] = (ee_input[dev] & 0xFF) as! u8; ee_data[base + baddr + 1] = ((ee_input[dev] >> 8) & 0xFF) as! u8; }
    else if opcode == 2 { ee_output[dev] = (ee_data[base + baddr] as i64) | ((ee_data[base + baddr + 1] as i64) << 8); }
    else if opcode == 3 && ee_wen[dev] { ee_data[base + baddr] = 0xFF; ee_data[base + baddr + 1] = 0xFF; }
}

fn ee_init_cart(save: i64) {
    cart_eeprom = false; ee_size[0] = 0; ee_bits[0] = 0; ee_wen[0] = false; ee_input[0] = 0; ee_output[0] = 0xFFFF;
    var size: i64 = 0; var bits: i64 = 0;
    if save == 0x10 { size = 128; bits = 6; }
    else if save == 0x50 { size = 1024; bits = 9; }
    else if save == 0x20 { size = 2048; bits = 10; }
    if size > 0 { cart_eeprom = true; ee_size[0] = size; ee_bits[0] = bits; for i in size { ee_data[i] = 0xFF; } }
    ee_size[1] = 2048; ee_bits[1] = 10; ee_wen[1] = true; ee_input[1] = 0; ee_output[1] = 0xFFFF;
    for i in 2048 { ee_data[2048 + i] = 0; }
    ie_done = false; ie_delay = 0; ie_fault = false;
}

// The internal EEPROM speaks two command widths: the start bit at
// bit 12 selects the 10-bit (colour) form, otherwise the 6-bit
// mono-compatible form, over the same storage.
fn ie_bits(comm: i64) -> i64 { if (comm & 0x1000) != 0 { return 10; } return 6; }

fn ie_status_read() -> i64 {
    var v: i64 = 0x02;
    if ie_done { v |= 1; }
    if ie_fault { v |= 0x80; }
    if ie_delay > 0 { ie_delay -= 1; if ie_delay == 0 { ie_done = true; } }
    return v;
}

fn ie_control(v: i64) {
    let comm: i64 = (io_ports[0xBC] as i64) | ((io_ports[0xBD] as i64) << 8);
    if v == 0x10 { ee_execute(1, comm, ie_bits(comm)); ie_done = false; ie_delay = 1; }
    else if v == 0x20 {
        ee_input[1] = (io_ports[0xBA] as i64) | ((io_ports[0xBB] as i64) << 8);
        let baddr: i64 = (comm & ((1 << ie_bits(comm)) - 1)) * 2;
        if baddr >= 0x60 { ie_fault = true; ie_done = true; ie_delay = 0; }
        else { ee_execute(1, comm, ie_bits(comm)); ie_done = false; ie_delay = 0; }
    }
    else if v == 0x40 { ee_execute(1, comm, ie_bits(comm)); ie_done = true; ie_delay = 0; }
    else { ie_done = false; ie_delay = 0; }
}

fn ce_control(v: i64) {
    let op: i64 = v >> 4;
    let data: i64 = (io_ports[0xC4] as i64) | ((io_ports[0xC5] as i64) << 8);
    let comm: i64 = (io_ports[0xC6] as i64) | ((io_ports[0xC7] as i64) << 8);
    var new_data: i64 = data;
    if op == 1 { ee_execute(0, comm, ee_bits[0]); new_data = ee_output[0]; }
    else if op == 2 { ee_input[0] = data; ee_execute(0, comm, ee_bits[0]); }
    else if op == 4 { ee_execute(0, comm, ee_bits[0]); }
    io_ports[0xC4] = (new_data & 0xFF) as! u8; io_ports[0xC5] = ((new_data >> 8) & 0xFF) as! u8;
    var done: i64 = 0; if op == 1 || op == 8 { done = 1; }
    io_ports[0xC8] = ((v & 0xF0) | 0x02 | done) as! u8;
}

var ee_pass: i64 = 0;
var ee_fail: i64 = 0;

fn ee_check(name: const u8[:], got: i64, want: i64) {
    if got == want { ee_pass += 1; }
    else { ee_fail += 1; print("FAIL ", name, ": got ", got, " want ", want); }
}

fn ee_reset(save: i64) {
    for i in 256 { io_ports[i] = 0; }
    ws_mode = true; ws_mono_cart = false; dbg_op = 0;
    ee_init_cart(save);
}

fn eeprom_test() {
    // Internal EEPROM: Swanium's bus-test sequences, through the ports
    ee_reset(0);
    port_wr(0xBC, 0x00); port_wr(0xBD, 0x18); port_wr(0xBE, 0x10);
    ee_check("ie read done delayed", port_rd(0xBE) & 1, 0);
    ee_check("ie read done after poll", port_rd(0xBE) & 1, 1);
    ee_check("ie default word lo", port_rd(0xBA), 0);
    ee_check("ie default word hi", port_rd(0xBB), 0);
    ee_reset(0);
    port_wr(0xBA, 0xEF); port_wr(0xBB, 0xBE); port_wr(0xBC, 0x00); port_wr(0xBD, 0x14); port_wr(0xBE, 0x20);
    ee_check("ie status ready", port_rd(0xBE) & 2, 2);
    port_wr(0xBC, 0x00); port_wr(0xBD, 0x18); port_wr(0xBE, 0x10);
    port_rd(0xBE); port_rd(0xBE);
    ee_check("ie roundtrip lo", port_rd(0xBA), 0xEF);
    ee_check("ie roundtrip hi", port_rd(0xBB), 0xBE);
    ee_reset(0);
    port_wr(0xBA, 0x55); port_wr(0xBB, 0xAA); port_wr(0xBC, 0x40); port_wr(0xBD, 0x01); port_wr(0xBE, 0x20);
    port_wr(0xBC, 0x00); port_wr(0xBD, 0x18); port_wr(0xBE, 0x10);
    port_rd(0xBE); port_rd(0xBE);
    ee_check("ie mono-width write lo", port_rd(0xBA), 0x55);
    ee_check("ie mono-width write hi", port_rd(0xBB), 0xAA);
    ee_reset(0);
    port_wr(0xBA, 0x34); port_wr(0xBB, 0x12); port_wr(0xBC, 0x30); port_wr(0xBD, 0x14); port_wr(0xBE, 0x20);
    ee_check("ie protect fault bit", port_rd(0xBE) & 0x80, 0x80);
    port_wr(0xBC, 0x30); port_wr(0xBD, 0x18); port_wr(0xBE, 0x10);
    port_rd(0xBE); port_rd(0xBE);
    ee_check("ie protected word lo", port_rd(0xBA), 0);
    ee_check("ie protected word hi", port_rd(0xBB), 0);
    // Cartridge EEPROM (128-byte device, 6-bit commands), through the ports
    ee_reset(0x10);
    port_wr(0xC4, 0xCD); port_wr(0xC5, 0xAB); port_wr(0xC6, 0x40); port_wr(0xC7, 0x01); port_wr(0xC8, 0x20);
    port_wr(0xC6, 0x80); port_wr(0xC7, 0x01); port_wr(0xC8, 0x10);
    ee_check("ce locked write blocked lo", port_rd(0xC4), 0xFF);
    ee_check("ce locked write blocked hi", port_rd(0xC5), 0xFF);
    ee_check("ce read sets DONE", port_rd(0xC8) & 1, 1);
    ee_check("ce status ready bit", port_rd(0xC8) & 2, 2);
    port_wr(0xC6, 0x30); port_wr(0xC7, 0x01); port_wr(0xC8, 0x40);
    ee_check("ce short command keeps DONE clear", port_rd(0xC8) & 1, 0);
    port_wr(0xC4, 0xCD); port_wr(0xC5, 0xAB); port_wr(0xC6, 0x40); port_wr(0xC7, 0x01); port_wr(0xC8, 0x20);
    port_wr(0xC6, 0x80); port_wr(0xC7, 0x01); port_wr(0xC8, 0x10);
    ee_check("ce write after EWEN lo", port_rd(0xC4), 0xCD);
    ee_check("ce write after EWEN hi", port_rd(0xC5), 0xAB);
    port_wr(0xC4, 0x00); port_wr(0xC5, 0x00); port_wr(0xC6, 0x41); port_wr(0xC7, 0x01); port_wr(0xC8, 0x20);
    port_wr(0xC6, 0xC1); port_wr(0xC7, 0x01); port_wr(0xC8, 0x40);
    port_wr(0xC6, 0x81); port_wr(0xC7, 0x01); port_wr(0xC8, 0x10);
    ee_check("ce erase restores ones", port_rd(0xC4), 0xFF);
    port_wr(0xC6, 0x00); port_wr(0xC7, 0x01); port_wr(0xC8, 0x40);
    port_wr(0xC4, 0x34); port_wr(0xC5, 0x12); port_wr(0xC6, 0x40); port_wr(0xC7, 0x01); port_wr(0xC8, 0x20);
    port_wr(0xC6, 0x80); port_wr(0xC7, 0x01); port_wr(0xC8, 0x10);
    ee_check("ce EWDS blocks write lo", port_rd(0xC4), 0xCD);
    ee_check("ce EWDS blocks write hi", port_rd(0xC5), 0xAB);
    // No cartridge EEPROM: open bus, writes ignored
    ee_reset(0);
    ee_check("ce absent data reads open bus", port_rd(0xC4), 0xFF);
    ee_check("ce absent status reads open bus", port_rd(0xC8), 0xFF);
    port_wr(0xC4, 0x55);
    ee_check("ce absent writes ignored", port_rd(0xC4), 0xFF);
    print("eeprom_test: ", ee_pass, " passed, ", ee_fail, " failed");
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
fn ws_deliver_int() -> bool {
    let pending: i64 = int_cause & (io_ports[0xB2] as i64);
    if pending == 0 { return false; }
    cpu_halted = false;  // a pending enabled interrupt wakes HLT even with IF=0 (it just isn't serviced then; WSTimingTest's HLT case relies on this)
    if (flags & 0x0200) == 0 { return false; }
    var bit: i64 = 7;
    while bit > 0 && ((pending >> bit) & 1) == 0 { bit -= 1; }
    do_int(((io_ports[0xB0] as i64) & 0xF8) + bit);
    return true;
}

// Memory written during a case, so the next case can restore zeros.
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
fn run_ws(path: u8[:]) {
    ws_mode = true;
    cpu_v20 = true;
    cpu_mz = true;
    guard read_file(path, rom) else { print("cannot read ", path); exit(1); }
    if rom.len > 16 { ws_mono_cart = (rom[rom.len - 9] as i64) == 0; }
    if rom.len > 16 { ee_init_cart(rom[rom.len - 5] as i64); }
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
    if argv2.len > 4 && (argv2[4] == "fb" || argv2[4] == "fbwav") { fb_dump = true; }
    var wav_dump: bool = false;
    if argv2.len > 4 && (argv2[4] == "wav" || argv2[4] == "fbwav") { wav_dump = true; aud_enabled = true; }
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
            if ws_deliver_int() { ws_cycles += 40; spent += 40; }  // hardware IRQ entry = 40 (fault entry is 44; the 4-cycle difference is what ExIrq measures)
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
    if wav_dump { wav_write(); print("audio written to audio.wav samples=", aud_buf.len / 2); }
}

var ws_mono_cart: bool = false;  // set from the ROM footer in run_ws: mono-only carts get the mono serial behaviour
