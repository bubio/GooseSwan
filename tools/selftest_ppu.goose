// sst ppu_test: white-box synthetic PPU scenes.
namespace core;

// ---- PPU synthetic self-test (sst ppu_test) ----
// Hand-built scenes with hand-computed expected pixels: mono palettes and
// transparency, scroll, hflip, SCR2 windowing, colour palette RAM, the
// tile-bank bit and 4bpp packed tiles.
var ppu_pass: i64 = 0;
var ppu_fail: i64 = 0;

fn ppu_check(name: u8[:], got: i64, exp: i64) {
    if got == exp { ppu_pass += 1; } else { ppu_fail += 1; print("PPU FAIL ", name, ": got ", got, " expected ", exp); }
}

fn ppu_clear() {
    for i in 256 { io_ports[i] = 0; }
    for i in 65536 { mem[i] = 0; }
    for i in 32256 { fb[i] = 0; }
    spr_latch_valid = false;  // scenes rewrite the table: re-latch it at the next render
}

fn ppu_set16(addr: i64, w: i64) { mem[addr] = (w & 0xFF) as! u8; mem[addr + 1] = ((w >> 8) & 0xFF) as! u8; }

fn ppu_set_sprite(ea: i64, w: i64, yy: i64, xx: i64) { ppu_set16(ea, w); mem[ea + 2] = yy as! u8; mem[ea + 3] = xx as! u8; }

fn ppu_setup_sprite_common() {
    io_ports[0x30] = 0x10; io_ports[0x31] = 0x32;
    io_ports[0x38] = 0x02; io_ports[0x39] = 0x13;
    mem[0x2000 + 32] = 0xFF; mem[0x2000 + 33] = 0x00;
    for i in 6 { ppu_set16(i * 2, 2); }
}

fn ppu_setup_mono() {
    io_ports[0x1C] = 0x0F;
    io_ports[0x1D] = 0x37;
    io_ports[0x01] = 2;
    io_ports[0x20] = 0x10; io_ports[0x21] = 0x32;
    io_ports[0x28] = 0x10; io_ports[0x29] = 0x32;
    mem[0x2000 + 16] = 0xAA; mem[0x2000 + 17] = 0xCC;
}

fn ppu_test() {
    // Scene 1: mono SCR1 (tile 1 row 0 = pixels 3,2,1,0,3,2,1,0)
    ppu_clear();
    ppu_setup_mono();
    ppu_set16(0, 1);
    ppu_set16(2, 1 | (4 << 9) | (1 << 14));
    io_ports[0x00] = 1;
    io_ports[0x07] = 0;
    render_line(0);
    ppu_check("s1 x0 pix3", fb[0], 0xCCC);
    ppu_check("s1 x1 pix2", fb[1], 0x888);
    ppu_check("s1 x2 pix1", fb[2], 0xFFF);
    ppu_check("s1 x3 pix0 pal0 opaque", fb[3], 0x000);
    ppu_check("s1 x8 pal4 flipped pix0 transparent", fb[8], 0x888);
    ppu_check("s1 x11 pal4 flipped pix3", fb[11], 0xCCC);
    ppu_check("s1 x100 empty entry", fb[100], 0x000);
    io_ports[0x10] = 8;
    render_line(0);
    ppu_check("s1 scroll x0", fb[0], 0x888);
    ppu_check("s1 scroll x3", fb[3], 0xCCC);
    ppu_check("s1 scroll x8", fb[8], 0x000);
    // Scene 2: SCR2 window (tile 2 = all pixel 1 -> 0xFFF)
    ppu_clear();
    ppu_setup_mono();
    mem[0x2000 + 32] = 0xFF; mem[0x2000 + 33] = 0x00;
    ppu_set16(0, 1);
    io_ports[0x07] = 0x10;
    ppu_set16(0x800, 2);
    io_ports[0x08] = 0; io_ports[0x09] = 0; io_ports[0x0A] = 3; io_ports[0x0B] = 0;
    io_ports[0x00] = 1 | 2 | 0x20;
    render_line(0);
    ppu_check("s2 x0 scr2 inside", fb[0], 0xFFF);
    ppu_check("s2 x1 scr2 inside", fb[1], 0xFFF);
    ppu_check("s2 x4 scr1 outside", fb[4], 0xCCC);
    io_ports[0x00] = 1 | 2 | 0x20 | 0x10;
    render_line(0);
    ppu_check("s2 x0 scr1 outside-mode", fb[0], 0xCCC);
    ppu_check("s2 x4 scr2 outside-mode", fb[4], 0xFFF);
    // Scene 3: colour mode
    ppu_clear();
    io_ports[0x60] = 0x80;
    io_ports[0x01] = 0x05;
    ppu_set16(0xFE00 + 2, 0x123);
    ppu_set16(0xFE00 + 4, 0x0F0);
    ppu_set16(0xFE00 + 6, 0xF00);
    ppu_set16(0xFE00 + 10, 0xABC);
    mem[0x2000 + 16] = 0xAA; mem[0x2000 + 17] = 0xCC;
    ppu_set16(0, 1);
    io_ports[0x00] = 1;
    io_ports[0x07] = 0;
    render_line(0);
    ppu_check("s3 x0 color3", fb[0], 0xF00);
    ppu_check("s3 x1 color2", fb[1], 0x0F0);
    ppu_check("s3 x2 color1", fb[2], 0x123);
    ppu_check("s3 x3 transparent backdrop", fb[3], 0xABC);
    mem[0x2000 + 513 * 16] = 0xFF; mem[0x2000 + 513 * 16 + 1] = 0xFF;
    ppu_set16(2, 1 | (1 << 13));
    render_line(0);
    ppu_check("s3 x8 bank tile", fb[8], 0xF00);
    io_ports[0x60] = 0x80 | 0x40 | 0x20;
    mem[0x4000 + 32] = 0x12; mem[0x4000 + 33] = 0x34; mem[0x4000 + 34] = 0x56; mem[0x4000 + 35] = 0x78;
    for k in 8 { ppu_set16(0xFE00 + (k + 1) * 2, (k + 1) * 0x111); }
    ppu_set16(2, 0);
    render_line(0);
    ppu_check("s3 4bpp x0", fb[0], 0x111);
    ppu_check("s3 4bpp x1", fb[1], 0x222);
    ppu_check("s3 4bpp x6", fb[6], 0x777);
    ppu_check("s3 4bpp x7", fb[7], 0x888);
    // Scene 4: sprites
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x06] = 2;
    io_ports[0x00] = 1 | 4;
    ppu_set_sprite(0x800, 1, 0, 16);
    ppu_set_sprite(0x804, 1 | (4 << 9), 0, 20);
    render_line(0);
    ppu_check("s4 bg x0", fb[0], 0xFFF);
    ppu_check("s4 spr0 x16 pix3", fb[16], 0xCCC);
    ppu_check("s4 spr0 x17 pix2", fb[17], 0x888);
    ppu_check("s4 spr0 x19 pix0 pal8 opaque", fb[19], 0x000);
    ppu_check("s4 spr0 wins x20", fb[20], 0xCCC);
    ppu_check("s4 spr1 x25 pix2 pal12", fb[25], 0xCCC);
    ppu_check("s4 spr1 x27 pix0 transparent", fb[27], 0xFFF);
    // Priority vs SCR2 (sprites move to 0xC00; SCR2 takes base 0x800)
    io_ports[0x07] = 0x10;
    io_ports[0x04] = 6;
    io_ports[0x06] = 3;
    io_ports[0x00] = 1 | 2 | 4;
    mem[0x2000 + 48] = 0x00; mem[0x2000 + 49] = 0xFF;
    ppu_set16(0x800, 3);
    ppu_set16(0x802, 4 << 9);
    ppu_set_sprite(0xC00, 1, 0, 0);
    ppu_set_sprite(0xC04, 1 | (1 << 13), 0, 16);
    ppu_set_sprite(0xC08, 1, 0, 8);
    spr_latch_valid = false;
    render_line(0);
    ppu_check("s4 prio0 behind scr2 x0", fb[0], 0x888);
    ppu_check("s4 prio0 through transparent scr2 x8", fb[8], 0xCCC);
    ppu_check("s4 prio1 front of scr2 x16", fb[16], 0xCCC);
    // Sprite window: sprite D (prio 1, window attr) at x32, window x 0..35
    ppu_set_sprite(0xC0C, 1 | (1 << 13) | (1 << 12), 0, 32);
    io_ports[0x06] = 4;
    io_ports[0x00] = 1 | 2 | 4 | 8;
    io_ports[0x0C] = 0; io_ports[0x0D] = 0; io_ports[0x0E] = 35; io_ports[0x0F] = 0;
    spr_latch_valid = false;
    render_line(0);
    ppu_check("s4 sprwin hidden x32", fb[32], 0x000);
    ppu_check("s4 sprwin shown x36", fb[36], 0xCCC);
    // 32-per-line limit: 32 transparent sprites consume the line's slots
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x00] = 1 | 4;
    for i in 33 {
        if i < 32 { ppu_set_sprite(0x800 + i * 4, 4 << 9, 0, i * 8); }
        else { ppu_set_sprite(0x800 + i * 4, 1, 0, 16); }
    }
    io_ports[0x06] = 33;
    render_line(0);
    ppu_check("s4 limit 33rd ignored x16", fb[16], 0xFFF);
    ppu_set_sprite(0x800 + 5 * 4, 1, 0, 16);
    ppu_set_sprite(0x800 + 32 * 4, 4 << 9, 0, 128);
    spr_latch_valid = false;
    render_line(0);
    ppu_check("s4 limit slot5 visible x16", fb[16], 0xCCC);
    // Y wrap: sprite at Y=254 covers line 1 at tile row 3 (all pixel 0)
    ppu_clear();
    ppu_setup_mono();
    ppu_setup_sprite_common();
    io_ports[0x07] = 0;
    io_ports[0x04] = 4;
    io_ports[0x05] = 0;
    io_ports[0x06] = 1;
    io_ports[0x00] = 1 | 4;
    ppu_set_sprite(0x800, 1, 254, 48);
    render_line(1);
    ppu_check("s4 ywrap line1 x48", fb[224 + 48], 0x000);
    print("ppu_test: ", ppu_pass, " passed, ", ppu_fail, " failed");
}
