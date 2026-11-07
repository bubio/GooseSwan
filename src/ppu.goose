// GooseSwan PPU: background/sprite rendering into the RGB444
// framebuffer, plus the synthetic ppu_test self-test.

var fb: u16[32256] = [0; 32256];

fn ppu_color_mode() -> bool { return ((io_ports[0x60] as i64) & 0x80) != 0; }

fn ppu_tile_pixel(tile: i64, tx: i64, ty: i64) -> i64 {
    let vm: i64 = io_ports[0x60] as i64;
    if (vm & 0x80) != 0 && (vm & 0x40) != 0 {
        let base: i64 = 0x4000 + tile * 32 + ty * 4;
        if (vm & 0x20) != 0 {
            let b: i64 = mem[base + (tx >> 1)] as i64;
            if (tx & 1) == 0 { return (b >> 4) & 15; }
            return b & 15;
        }
        var px: i64 = 0;
        let bit: i64 = 7 - tx;
        for pl in 4 { px |= (((mem[base + pl] as i64) >> bit) & 1) << pl; }
        return px;
    }
    let a: i64 = 0x2000 + tile * 16 + ty * 2;
    let bit2: i64 = 7 - tx;
    let lo: i64 = ((mem[a] as i64) >> bit2) & 1;
    let hi: i64 = ((mem[a + 1] as i64) >> bit2) & 1;
    return (hi << 1) | lo;
}

fn ppu_shade(idx: i64) -> i64 {
    let b: i64 = io_ports[0x1C + (idx >> 1)] as i64;
    if (idx & 1) == 0 { return b & 15; }
    return (b >> 4) & 15;
}

fn ppu_grey(shade: i64) -> i64 { let n: i64 = 15 - (shade & 15); return (n << 8) | (n << 4) | n; }

fn ppu_resolve_mono(pal: i64, pixel: i64) -> i64 {
    let b: i64 = io_ports[0x20 + pal * 2 + (pixel >> 1)] as i64;
    var pool: i64 = (b >> 4) & 7;
    if (pixel & 1) == 0 { pool = b & 7; }
    return ppu_grey(ppu_shade(pool));
}

fn ppu_resolve_color(pal: i64, pixel: i64) -> i64 {
    let a: i64 = 0xFE00 + (pal * 16 + pixel) * 2;
    return ((mem[a] as i64) | ((mem[a + 1] as i64) << 8)) & 0xFFF;
}

fn ppu_resolve(pal: i64, pixel: i64) -> i64 {
    if ppu_color_mode() { return ppu_resolve_color(pal, pixel); }
    return ppu_resolve_mono(pal, pixel);
}

fn ppu_transparent(pal: i64, pixel: i64) -> bool {
    if pixel != 0 { return false; }
    if ppu_color_mode() { return true; }
    return !((pal >= 0 && pal <= 3) || (pal >= 8 && pal <= 11));
}

fn ppu_backdrop() -> i64 {
    let b: i64 = io_ports[0x01] as i64;
    if ppu_color_mode() { return ppu_resolve_color(b >> 4, b & 15); }
    return ppu_grey(ppu_shade(b & 7));
}

fn ppu_bg_sample(layer: i64, x: i64, y: i64) -> i64, i64 {
    var sx: i64 = io_ports[0x10] as i64;
    var sy: i64 = io_ports[0x11] as i64;
    var nib: i64 = (io_ports[0x07] as i64) & 0x0F;
    if layer == 1 { sx = io_ports[0x12] as i64; sy = io_ports[0x13] as i64; nib = ((io_ports[0x07] as i64) >> 4) & 0x0F; }
    if !ppu_color_mode() { nib = nib & 7; }
    let base: i64 = nib << 11;
    let bgx: i64 = (x + sx) & 0xFF;
    let bgy: i64 = (y + sy) & 0xFF;
    let ea: i64 = base + (((bgy >> 3) * 32) + (bgx >> 3)) * 2;
    let w: i64 = (mem[ea] as i64) | ((mem[ea + 1] as i64) << 8);
    var tile: i64 = w & 0x1FF;
    if ppu_color_mode() && (w & 0x2000) != 0 { tile += 512; }
    let pal: i64 = (w >> 9) & 0x0F;
    var tx: i64 = bgx & 7;
    var ty: i64 = bgy & 7;
    if (w & 0x4000) != 0 { tx = 7 - tx; }
    if (w & 0x8000) != 0 { ty = 7 - ty; }
    return ppu_tile_pixel(tile, tx, ty), pal;
}

fn ppu_scr2_visible(x: i64, y: i64) -> bool {
    let dc: i64 = io_ports[0x00] as i64;
    if (dc & 0x20) == 0 { return true; }
    let inside: bool = x >= (io_ports[0x08] as i64) && x <= (io_ports[0x0A] as i64) && y >= (io_ports[0x09] as i64) && y <= (io_ports[0x0B] as i64);
    if (dc & 0x10) != 0 { return !inside; }
    return inside;
}

// Sprite line buffers: the first opaque sprite pixel per column (any
// priority) and the first opaque priority-1 (in front of SCR2) pixel.
var spr_any_c: i64[224] = [0; 224];
var spr_any_on: bool[224] = [false; 224];
var spr_front_c: i64[224] = [0; 224];
var spr_front_on: bool[224] = [false; 224];

// Fill the sprite line buffers for line y from the live attribute table
// (Swanium latches the table per frame; sampling it per line is the
// documented simplification here). At most 32 sprites per line count,
// in table order starting at SPR_FIRST; X wraps at 256.
fn ppu_sprite_line(y: i64) {
    for i in 224 { spr_any_on[i] = false; spr_front_on[i] = false; }
    let base: i64 = ((io_ports[0x04] as i64) & 0x3F) << 9;
    let first: i64 = io_ports[0x05] as i64;
    var count: i64 = io_ports[0x06] as i64; if count > 128 { count = 128; }
    let dc: i64 = io_ports[0x00] as i64;
    var used: i64 = 0;
    var n: i64 = 0;
    while n < count && used < 32 {
        let idx: i64 = (first + n) & 127; n += 1;
        let ea: i64 = base + idx * 4;
        let w: i64 = (mem[ea] as i64) | ((mem[ea + 1] as i64) << 8);
        let sy: i64 = mem[ea + 2] as i64;
        let sx: i64 = mem[ea + 3] as i64;
        var dy: i64 = y - sy; if dy < 0 { dy += 256; }
        if dy >= 8 { continue; }
        used += 1;
        var ty: i64 = dy; if (w & 0x8000) != 0 { ty = 7 - ty; }
        let tile: i64 = w & 0x1FF;
        let pal: i64 = ((w >> 9) & 7) + 8;
        let prio: bool = (w & 0x2000) != 0;
        let wattr: bool = (w & 0x1000) != 0;
        for dx in 8 {
            var x: i64 = sx + dx; if x >= 256 { x -= 256; }
            if x >= 224 { continue; }
            if spr_any_on[x] && (!prio || spr_front_on[x]) { continue; }
            if (dc & 8) != 0 && wattr && x >= (io_ports[0x0C] as i64) && x <= (io_ports[0x0E] as i64) && y >= (io_ports[0x0D] as i64) && y <= (io_ports[0x0F] as i64) { continue; }
            var tx: i64 = dx; if (w & 0x4000) != 0 { tx = 7 - tx; }
            let px: i64 = ppu_tile_pixel(tile, tx, ty);
            if ppu_transparent(pal, px) { continue; }
            let c: i64 = ppu_resolve(pal, px);
            if !spr_any_on[x] { spr_any_on[x] = true; spr_any_c[x] = c; }
            if prio && !spr_front_on[x] { spr_front_on[x] = true; spr_front_c[x] = c; }
        }
    }
}

fn render_line(y: i64) {
    if y < 0 || y >= 144 { return; }
    let dc: i64 = io_ports[0x00] as i64;
    let bd: i64 = ppu_backdrop();
    let row: i64 = y * 224;
    if (dc & 4) != 0 { ppu_sprite_line(y); }
    for x in 224 {
        var c: i64 = bd;
        if (dc & 1) != 0 { let px, pal = ppu_bg_sample(0, x, y); if !ppu_transparent(pal, px) { c = ppu_resolve(pal, px); } }
        var s2_on: bool = false;
        var s2_c: i64 = 0;
        if (dc & 2) != 0 && ppu_scr2_visible(x, y) { let px2, pal2 = ppu_bg_sample(1, x, y); if !ppu_transparent(pal2, px2) { s2_on = true; s2_c = ppu_resolve(pal2, px2); } }
        if (dc & 4) != 0 {
            if s2_on { if spr_front_on[x] { c = spr_front_c[x]; } else { c = s2_c; } }
            else if spr_any_on[x] { c = spr_any_c[x]; }
        } else if s2_on { c = s2_c; }
        fb[row + x] = c as! u16;
    }
}

fn fb_hash() -> i64 {
    var h: i64 = 5381;
    for i in 32256 { h = ((h << 5) + h) ^ (fb[i] as i64); }
    return h;
}

fn fb_write_ppm() {
    var ppm: u8[>..] = [];
    let hdr = "P6\n224 144\n255\n";
    for i in hdr.len { ppm.push(hdr[i]); }
    for i in 32256 {
        let c: i64 = fb[i] as i64;
        ppm.push((((c >> 8) & 15) * 17) as! u8);
        ppm.push((((c >> 4) & 15) * 17) as! u8);
        ppm.push(((c & 15) * 17) as! u8);
    }
    write_file("framebuffer.ppm", ppm);
}


// ---- APU: wave channels, sweep, mixer readback, GDMA ----
// Channel/sweep state follows Swanium's apu module. The audible sample
// stream is not generated (no frontend yet); what is modelled is every
// CPU-visible surface: channel sample state behind the SND_CH_OUT
// readback ports 0x96-0x9B, the sweep's pitch write-back, and GDMA.
var ppu_pass: i64 = 0;
var ppu_fail: i64 = 0;

fn ppu_check(name: u8[:], got: i64, exp: i64) {
    if got == exp { ppu_pass += 1; } else { ppu_fail += 1; print("PPU FAIL ", name, ": got ", got, " expected ", exp); }
}

fn ppu_clear() {
    for i in 256 { io_ports[i] = 0; }
    for i in 65536 { mem[i] = 0; }
    for i in 32256 { fb[i] = 0; }
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
    ppu_check("s1 x0 pix3", fb[0] as i64, 0xCCC);
    ppu_check("s1 x1 pix2", fb[1] as i64, 0x888);
    ppu_check("s1 x2 pix1", fb[2] as i64, 0xFFF);
    ppu_check("s1 x3 pix0 pal0 opaque", fb[3] as i64, 0x000);
    ppu_check("s1 x8 pal4 flipped pix0 transparent", fb[8] as i64, 0x888);
    ppu_check("s1 x11 pal4 flipped pix3", fb[11] as i64, 0xCCC);
    ppu_check("s1 x100 empty entry", fb[100] as i64, 0x000);
    io_ports[0x10] = 8;
    render_line(0);
    ppu_check("s1 scroll x0", fb[0] as i64, 0x888);
    ppu_check("s1 scroll x3", fb[3] as i64, 0xCCC);
    ppu_check("s1 scroll x8", fb[8] as i64, 0x000);
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
    ppu_check("s2 x0 scr2 inside", fb[0] as i64, 0xFFF);
    ppu_check("s2 x1 scr2 inside", fb[1] as i64, 0xFFF);
    ppu_check("s2 x4 scr1 outside", fb[4] as i64, 0xCCC);
    io_ports[0x00] = 1 | 2 | 0x20 | 0x10;
    render_line(0);
    ppu_check("s2 x0 scr1 outside-mode", fb[0] as i64, 0xCCC);
    ppu_check("s2 x4 scr2 outside-mode", fb[4] as i64, 0xFFF);
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
    ppu_check("s3 x0 color3", fb[0] as i64, 0xF00);
    ppu_check("s3 x1 color2", fb[1] as i64, 0x0F0);
    ppu_check("s3 x2 color1", fb[2] as i64, 0x123);
    ppu_check("s3 x3 transparent backdrop", fb[3] as i64, 0xABC);
    mem[0x2000 + 513 * 16] = 0xFF; mem[0x2000 + 513 * 16 + 1] = 0xFF;
    ppu_set16(2, 1 | (1 << 13));
    render_line(0);
    ppu_check("s3 x8 bank tile", fb[8] as i64, 0xF00);
    io_ports[0x60] = 0x80 | 0x40 | 0x20;
    mem[0x4000 + 32] = 0x12; mem[0x4000 + 33] = 0x34; mem[0x4000 + 34] = 0x56; mem[0x4000 + 35] = 0x78;
    for k in 8 { ppu_set16(0xFE00 + (k + 1) * 2, (k + 1) * 0x111); }
    ppu_set16(2, 0);
    render_line(0);
    ppu_check("s3 4bpp x0", fb[0] as i64, 0x111);
    ppu_check("s3 4bpp x1", fb[1] as i64, 0x222);
    ppu_check("s3 4bpp x6", fb[6] as i64, 0x777);
    ppu_check("s3 4bpp x7", fb[7] as i64, 0x888);
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
    ppu_check("s4 bg x0", fb[0] as i64, 0xFFF);
    ppu_check("s4 spr0 x16 pix3", fb[16] as i64, 0xCCC);
    ppu_check("s4 spr0 x17 pix2", fb[17] as i64, 0x888);
    ppu_check("s4 spr0 x19 pix0 pal8 opaque", fb[19] as i64, 0x000);
    ppu_check("s4 spr0 wins x20", fb[20] as i64, 0xCCC);
    ppu_check("s4 spr1 x25 pix2 pal12", fb[25] as i64, 0xCCC);
    ppu_check("s4 spr1 x27 pix0 transparent", fb[27] as i64, 0xFFF);
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
    render_line(0);
    ppu_check("s4 prio0 behind scr2 x0", fb[0] as i64, 0x888);
    ppu_check("s4 prio0 through transparent scr2 x8", fb[8] as i64, 0xCCC);
    ppu_check("s4 prio1 front of scr2 x16", fb[16] as i64, 0xCCC);
    // Sprite window: sprite D (prio 1, window attr) at x32, window x 0..35
    ppu_set_sprite(0xC0C, 1 | (1 << 13) | (1 << 12), 0, 32);
    io_ports[0x06] = 4;
    io_ports[0x00] = 1 | 2 | 4 | 8;
    io_ports[0x0C] = 0; io_ports[0x0D] = 0; io_ports[0x0E] = 35; io_ports[0x0F] = 0;
    render_line(0);
    ppu_check("s4 sprwin hidden x32", fb[32] as i64, 0x000);
    ppu_check("s4 sprwin shown x36", fb[36] as i64, 0xCCC);
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
    ppu_check("s4 limit 33rd ignored x16", fb[16] as i64, 0xFFF);
    ppu_set_sprite(0x800 + 5 * 4, 1, 0, 16);
    ppu_set_sprite(0x800 + 32 * 4, 4 << 9, 0, 128);
    render_line(0);
    ppu_check("s4 limit slot5 visible x16", fb[16] as i64, 0xCCC);
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
    ppu_check("s4 ywrap line1 x48", fb[224 + 48] as i64, 0x000);
    print("ppu_test: ", ppu_pass, " passed, ", ppu_fail, " failed");
}
