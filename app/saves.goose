// Save-data persistence: the core hands out its save media as bytes;
// the frontend keeps them next to the ROM as <rom>.sav (cartridge
// SRAM), <rom>.eep (cartridge EEPROM, only when fitted) and <rom>.iep
// (the console's internal EEPROM). Loaded after power-on, written on
// exit and every 600 frames.

fn save_path(path: const u8[:], kind: i64) -> u8[>..] {
    var name: u8[>..] = [];
    for i in path.len { name.push(path[i]); }
    let ext = if kind == core::SAVE_SRAM { ".sav" } else if kind == core::SAVE_CART_EEPROM { ".eep" } else { ".iep" };
    for i in ext.len { name.push(ext[i]); }
    return name;
}

fn load_saves(path: const u8[:]) {
    for kind in 3 {
        if core::save_size(kind) == 0 { continue; }
        var buf: u8[>..] = [];
        if read_file(save_path(path, kind), buf) { core::save_load(kind, buf); }
    }
}

fn save_saves(path: const u8[:]) {
    for kind in 3 {
        if core::save_size(kind) == 0 { continue; }
        var buf: u8[>..] = [];
        core::save_read(kind, buf);
        write_file(save_path(path, kind), buf);
    }
}
