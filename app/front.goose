// Gooswan frontend: an SDL3 window through Goose's gfx package,
// keyboard input, and the core's audio stream played through the
// audio package's mixer. The machine is reached only through the core
// package's API (core/core.goose).
//
// Keys: Y pad (left) = WASD, X pad (right) = arrow keys, A = X,
// B = Z, Start = Return, Escape closes. Saves land next to the ROM
// (<rom>.sav / .eep / .iep) on exit and every 600 frames.
//
// Vertical games (cartridge footer flag) are shown as Swanium does:
// the picture turned 90 degrees counter-clockwise in a 144x224-shaped
// window, and both pads' directions turned with it (pad key n acts as
// key n+1), so the arrow keys and WASD keep matching the screen.
//
// Usage: gooswan <rom> [frames] [check]
//   frames > 0 stops after that many frames (smoke runs); "check"
//   then reads the presented screen back and compares it against
//   the framebuffer (needs a GPU device; lavapipe works).

let front_vs = embed_shader("vert", """
    layout(location = 0) out vec2 v_uv;
    void main() {
        vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
        v_uv = vec2(p.x, 1.0 - p.y);
        gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    }
    """);

let front_fs = embed_shader("frag", """
    layout(set = 2, binding = 0) uniform sampler2D tex;
    layout(location = 0) in vec2 v_uv;
    layout(location = 0) out vec4 o;
    void main() { o = texture(tex, v_uv); }
    """);

// Streaming audio output (hostaudio.c): one SDL3 stream fed every frame.
extern fn hostaudio_open(rate: i64) -> bool;
extern fn hostaudio_push(pcm: const i16[:]);
extern fn hostaudio_queued() -> i64;
extern fn hostaudio_close();

// Pacing. The machine runs at ~75.47 Hz but presenting is tied to the
// display (gfx::frame() returns at ~60 Hz on a 60 Hz screen even with
// NO_VSYNC), so emulation is decoupled from presentation: before each
// present, run as many machine frames as keep the audio queue at least
// FRONT_AUDIO_AHEAD stereo frames deep (four machine frames, 318 each at
// 24 kHz, ~53 ms). The device clock thus sets the speed and the stream
// never runs dry. Without audio, a timer plays that role.
let FRONT_AUDIO_AHEAD: i64 = 1272;
let FRONT_MAX_RUN:     i64 = 8; // machine frames per present, at most

var front_audio_ok: bool = false;

fn front_parse(s: const u8[:]) -> i64 {
    var v: i64 = 0;
    for i in s.len { let c: i64 = s[i]; if c >= 48 && c <= 57 { v = v * 10 + (c - 48); } }
    return v;
}

// Turn both pads one step clockwise (Y1->Y2->Y3->Y4->Y1, same for X),
// compensating for the counter-clockwise screen of vertical games.
fn front_rotate_pads(k: i64) -> i64 {
    let y:  i64 = k & 15;
    let x:  i64 = (k >> 4) & 15;
    let y2: i64 = ((y << 1) | (y >> 3)) & 15;
    let x2: i64 = ((x << 1) | (x >> 3)) & 15;
    return (k & ~255) | y2 | (x2 << 4);
}

fn front_keys(vertical: bool) -> i64 {
    var k: i64 = 0;
    if gfx::key_down("W") { k |= core::KEY_Y1; }
    if gfx::key_down("D") { k |= core::KEY_Y2; }
    if gfx::key_down("S") { k |= core::KEY_Y3; }
    if gfx::key_down("A") { k |= core::KEY_Y4; }
    if gfx::key_down("Up") { k |= core::KEY_X1; }
    if gfx::key_down("Right") { k |= core::KEY_X2; }
    if gfx::key_down("Down") { k |= core::KEY_X3; }
    if gfx::key_down("Left") { k |= core::KEY_X4; }
    if gfx::key_down("Return") { k |= core::KEY_START; }
    if gfx::key_down("X") { k |= core::KEY_A; }
    if gfx::key_down("Z") { k |= core::KEY_B; }
    return if vertical { front_rotate_pads(k) } else { k };
}

// Append this frame's samples to the stream, right after the previous
// frame's, so playback is continuous.
fn front_audio_pump() {
    if !front_audio_ok { core::audio_clear(); return; }
    var pcm: i16[>..] = [];
    for i in core::audio_len() { pcm.push(core::audio_sample(i) as! i16); }
    core::audio_clear();
    hostaudio_push(pcm[..]);
}

fn front_main() {
    let argv = args();
    if argv.len < 2 { print("usage: gooswan <rom> [frames] [check]"); exit(2); }
    let path = argv[1];
    var max_frames: i64 = 0;
    if argv.len > 2 { max_frames = front_parse(argv[2]); }
    var check: bool = false;
    if argv.len > 3 && argv[3] == "check" { check = true; }
    var image: u8[>..] = [];
    guard read_file(path, image) else { print("cannot read ", path); exit(1); }
    core::power_on(image);
    load_saves(path);
    sync_rtc_to_host();
    core::set_audio(true);
    let vertical = core::is_vertical();
    // displayed picture size: 224x144, or 144x224 turned for vertical games
    let tw: i64 = if vertical { 144 } else { 224 };
    let th: i64 = if vertical { 224 } else { 144 };
    if !gfx::open("Gooswan", tw * 3, th * 3, gfx::NO_VSYNC | gfx::WINDOW_RESIZABLE) { print("gfx: ", gfx::error()); exit(3); }
    let tex = gfx::texture2d(tw, th);
    let smp = gfx::sampler(gfx::NEAREST, gfx::CLAMP);
    let pipe = gfx::pipeline(front_vs, front_fs);
    front_audio_ok = hostaudio_open(core::AUDIO_RATE);
    if !front_audio_ok { print("audio: no output device (continuing silently)"); }
    var rgba: u8[129024] = [0; 129024];
    let period: f64 = (core::FRAME_CYCLES as f64) / core::CPU_HZ;
    var next_t:   f64  = gfx::time() + period;
    var frame_no: i64  = 0;
    var running:  bool = true;
    while running && gfx::frame() {
        if gfx::key_pressed("Escape") { running = false; }
        let keys = front_keys(vertical);
        var ran: i64 = 0;
        while running && ran < FRONT_MAX_RUN {
            if front_audio_ok {
                if hostaudio_queued() >= FRONT_AUDIO_AHEAD { break; }
            } else {
                let now: f64 = gfx::time();
                if now < next_t { break; }
                next_t += period;
                if now - next_t > 0.25 { next_t = now + period; }
            }
            if !core::run_frame(keys) { print("unsupported opcode ", core::fault_op(), " at cs:ip ", core::fault_cs(), ":", core::fault_ip()); running = false; }
            front_audio_pump();
            ran += 1;
            frame_no += 1;
            if frame_no % 600 == 0 { save_saves(path); }
            if max_frames > 0 && frame_no >= max_frames { running = false; }
        }
        if ran == 0 { sleep_ms(1); }   // nothing due: yield instead of spinning
        // convert only when the machine advanced; otherwise redraw the last picture
        if ran > 0 { for sy in 144 { for sx in 224 {
            let c: i64 = core::fb[sy * 224 + sx];
            // counter-clockwise for vertical games: (sx, sy) -> (sy, 223 - sx)
            let d: i64 = if vertical { ((223 - sx) * 144 + sy) * 4 } else { (sy * 224 + sx) * 4 };
            rgba[d] = (((c >> 8) & 15) * 17) as! u8;
            rgba[d + 1] = (((c >> 4) & 15) * 17) as! u8;
            rgba[d + 2] = ((c & 15) * 17) as! u8;
            rgba[d + 3] = 255;
        } } }
        gfx::update_texture(tex, rgba[..]);
        gfx::begin_screen(float4 { 0.0, 0.0, 0.0, 1.0 });
        gfx::bind(pipe);
        gfx::bind_texture(gfx::FRAGMENT, 0, tex, smp);
        gfx::draw(3);
        gfx::end_pass();
    }
    if check {
        gfx::frame();
        let px = gfx::read_pixels(gfx::screen());
        var bad: i64 = 0;
        let ww: i64 = tw * 3;
        if px.len == ww * th * 3 * 4 {
            for y in th { for x in tw {
                let si: i64 = ((y * 3 + 1) * ww + (x * 3 + 1)) * 4;
                let di: i64 = (y * tw + x) * 4;
                if px[si] != rgba[di] || px[si + 1] != rgba[di + 1] || px[si + 2] != rgba[di + 2] { bad += 1; }
            } }
        } else { bad = -1; }
        print("frontcheck: mismatches=", bad, " of 32256 after ", frame_no, " frames");
        save_saves(path);
        hostaudio_close();
        gfx::close();
        if bad != 0 { exit(1); }
        return;
    }
    save_saves(path);
    hostaudio_close();
    gfx::close();
}
