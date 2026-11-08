// GooseSwan core: the WonderSwan / WonderSwan Color machine as a Goose
// package (namespace `core`). Frontends and tools import it from their
// root file with `import core from "../core";`.
//
// The core does no file, window, audio-device or input-device I/O and
// imports nothing beyond std: a host hands it a ROM image, the pad
// state and save bytes, and reads back the framebuffer, the audio
// samples and the save bytes. The functions below are the API a
// frontend uses; the tools/ test harness additionally reaches into the
// modules white-box (same namespace).
namespace core;

import std;
import cpu;
import bus;
import eeprom;
import ppu;
import apu;

let SCREEN_W: i64 = 224;
let SCREEN_H: i64 = 144;
let AUDIO_RATE: i64 = 24000;           // stereo, interleaved L/R
let FRAME_CYCLES: i64 = 40704;         // 159 lines x 256 cycles
let CPU_HZ: i64 = 3072000;

// Pad bits for run_frame's `keys`.
let KEY_Y1: i64 = 1 << 0;
let KEY_Y2: i64 = 1 << 1;
let KEY_Y3: i64 = 1 << 2;
let KEY_Y4: i64 = 1 << 3;
let KEY_X1: i64 = 1 << 4;
let KEY_X2: i64 = 1 << 5;
let KEY_X3: i64 = 1 << 6;
let KEY_X4: i64 = 1 << 7;
let KEY_START: i64 = 1 << 9;
let KEY_A: i64 = 1 << 10;
let KEY_B: i64 = 1 << 11;

// Save media, for save_size / save_read / save_load.
let SAVE_SRAM: i64 = 0;
let SAVE_CART_EEPROM: i64 = 1;
let SAVE_INTERNAL_EEPROM: i64 = 2;

// Power on with a cartridge image (the whole .ws/.wsc file).
fn power_on(image: const u8[:]) {
    rom = [];
    for i in image.len { rom.push(image[i]); }
    ws_boot();
}

// Run one frame (FRAME_CYCLES) with the given pad state. Returns false
// when the CPU hit an opcode the core does not implement; the machine
// then stays stopped and fault_cs/fault_ip/fault_op describe it.
fn run_frame(keys: i64) -> bool {
    keys_state = keys;
    ws_frame();
    return !ws_unsupported;
}
fn fault_op() -> i64 { dbg_op }
fn fault_cs() -> i64 { seg[1] as i64 }
fn fault_ip() -> i64 { dbg_ip }

// The framebuffer is core::fb: SCREEN_W x SCREEN_H RGB444 values
// (0x0RGB), row-major, complete after every run_frame.
fn pixel(x: i64, y: i64) -> i64 { fb[y * SCREEN_W + x] as i64 }

// Audio: off by default (headless runs pay nothing). When on, each
// run_frame appends interleaved stereo i16-range samples at
// AUDIO_RATE to core::aud_buf; the host drains it with audio_clear().
fn set_audio(on: bool) { aud_enabled = on; }
fn audio_len() -> i64 { aud_buf.len }
fn audio_sample(i: i64) -> i64 { aud_buf[i] }
fn audio_clear() { aud_buf = []; }

// Save media. save_size is 0 when the cartridge has no such device.
fn save_size(kind: i64) -> i64 {
    if kind == SAVE_SRAM { return 65536; }
    if kind == SAVE_CART_EEPROM { return if cart_eeprom { ee_size[0] } else { 0 }; }
    if kind == SAVE_INTERNAL_EEPROM { return 2048; }
    return 0;
}
fn save_read(kind: i64, out: u8[>..]&) {
    let n: i64 = save_size(kind);
    for i in n {
        if kind == SAVE_SRAM { out.push(sram[i]); }
        else if kind == SAVE_CART_EEPROM { out.push(ee_data[i]); }
        else { out.push(ee_data[2048 + i]); }
    }
}
fn save_load(kind: i64, data: const u8[:]) {
    var n: i64 = save_size(kind);
    if data.len < n { n = data.len; }
    for i in n {
        if kind == SAVE_SRAM { sram[i] = data[i]; }
        else if kind == SAVE_CART_EEPROM { ee_data[i] = data[i]; }
        else { ee_data[2048 + i] = data[i]; }
    }
}
