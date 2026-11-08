// Differential probe: run a ROM on swanium-core for N frames with a key
// script and dump what Gooswan's `sst run` dumps, in the same formats.
// usage: swprobe <rom> <frames> <out_prefix> [keys] [mono|color]
//   keys = "f:bits,f:bits,..." (bits held from frame f until the next entry)
use std::io::Write;
use swanium_core::keypad::KeyState;
use swanium_core::model::HardwareModel;
use swanium_core::system::System;

fn fb_hash(fb: &[u16]) -> i64 {
    let mut h: i64 = 5381;
    for &p in fb { h = (h.wrapping_shl(5)).wrapping_add(h) ^ (p as i64); }
    h
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let rom = std::fs::read(&a[1]).expect("rom");
    let frames: usize = a[2].parse().unwrap();
    let out = &a[3];
    let mut script: Vec<(usize, u16)> = vec![];
    if a.len() > 4 && !a[4].is_empty() && a[4] != "-" {
        for e in a[4].split(',') { let mut it = e.split(':'); script.push((it.next().unwrap().parse().unwrap(), it.next().unwrap().parse().unwrap())); }
    }
    let mut sys = System::from_rom(rom);
    if a.len() > 5 { sys.set_model(if a[5] == "mono" { HardwareModel::Mono } else { HardwareModel::Color }); }
    let mut hashes = String::new();
    let mut keys: u16 = 0;
    let mut audio: Vec<i16> = vec![];
    for f in 0..frames {
        for &(sf, b) in &script { if sf == f { keys = b; } }
        sys.run_frame(KeyState::from_bits(keys));
        audio.extend_from_slice(sys.audio_samples());
        sys.clear_audio_samples();
        hashes.push_str(&format!("{}\n", fb_hash(sys.framebuffer())));
    }
    std::fs::write(format!("{out}.hashes"), hashes).unwrap();
    let fb = sys.framebuffer();
    let mut ppm = b"P6\n224 144\n255\n".to_vec();
    for &c in fb { ppm.push((((c >> 8) & 15) * 17) as u8); ppm.push((((c >> 4) & 15) * 17) as u8); ppm.push(((c & 15) * 17) as u8); }
    std::fs::write(format!("{out}.ppm"), ppm).unwrap();
    let mut ram = vec![0u8; 0x10000];
    for i in 0..0x10000u32 { ram[i as usize] = sys.read_memory_at(i); }
    std::fs::write(format!("{out}.ram"), &ram).unwrap();
    let io: Vec<u8> = (0..=255u8).map(|p| sys.bus().peek_io(p)).collect();
    std::fs::write(format!("{out}.io"), io).unwrap();
    let mut w = vec![];
    for s in &audio { w.extend_from_slice(&s.to_le_bytes()); }
    std::fs::write(format!("{out}.pcm"), w).unwrap();
    // screen text, same as Gooswan's ws_screen_text
    let base = ((sys.bus().peek_io(0x07) as usize) & 0x0F) << 11;
    let top = ((sys.bus().peek_io(0x11) as usize) >> 3) & 31;
    let mut txt = String::new();
    for y in 0..18 { let row = (top + y) & 31; for x in 0..28 { let c = ram[base + (row * 32 + x) * 2]; txt.push(if (32..127).contains(&c) { c as char } else { '.' }); } txt.push('\n'); }
    std::io::stdout().write_all(txt.as_bytes()).unwrap();
    println!("fbhash={}", fb_hash(fb));
}
