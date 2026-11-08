// Save-data persistence: the core hands out its save media as bytes;
// the frontend keeps them next to the ROM as <rom>.sav (cartridge
// SRAM), <rom>.eep (cartridge EEPROM, only when fitted) and <rom>.iep
// (the console's internal EEPROM), plus <rom>.rtc for a cartridge
// clock's registers. Loaded after power-on, written on exit and every
// 600 frames.

fn save_path(path: const u8[:], kind: i64) -> u8[>..] {
    var name: u8[>..] = [];
    for i in path.len { name.push(path[i]); }
    let ext = if kind == core::SAVE_SRAM { ".sav" } else if kind == core::SAVE_CART_EEPROM { ".eep" } else if kind == core::SAVE_RTC { ".rtc" } else { ".iep" };
    for i in ext.len { name.push(ext[i]); }
    return name;
}

fn load_saves(path: const u8[:]) {
    for kind in core::SAVE_KINDS {
        if core::save_size(kind) == 0 { continue; }
        var buf: u8[>..] = [];
        if read_file(save_path(path, kind), buf) { core::save_load(kind, buf); }
    }
}

fn save_saves(path: const u8[:]) {
    for kind in core::SAVE_KINDS {
        if core::save_size(kind) == 0 { continue; }
        var buf: u8[>..] = [];
        core::save_read(kind, buf);
        write_file(save_path(path, kind), buf);
    }
}

// Set a cartridge clock from the host's wall clock (UTC: the os
// package exposes no time zone), as Swanium's frontend does at load.
fn sync_rtc_to_host() {
    if !core::has_rtc() { return; }
    let secs: i64 = time_ns() / 1000000000;
    let days: i64 = secs / 86400;
    let rem: i64 = secs % 86400;
    // civil_from_days (Howard Hinnant)
    let z: i64 = days + 719468;
    let era: i64 = z / 146097;
    let doe: i64 = z - era * 146097;
    let yoe: i64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy: i64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp: i64 = (5 * doy + 2) / 153;
    let d: i64 = doy - (153 * mp + 2) / 5 + 1;
    let m: i64 = if mp < 10 { mp + 3 } else { mp - 9 };
    let y: i64 = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    core::set_rtc_datetime(y, m, d, (days + 4) % 7, rem / 3600, (rem / 60) % 60, rem % 60);
}
