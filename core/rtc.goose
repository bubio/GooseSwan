// Gooswan cartridge real-time clock (ports 0xCA command/status, 0xCB
// data), after Swanium's bus/cart/rtc.rs. Present only when the footer
// says so: flags byte (0xC) bit 2 together with a non-zero mapper byte
// (0xD) — bit 2 alone is the fast-ROM flag on most retail carts.
//
// The core never reads the wall clock: the host injects a date/time
// (core::set_rtc_datetime) and the clock then free-runs off emulated
// cycles. Without an injected time it starts at 2000-01-01 00:00:00
// (a Saturday), so headless runs stay reproducible.
namespace core;

var rtc_present: bool = false;
// Battery-backed registers (BCD except weekday): year, month, day,
// weekday, hour, minute, second, status, alarm hour, alarm minute.
var rtc_reg:              i64[10] = [0; 10];
var rtc_cmd:              i64     = 0;
var rtc_index:            i64     = 0;
var rtc_remaining:        i64     = 0;
var rtc_unsupported_busy: bool    = false;
var rtc_cycles:           i64     = 0;

fn rtc_to_bcd(v: i64) -> i64 { ((v / 10) << 4) | (v % 10) }
fn rtc_from_bcd(v: i64) -> i64 { (v >> 4) * 10 + (v & 0x0F) }

fn rtc_reset_registers() {
    for i in 10 { rtc_reg[i] = 0; }
    rtc_reg[1] = 0x01; rtc_reg[2] = 0x01; rtc_reg[3] = 6;
}

fn rtc_power_on(footer_flags: i64, footer_mapper: i64) {
    rtc_present = (footer_flags & 0x04) != 0 && footer_mapper != 0;
    rtc_reset_registers();
    rtc_cmd = 0; rtc_index = 0; rtc_remaining = 0; rtc_unsupported_busy = false; rtc_cycles = 0;
}

fn rtc_set_datetime(year: i64, month: i64, day: i64, weekday: i64, hour: i64, minute: i64, second: i64) {
    rtc_reg[0] = rtc_to_bcd(year % 100);
    rtc_reg[1] = rtc_to_bcd(if month < 1 { 1 } else if month > 12 { 12 } else { month });
    rtc_reg[2] = rtc_to_bcd(if day < 1 { 1 } else if day > 31 { 31 } else { day });
    rtc_reg[3] = weekday % 7;
    rtc_reg[4] = rtc_to_bcd(if hour > 23 { 23 } else { hour });
    rtc_reg[5] = rtc_to_bcd(if minute > 59 { 59 } else { minute });
    rtc_reg[6] = rtc_to_bcd(if second > 59 { 59 } else { second });
    rtc_cycles = 0;
}

fn rtc_days_in_month(month: i64, year: i64) -> i64 {
    if month == 4 || month == 6 || month == 9 || month == 11 { return 30; }
    if month == 2 { return if year % 4 == 0 { 29 } else { 28 }; }
    return 31;
}

fn rtc_advance_second() {
    let s: i64 = rtc_from_bcd(rtc_reg[6]) + 1;
    if s < 60 { rtc_reg[6] = rtc_to_bcd(s); return; }
    rtc_reg[6] = 0;
    let mi: i64 = rtc_from_bcd(rtc_reg[5]) + 1;
    if mi < 60 { rtc_reg[5] = rtc_to_bcd(mi); return; }
    rtc_reg[5] = 0;
    let h: i64 = rtc_from_bcd(rtc_reg[4]) + 1;
    if h < 24 { rtc_reg[4] = rtc_to_bcd(h); return; }
    rtc_reg[4] = 0;
    rtc_reg[3] = (rtc_reg[3] + 1) % 7;
    let year:  i64 = rtc_from_bcd(rtc_reg[0]);
    let month: i64 = rtc_from_bcd(rtc_reg[1]);
    let d:     i64 = rtc_from_bcd(rtc_reg[2]) + 1;
    if d <= rtc_days_in_month(month, year) { rtc_reg[2] = rtc_to_bcd(d); return; }
    rtc_reg[2] = 0x01;
    if month + 1 <= 12 { rtc_reg[1] = rtc_to_bcd(month + 1); return; }
    rtc_reg[1] = 0x01;
    rtc_reg[0] = rtc_to_bcd((year + 1) % 100);
}

fn rtc_tick(cycles: i64) {
    if !rtc_present { return; }
    rtc_cycles += cycles;
    while rtc_cycles >= 3072000 { rtc_cycles -= 3072000; rtc_advance_second(); }
}

// Payload length of each command (low 5 bits); 0 = unsupported.
fn rtc_transfer_len(c: i64) -> i64 {
    if c >= 0x10 && c <= 0x13 { return 1; }
    if c == 0x14 || c == 0x15 { return 7; }
    if c == 0x16 || c == 0x17 { return 3; }
    if c >= 0x18 && c <= 0x1B { return 2; }
    return 0;
}

fn rtc_write_command(v: i64) {
    rtc_cmd = v; rtc_index = 0;
    if (v & 0x80) != 0 { rtc_remaining = 0; rtc_unsupported_busy = false; return; }  // the ready bit cannot be forced
    let c: i64 = v & 0x1F;
    rtc_remaining = rtc_transfer_len(c);
    rtc_unsupported_busy = rtc_remaining == 0;
    if c == 0x10 { rtc_reset_registers(); }
}

fn rtc_read_command() -> i64 {
    var v: i64 = 0;
    if rtc_remaining > 0 { v |= 0x80; }                          // ready
    if rtc_remaining > 1 || rtc_unsupported_busy { v |= 0x10; }  // busy: more bytes pending
    return v;
}

fn rtc_consume() { if rtc_remaining > 0 { rtc_remaining -= 1; } }

fn rtc_write_data(v: i64) {
    let c: i64 = rtc_cmd & 0x1F;
    if c == 0x14 || c == 0x15 {
        rtc_reg[rtc_index] = if rtc_index == 3 { v & 7 } else { v };
        rtc_index = (rtc_index + 1) % 7; rtc_consume();
    } else if c == 0x18 || c == 0x1A {
        rtc_reg[8 + rtc_index] = v;
        rtc_index = (rtc_index + 1) % 2; rtc_consume();
    } else if c == 0x12 || c == 0x13 { rtc_reg[7] = v; rtc_consume(); }
    else if c == 0x16 || c == 0x17 { rtc_consume(); }
}

fn rtc_read_data() -> i64 {
    let c: i64 = rtc_cmd & 0x1F;
    if c == 0x14 || c == 0x15 { let v: i64 = rtc_reg[rtc_index]; rtc_index = (rtc_index + 1) % 7; rtc_consume(); return v; }
    if c == 0x19 || c == 0x1B { let v: i64 = rtc_reg[8 + rtc_index]; rtc_index = (rtc_index + 1) % 2; rtc_consume(); return v; }
    if c == 0x12 || c == 0x13 { rtc_consume(); return rtc_reg[7]; }
    if c == 0x16 || c == 0x17 { rtc_consume(); return 0; }
    return 0x90;
}
