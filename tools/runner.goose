// Headless ROM runner (sst ws <rom> ...): scripted input for the test
// ROMs' menus, screen-text readback, framebuffer/audio dumps.
namespace core;

// Run a WonderSwan ROM headlessly: reset to CS=FFFF:0000 (the linear
// window's modulo decode lands on the cartridge footer), raise VBlank
// once per frame of executed steps, and script a single A press so menu
// driven test ROMs start their "Test All". Stops when the screen shows
// "Ok" at least 7 times (one per suite), when the screen has been frozen
// for 600 frames (a failure stop inside the ROM), or at the frame cap.

fn run_ws(path: u8[:]) {
    guard read_file(path, rom) else { print("cannot read ", path); exit(1); }
    ws_boot();
    print("rom loaded: ", rom.len, " bytes");
    var screen: u8[1024] = [0; 1024];
    var last: u8[1024] = [0; 1024];
    var lastn: i64 = 0;
    var frozen: i64 = 0;
    var menu_idx: i64 = 0;
    let argv2 = args();
    var survey: bool = false;
    var page_target: i64 = 0;
    if argv2.len > 3 {
        let a3 = argv2[3];
        if a3.len > 0 && a3[a3.len - 1] == 43 { survey = true; }
        if a3 == "logic" || a3 == "logic+" { menu_idx = 1; }
        else if a3 == "arith" || a3 == "arith+" { menu_idx = 2; }
        else if a3 == "rot" || a3 == "rot+" { menu_idx = 3; }
        else if a3 == "misc" || a3 == "misc+" { menu_idx = 4; }
        else if a3 == "mul" || a3 == "mul+" { menu_idx = 5; }
        else if a3 == "div" || a3 == "div+" { menu_idx = 6; }
        else if a3 == "sdiv" || a3 == "sdiv+" { menu_idx = 7; }
        else if a3.len == 2 && a3[0] == 109 { menu_idx = (a3[1] as i64) - 48; }  // "m1".."m9": generic menu index (WSHWTest)
        else if a3.len >= 3 && a3[0] == 112 && a3[1] == 103 { page_target = (a3[2] as i64) - 48; if a3.len >= 4 { page_target = page_target * 10 + ((a3[3] as i64) - 48); } }  // "pgN": WSTimingTest page index
    }
    var skips: i64 = 0;
    var skip_hold: i64 = 0;
    var frame: i64 = 0;
    var done: bool = false;
    var dismiss: i64 = 0;
    // Menu-driven ROMs: remember the menu as it stands just before the A press;
    // once a test has run, coming back to that exact screen ends the run
    // (otherwise auto-dismiss would restart Test All forever).
    var menu: u8[1024] = [0; 1024];
    var menun: i64 = 0;
    var left_menu: bool = false;
    var prev_fail: bool = false;
    var page_done: i64 = 0;
    var page_hold: i64 = 0;
    var fb_dump: bool = false;
    if argv2.len > 4 && (argv2[4] == "fb" || argv2[4] == "fbwav") { fb_dump = true; }
    var wav_dump: bool = false;
    if argv2.len > 4 && (argv2[4] == "wav" || argv2[4] == "fbwav") { wav_dump = true; aud_enabled = true; }
    while frame < 2000000 && !done {
        keys_state = 0;
        if skip_hold > 0 { keys_state = 1 << 11; skip_hold -= 1; }
        if menu_idx > 0 {
            // tap X3 (down) menu_idx times, one tap per 4 frames, then A
            let rel: i64 = frame - 30;
            if rel >= 0 {
                let tap: i64 = rel / 4;
                if tap < menu_idx { if rel % 4 < 2 { keys_state = 1 << 6; } }
                else if rel - menu_idx * 4 < 4 { keys_state = 1 << 10; }
            }
        } else if frame >= 30 && frame < 45 { keys_state = 1 << 10; }  // hold A to pick "Test All"
        if dismiss > 0 { keys_state |= 1 << 10; dismiss -= 1; }  // auto-tap A to dismiss "press any key" HLT waits
        if page_hold > 0 { keys_state |= 1 << 5; page_hold -= 1; }  // WSTimingTest: X2 (right) advances the page
        ws_frame();
        if ws_unsupported { print("unsupported opcode ", dbg_op, " at cs:ip ", seg[1], ":", dbg_ip, " frame ", frame); let m = ws_screen_text(screen); write_stdout(screen[..m]); exit(1); }
        let n = ws_screen_text(screen);
        // Report every screen that shows "Failed" (the periodic dumps
        // below only sample one frame in 2000).
        var has_fail: bool = false;
        var fi: i64 = 0;
        while fi + 5 < n { if screen[fi] == 70 && screen[fi + 1] == 97 && screen[fi + 2] == 105 && screen[fi + 3] == 108 && screen[fi + 4] == 101 && screen[fi + 5] == 100 { has_fail = true; } fi += 1; }
        if has_fail && !prev_fail { print("failed screen at frame ", frame, ":"); write_stdout(screen[..n]); }
        prev_fail = has_fail;
        var at_menu: bool = menun == n;
        if at_menu { for i in n { if screen[i] != menu[i] { at_menu = false; } } }
        if menu_idx > 0 && frame == 29 + menu_idx * 4 { for i in n { menu[i] = screen[i]; } menun = n; }
        if menu_idx > 0 && frame > 40 + menu_idx * 4 { if !at_menu { left_menu = true; } else if left_menu { print("back at the menu at frame ", frame, " after ", ws_total, " instructions"); done = true; } }
        var same: bool = n == lastn;
        if same { for i in n { if screen[i] != last[i] { same = false; } } }
        if same { frozen += 1; } else { frozen = 0; for i in n { last[i] = screen[i]; } lastn = n; }
        if frozen == 200 && cpu_halted { dismiss = 6; }
        if page_target > 0 && frame > 60 && frozen == 90 && page_done < page_target { page_done += 1; page_hold = 4; frozen = 0; for i in n { last[i] = 0; } lastn = 0; }
        if survey && frozen >= 90 && skips < 40 { skips += 1; print("survey skip ", skips, " at frame ", frame, " after ", ws_total, " instructions; screen was:"); write_stdout(screen[..n]); skip_hold = 6; frozen = 0; for i in n { last[i] = 0; } lastn = 0; }
        else if frozen >= 600 { print("screen frozen for 600 frames at frame ", frame, " after ", ws_total, " instructions (waiting for a key: end of Test All or a failure stop)"); done = true; }
        else if frame % 2000 == 0 { print("frame ", frame, " oks=", count_ok(screen, n)); write_stdout(screen[..n]); }
        frame += 1;
    }
    print("final screen (frame ", frame, ", ", ws_total, " instructions):");
    print("state: cs:ip=", seg[1], ":", ip, " ax=", r[0], " bx=", r[2], " cx=", r[1], " dx=", r[3], " sp=", r[4], " bp=", r[5], " si=", r[6], " di=", r[7], " flags=", flags, " halted=", cpu_halted, " line=", (ws_cycles % 40704) / 256, " cause=", int_cause, " enable=", io_ports[0xB2], " scr_area=", io_ports[0x07], " p60=", io_ports[0x60], " p01raw=", io_ports[0x01], " p01rd=", port_rd(1));
    let m = ws_screen_text(screen);
    write_stdout(screen[..m]);
    if fb_dump { print("fbhash=", fb_hash()); fb_write_ppm(); print("framebuffer written to framebuffer.ppm"); }
    if wav_dump { wav_write(); print("audio written to audio.wav samples=", aud_buf.len / 2); }
}

fn ws_screen_text(buf: u8[:]) -> i64 {
    let mapbase: i64 = ((io_ports[0x07] as i64) & 0x0F) << 11;
    let top: i64 = ((io_ports[0x11] as i64) >> 3) & 31;
    var n: i64 = 0;
    for y in 18 {
        let row: i64 = (top + y) & 31;
        for x in 28 {
            let c = mem[mapbase + (row * 32 + x) * 2];
            buf[n] = if c >= 32 && c < 127 { c } else { 46 };  // '.' for non-printables
            n += 1;
        }
        buf[n] = 10; n += 1;
    }
    n
}

fn count_ok(buf: u8[:], n: i64) -> i64 {
    var cnt: i64 = 0;
    var i: i64 = 0;
    while i + 1 < n {
        if buf[i] == 79 && buf[i + 1] == 107 { cnt += 1; }  // "Ok"
        i += 1;
    }
    cnt
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


fn wav_write() {
    var w: u8[>..] = [];
    let data_bytes: i64 = aud_buf.len * 2;
    let riff = "RIFF"; for i in riff.len { w.push(riff[i]); }
    let chunk: i64 = 36 + data_bytes;
    w.push((chunk & 0xFF) as! u8); w.push(((chunk >> 8) & 0xFF) as! u8); w.push(((chunk >> 16) & 0xFF) as! u8); w.push(((chunk >> 24) & 0xFF) as! u8);
    let wave = "WAVE"; for i in wave.len { w.push(wave[i]); }
    let fmt = "fmt "; for i in fmt.len { w.push(fmt[i]); }
    w.push(16); w.push(0); w.push(0); w.push(0);
    w.push(1); w.push(0); w.push(2); w.push(0);
    w.push(0xC0); w.push(0x5D); w.push(0); w.push(0);
    w.push(0x80); w.push(0xBB); w.push(0); w.push(0);
    w.push(4); w.push(0); w.push(16); w.push(0);
    let data = "data"; for i in data.len { w.push(data[i]); }
    w.push((data_bytes & 0xFF) as! u8); w.push(((data_bytes >> 8) & 0xFF) as! u8); w.push(((data_bytes >> 16) & 0xFF) as! u8); w.push(((data_bytes >> 24) & 0xFF) as! u8);
    for i in aud_buf.len { let v: i64 = aud_buf[i]; w.push((v & 0xFF) as! u8); w.push(((v >> 8) & 0xFF) as! u8); }
    write_file("audio.wav", w);
}

// ---- ws-test-suite pass/fail markers (sst mark <rom> <spec>) ----
// asiekierka/ws-test-suite's common/test/pass_fail.h writes tile 5
// (pass) or 6 (fail) into screen_1 (WRAM 0x1800, 64-byte rows) at
// x = 27 - offset. spec lists the markers as "row:offset" pairs; a
// leading "R" means each pair is a range (offsets max..0 on that row),
// "P" that each pair is one position — the same tables Swanium's
// public_roms.rs keeps per ROM. Runs at most 120 frames, stopping as
// soon as every marker is written.
fn mark_parse(spec: const u8[:], out: i64[>..]&) {
    let ranges: bool = spec.len > 0 && spec[0] == 82;  // 'R'
    var i: i64 = 1;
    while i < spec.len {
        var row: i64 = 0; var off: i64 = 0;
        while i < spec.len && spec[i] != 58 { row = row * 10 + ((spec[i] as i64) - 48); i += 1; }
        i += 1;
        while i < spec.len && spec[i] != 44 { off = off * 10 + ((spec[i] as i64) - 48); i += 1; }
        i += 1;
        if ranges { var o: i64 = off; while o >= 0 { out.push(row); out.push(o); o -= 1; } }
        else { out.push(row); out.push(off); }
    }
}

fn run_mark(path: u8[:], spec: u8[:]) {
    guard read_file(path, rom) else { print("cannot read ", path); exit(1); }
    ws_boot();
    var pos: i64[>..] = [];
    mark_parse(spec, pos);
    let n: i64 = pos.len / 2;
    var got: i64[>..] = [];
    for k in n { got.push(0); }
    var frame: i64 = 0;
    var all: bool = false;
    while frame < 120 && !all {
        keys_state = 0;
        ws_frame();
        if ws_unsupported { print("FAIL unsupported opcode ", dbg_op, " at ", seg[1], ":", dbg_ip); exit(1); }
        all = true;
        for k in n {
            let v: i64 = mem[0x1800 + pos[k * 2] * 64 + (27 - pos[k * 2 + 1]) * 2] as i64;
            got[k] = v;
            if v != 5 && v != 6 { all = false; }
        }
        frame += 1;
    }
    var pass: i64 = 0; var fail: i64 = 0;
    for k in n { if got[k] == 5 { pass += 1; } else if got[k] == 6 { fail += 1; } }
    if pass == n { print("PASS ", pass, "/", n, " (frame ", frame, ")"); return; }
    print("FAIL ", pass, "/", n, " pass, ", fail, " fail, ", n - pass - fail, " unwritten (frame ", frame, ")");
    for k in n { if got[k] != 5 { print("  row ", pos[k * 2], " offset ", pos[k * 2 + 1], ": tile ", got[k]); } }
    var screen: u8[1024] = [0; 1024];
    let m = ws_screen_text(screen);
    write_stdout(screen[..m]);
}

// ---- Differential run (sst run <rom> <frames> <out> [keys] [mono|color]) ----
// Runs a fixed number of frames with a key script ("f:bits,..." — bits
// held from frame f on) and writes <out>.hashes (one framebuffer hash
// per frame), <out>.ppm, <out>.ram (WRAM 0x0000-0xFFFF) and <out>.pcm
// (s16le stereo 24 kHz) — the formats of the Swanium-side probe, so the
// two cores can be compared frame by frame.
var trace_frames: i64 = 0;  // sst run: print the CPU state at the end of the last N frames (GS_TRACE=N)

fn run_diff(path: u8[:], frames: i64, out: u8[:], script: u8[:], model: u8[:]) {
    var tv: u8[>..] = [];
    if env("GS_TRACE", tv) { for k in tv.len { trace_frames = trace_frames * 10 + ((tv[k] as i64) - 48); } }
    guard read_file(path, rom) else { print("cannot read ", path); exit(1); }
    if model == "mono" { model_forced = 0; } else if model == "color" { model_forced = 1; }
    ws_boot();
    aud_enabled = true;
    var sf: i64[>..] = []; var sb: i64[>..] = [];
    var i: i64 = 0;
    while i < script.len && script[0] != 45 {
        var f: i64 = 0; var b: i64 = 0;
        while i < script.len && script[i] != 58 { f = f * 10 + ((script[i] as i64) - 48); i += 1; }
        i += 1;
        while i < script.len && script[i] != 44 { b = b * 10 + ((script[i] as i64) - 48); i += 1; }
        i += 1;
        sf.push(f); sb.push(b);
    }
    var hashes: u8[>..] = [];
    var pcm: u8[>..] = [];
    var keys: i64 = 0;
    for fr in frames {
        for k in sf.len { if sf[k] == fr { keys = sb[k]; } }
        keys_state = keys;
        ws_frame();
        if ws_unsupported { print("unsupported opcode ", dbg_op, " at ", seg[1], ":", dbg_ip, " frame ", fr); break; }
        if trace_frames > 0 && fr >= frames - trace_frames { print("frame ", fr, " end cs:ip=", seg[1], ":", ip, " sp=", r[4], " halted=", cpu_halted, " cause=", int_cause, " en=", io_ports[0xB2], " if=", (flags >> 9) & 1, " line=", (ws_cycles % 40704) / 256);
            for k in 64 { let e: i64 = dbg_ring[(dbg_ring_pos + k) & 63]; print("  ", e >> 24, ":", (e >> 8) & 0xFFFF, " ", e & 0xFF); } }
        for k in aud_buf.len { let v: i64 = aud_buf[k]; pcm.push((v & 0xFF) as! u8); pcm.push(((v >> 8) & 0xFF) as! u8); }
        aud_buf = [];
        let line = str(fb_hash(), "\n");
        for k in line.len { hashes.push(line[k]); }
    }
    write_file(str(out, ".hashes"), hashes);
    write_file(str(out, ".pcm"), pcm);
    var ram: u8[>..] = [];
    for k in 65536 { ram.push(mem[k]); }
    write_file(str(out, ".ram"), ram);
    var ppm: u8[>..] = [];
    let hdr = "P6\n224 144\n255\n";
    for k in hdr.len { ppm.push(hdr[k]); }
    for k in 32256 { let c: i64 = fb[k] as i64; ppm.push((((c >> 8) & 15) * 17) as! u8); ppm.push((((c >> 4) & 15) * 17) as! u8); ppm.push(((c & 15) * 17) as! u8); }
    write_file(str(out, ".ppm"), ppm);
    var screen: u8[1024] = [0; 1024];
    let m = ws_screen_text(screen);
    write_stdout(screen[..m]);
    print("fbhash=", fb_hash());
}
