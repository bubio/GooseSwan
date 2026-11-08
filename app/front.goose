// Gooswan frontend: an SDL3 window through Goose's gfx package,
// keyboard input, and the core's audio stream played through the
// audio package's mixer. The machine is reached only through the core
// package's API (core/core.goose).
//
// Keys: Y pad (left) = WASD, X pad (right) = arrow keys, A = X,
// B = Z, Start = Return, Escape closes. Saves land next to the ROM
// (<rom>.sav / .eep / .iep) on exit and every 600 frames.
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

var front_snd: audio::Sound[>..] = [];
var front_vox: audio::Voice[>..] = [];
var front_audio_ok: bool = false;

fn front_parse(s: const u8[:]) -> i64 {
    var v: i64 = 0;
    for i in s.len { let c: i64 = s[i] as i64; if c >= 48 && c <= 57 { v = v * 10 + (c - 48); } }
    return v;
}

fn front_keys() -> i64 {
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
    return k;
}

fn front_audio_pump() {
    // retire finished voices (releasing their sounds), then queue
    // this frame's samples as one short sound
    var ns: audio::Sound[>..] = [];
    var nv: audio::Voice[>..] = [];
    for i in front_vox.len {
        if audio::playing(front_vox[i]) { ns.push(front_snd[i]); nv.push(front_vox[i]); }
        else { audio::release_sound(front_snd[i]); }
    }
    front_snd = copy(ns); front_vox = copy(nv);
    if !front_audio_ok { core::audio_clear(); return; }
    var pcm: f32[>..] = [];
    for i in core::audio_len() { pcm.push((core::audio_sample(i) as f32) / 32768.0); }
    core::audio_clear();
    if pcm.len == 0 { return; }
    let snd = audio::create_sound(pcm, core::AUDIO_RATE as! i32, 2);
    if snd.id == 0 { return; }
    let vox = audio::play(snd);
    front_snd.push(snd); front_vox.push(vox);
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
    if !gfx::open("Gooswan", 672, 432, gfx::NO_VSYNC | gfx::WINDOW_RESIZABLE) { print("gfx: ", gfx::error()); exit(3); }
    let tex = gfx::texture2d(224, 144);
    let smp = gfx::sampler(gfx::NEAREST, gfx::CLAMP);
    let pipe = gfx::pipeline(front_vs, front_fs);
    front_audio_ok = audio::open(48000);
    if !front_audio_ok { print("audio: ", audio::error(), " (continuing silently)"); }
    var rgba: u8[129024] = [0; 129024];
    let period: f64 = (core::FRAME_CYCLES as f64) / (core::CPU_HZ as f64);
    var next_t: f64 = gfx::time() + period;
    var frame_no: i64 = 0;
    var running: bool = true;
    while running && gfx::frame() {
        if gfx::key_pressed("Escape") { running = false; }
        if !core::run_frame(front_keys()) { print("unsupported opcode ", core::fault_op(), " at cs:ip ", core::fault_cs(), ":", core::fault_ip()); running = false; }
        for i in 32256 {
            let c: i64 = core::fb[i] as i64;
            rgba[i * 4] = (((c >> 8) & 15) * 17) as! u8;
            rgba[i * 4 + 1] = (((c >> 4) & 15) * 17) as! u8;
            rgba[i * 4 + 2] = ((c & 15) * 17) as! u8;
            rgba[i * 4 + 3] = 255;
        }
        gfx::update_texture(tex, rgba[..]);
        gfx::begin_screen(float4 { 0.0, 0.0, 0.0, 1.0 });
        gfx::bind(pipe);
        gfx::bind_texture(gfx::FRAGMENT, 0, tex, smp);
        gfx::draw(3);
        gfx::end_pass();
        front_audio_pump();
        frame_no += 1;
        if frame_no % 600 == 0 { save_saves(path); }
        if max_frames > 0 && frame_no >= max_frames { running = false; }
        let now: f64 = gfx::time();
        if next_t > now { let ms: i64 = ((next_t - now) * 1000.0) as i64; if ms > 0 { sleep_ms(ms); } }
        next_t += period;
        if gfx::time() - next_t > 0.25 { next_t = gfx::time() + period; }
    }
    if check {
        gfx::frame();
        let px = gfx::read_pixels(gfx::screen());
        var bad: i64 = 0;
        if px.len == 672 * 432 * 4 {
            for y in 144 { for x in 224 {
                let si: i64 = ((y * 3 + 1) * 672 + (x * 3 + 1)) * 4;
                let di: i64 = (y * 224 + x) * 4;
                if px[si] != rgba[di] || px[si + 1] != rgba[di + 1] || px[si + 2] != rgba[di + 2] { bad += 1; }
            } }
        } else { bad = -1; }
        print("frontcheck: mismatches=", bad, " of 32256 after ", frame_no, " frames");
        save_saves(path);
        audio::close();
        gfx::close();
        if bad != 0 { exit(1); }
        return;
    }
    save_saves(path);
    audio::close();
    gfx::close();
}
