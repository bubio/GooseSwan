// Gooswan PPU: background/sprite rendering into the RGB444
// framebuffer (224x144), one completed scanline at a time.
namespace core;

var fb: u16[32256] = [0; 32256];

fn ppu_color_mode() -> bool { return !model_mono && ((io_ports[0x60] as i64) & 0x80) != 0; }  // a mono WonderSwan ignores the colour-mode bit (Swanium color_rendering_enabled)

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
// Sprite attributes are latched per frame, as Swanium does: the table is
// captured just before line 142 renders and becomes active when the
// frame ends, so mid-frame OAM writes show up on the next frame. Until
// the first capture the live table is latched once.
var spr_latch: i64[384] = [0; 384];   // w, y, x per entry
var spr_latch_n: i64 = 0;
var spr_next: i64[384] = [0; 384];
var spr_next_n: i64 = 0;
var spr_latch_valid: bool = false;

fn ppu_capture_sprites(into_next: bool) {
    let base: i64 = ((io_ports[0x04] as i64) & 0x3F) << 9;
    let first: i64 = io_ports[0x05] as i64;
    var count: i64 = io_ports[0x06] as i64; if count > 128 { count = 128; }
    for i in count {
        let ea: i64 = base + ((first + i) & 127) * 4;
        let w: i64 = (mem[ea] as i64) | ((mem[ea + 1] as i64) << 8);
        if into_next { spr_next[i * 3] = w; spr_next[i * 3 + 1] = mem[ea + 2] as i64; spr_next[i * 3 + 2] = mem[ea + 3] as i64; }
        else { spr_latch[i * 3] = w; spr_latch[i * 3 + 1] = mem[ea + 2] as i64; spr_latch[i * 3 + 2] = mem[ea + 3] as i64; }
    }
    if into_next { spr_next_n = count; } else { spr_latch_n = count; }
}
fn ppu_promote_sprites() {
    for i in spr_next_n * 3 { spr_latch[i] = spr_next[i]; }
    spr_latch_n = spr_next_n;
    spr_latch_valid = true;
}

fn ppu_sprite_line(y: i64) {
    for i in 224 { spr_any_on[i] = false; spr_front_on[i] = false; }
    if !spr_latch_valid { ppu_capture_sprites(false); spr_latch_valid = true; }
    let count: i64 = spr_latch_n;
    let dc: i64 = io_ports[0x00] as i64;
    var used: i64 = 0;
    var n: i64 = 0;
    while n < count && used < 32 {
        let w: i64 = spr_latch[n * 3];
        let sy: i64 = spr_latch[n * 3 + 1];
        let sx: i64 = spr_latch[n * 3 + 2];
        n += 1;
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
