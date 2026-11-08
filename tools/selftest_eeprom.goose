// sst eeprom_test: white-box self-test of the serial EEPROM devices.
namespace core;

var ee_pass: i64 = 0;
var ee_fail: i64 = 0;

fn ee_check(name: const u8[:], got: i64, want: i64) {
    if got == want { ee_pass += 1; }
    else { ee_fail += 1; print("FAIL ", name, ": got ", got, " want ", want); }
}

fn ee_reset(save: i64) {
    for i in 256 { io_ports[i] = 0; }
    ws_mode = true; model_mono = false; dbg_op = 0;
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
