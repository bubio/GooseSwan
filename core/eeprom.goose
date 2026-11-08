// Gooswan serial EEPROMs: the cartridge and internal 93Cxx devices.
namespace core;

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
    else if opcode == 2 { ee_output[dev] = ee_data[base + baddr] | ((ee_data[base + baddr + 1] as i64) << 8); }
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
    let comm: i64 = io_ports[0xBC] | ((io_ports[0xBD] as i64) << 8);
    if v == 0x10 { ee_execute(1, comm, ie_bits(comm)); ie_done = false; ie_delay = 1; }
    else if v == 0x20 {
        ee_input[1] = io_ports[0xBA] | ((io_ports[0xBB] as i64) << 8);
        let baddr: i64 = (comm & ((1 << ie_bits(comm)) - 1)) * 2;
        if baddr >= 0x60 { ie_fault = true; ie_done = true; ie_delay = 0; }
        else { ee_execute(1, comm, ie_bits(comm)); ie_done = false; ie_delay = 0; }
    }
    else if v == 0x40 { ee_execute(1, comm, ie_bits(comm)); ie_done = true; ie_delay = 0; }
    else { ie_done = false; ie_delay = 0; }
}

fn ce_control(v: i64) {
    let op: i64 = v >> 4;
    let data: i64 = io_ports[0xC4] | ((io_ports[0xC5] as i64) << 8);
    let comm: i64 = io_ports[0xC6] | ((io_ports[0xC7] as i64) << 8);
    var new_data: i64 = data;
    if op == 1 { ee_execute(0, comm, ee_bits[0]); new_data = ee_output[0]; }
    else if op == 2 { ee_input[0] = data; ee_execute(0, comm, ee_bits[0]); }
    else if op == 4 { ee_execute(0, comm, ee_bits[0]); }
    io_ports[0xC4] = (new_data & 0xFF) as! u8; io_ports[0xC5] = ((new_data >> 8) & 0xFF) as! u8;
    var done: i64 = 0; if op == 1 || op == 8 { done = 1; }
    io_ports[0xC8] = ((v & 0xF0) | 0x02 | done) as! u8;
}
