// I/O port numbers (indices into io_ports and the p argument of
// port_rd / port_wr). Names follow Swanium (crates/core: ppu/mod.rs,
// ppu/palette.rs, apu/mod.rs constants and the register names in
// bus/mod.rs comments) so the two cores can be read side by side.
// Ports Swanium leaves unnamed take the WSdev wiki I/O port map's name
// (marked WSdev). A 16-bit register is named by its low port; its high
// byte is NAME + 1.
namespace core;

// ---- Display (0x00-0x3F) ----
let DISP_CTRL:       i64 = 0x00;  // layer / window enables
let DISP_CTRL_HI:    i64 = 0x01;  // background colour
let LCD_LINE:        i64 = 0x02;  // current scanline (read-only)
let DISP_INT_LINE:   i64 = 0x03;  // line-compare interrupt line (WSdev)
let SPR_BASE:        i64 = 0x04;  // sprite table base = (value & 0x3F) << 9
let SPR_FIRST:       i64 = 0x05;  // first sprite to process
let SPR_COUNT:       i64 = 0x06;  // sprites to process (0-128)
let MAP_BASE:        i64 = 0x07;  // SCR1 map (low nibble), SCR2 map (high nibble)
let SCR2_WINDOW_X1:  i64 = 0x08;
let SCR2_WINDOW_Y1:  i64 = 0x09;
let SCR2_WINDOW_X2:  i64 = 0x0A;
let SCR2_WINDOW_Y2:  i64 = 0x0B;
let SPR_WINDOW_X1:   i64 = 0x0C;
let SPR_WINDOW_Y1:   i64 = 0x0D;
let SPR_WINDOW_X2:   i64 = 0x0E;
let SPR_WINDOW_Y2:   i64 = 0x0F;
let SCR1_SCROLL_X:   i64 = 0x10;
let SCR1_SCROLL_Y:   i64 = 0x11;
let SCR2_SCROLL_X:   i64 = 0x12;
let SCR2_SCROLL_Y:   i64 = 0x13;
let SHADE_POOL_BASE: i64 = 0x1C;  // 0x1C-0x1F: mono shade LUT, two 4-bit shades per byte
let PALETTE_BASE:    i64 = 0x20;  // 0x20-0x3F: 16 mono palettes, 2 bytes each

// ---- DMA (colour, 0x40-0x52) ----
let GDMA_SRC_LO: i64 = 0x40;      // 16-bit offset (WSdev)
let GDMA_SRC_HI: i64 = 0x42;      // segment bits 19-16 (WSdev)
let GDMA_DST:    i64 = 0x44;      // 16-bit WRAM address (WSdev)
let GDMA_LEN:    i64 = 0x46;      // 16-bit byte count (WSdev)
let GDMA_CTRL:   i64 = 0x48;      // bit 7 start, bit 6 decrement (WSdev)
let SDMA_SRC_LO: i64 = 0x4A;      // (WSdev)
let SDMA_SRC_HI: i64 = 0x4C;      // (WSdev)
let SDMA_LEN_LO: i64 = 0x4E;      // remaining-length counter (WSdev)
let SDMA_LEN_HI: i64 = 0x50;      // (WSdev)
let SDMA_CTRL:   i64 = 0x52;      // enable / decrement / repeat / hold / rate

// ---- System control and HyperVoice (0x60-0x6B) ----
let VIDEO_MODE:     i64 = 0x60;   // bit 7 colour mode (Swanium; WSdev System Control 2)
let HV_DIRECT_L_LO: i64 = 0x64;   // signed 16-bit direct left output
let HV_DIRECT_L_HI: i64 = 0x65;
let HV_DIRECT_R_LO: i64 = 0x66;   // signed 16-bit direct right output
let HV_DIRECT_R_HI: i64 = 0x67;
let HV_DATA:        i64 = 0x69;   // 8-bit PCM data latch
let HV_CTRL:        i64 = 0x6A;   // enable / sample-extension mode / volume shift
let HV_CHAN_CTRL:   i64 = 0x6B;   // left/right routing

// ---- Sound (0x80-0x9E) ----
let SND_CH_PITCH:     i64 = 0x80; // 0x80-0x87: 4x 11-bit period (lo, hi)
let SND_CH_VOL:       i64 = 0x88; // 0x88-0x8B: 4x volume (L nibble, R nibble)
let SND_VOICE_SAMPLE: i64 = 0x89; // channel 2 volume doubles as the PCM voice sample
let SND_SWEEP_VALUE:  i64 = 0x8C; // signed sweep delta
let SND_SWEEP_TIME:   i64 = 0x8D; // sweep step count (5 bits)
let SND_NOISE:        i64 = 0x8E; // noise tap / enable / reset
let SND_WAVE_BASE:    i64 = 0x8F; // waveform base address >> 6
let SND_CTRL:         i64 = 0x90; // channel enables and voice / sweep / noise modes
let SND_OUTPUT_CTRL:  i64 = 0x91; // speaker/headphone output and speaker shift
let SND_RANDOM:       i64 = 0x92; // noise LFSR readback (lo, hi)
let SND_VOICE_VOL:    i64 = 0x94; // voice L/R volume
let SND_TEST:         i64 = 0x95;
let SND_CH_OUT_R:     i64 = 0x96; // mixer readback (lo, hi)
let SND_CH_OUT_L:     i64 = 0x98;
let SND_CH_OUT_LR:    i64 = 0x9A;
let SND_MAIN_VOL:     i64 = 0x9E; // speaker main volume (WSdev)

// ---- SoC: timers, interrupts, serial, keypad (0xA0-0xB7) ----
let SYSTEM_CTRL1:         i64 = 0xA0; // a.k.a. HW_FLAGS in Swanium
let TIMER_CTRL:           i64 = 0xA2; // (WSdev)
let HBLANK_TIMER_RELOAD:  i64 = 0xA4;  // (WSdev)
let VBLANK_TIMER_RELOAD:  i64 = 0xA6;  // (WSdev)
let HBLANK_TIMER_COUNTER: i64 = 0xA8;  // read-only (WSdev)
let VBLANK_TIMER_COUNTER: i64 = 0xAA;  // read-only (WSdev)
let INT_BASE:             i64 = 0xB0; // vector base (write) / INT_VECTOR (read)
let SERIAL_DATA:          i64 = 0xB1;
let INT_ENABLE:           i64 = 0xB2;
let SERIAL_STATUS:        i64 = 0xB3;
let INT_CAUSE:            i64 = 0xB4;
let KEYPAD:               i64 = 0xB5; // (WSdev Keypad Scan)
let INT_CAUSE_CLEAR:      i64 = 0xB6;
let INT_NMI_CTRL:         i64 = 0xB7;

// ---- Internal EEPROM (0xBA-0xBF) ----
let IEEP_DATA: i64 = 0xBA;        // (WSdev)
let IEEP_CMD:  i64 = 0xBC;        // (WSdev)
let IEEP_CTRL: i64 = 0xBE;        // control (write) / status (read) (WSdev)

// ---- Cartridge (0xC0-0xD5) ----
let BANK_LINEAR: i64 = 0xC0;      // (WSdev)
let BANK_RAM:    i64 = 0xC1;      // (WSdev)
let BANK_ROM0:   i64 = 0xC2;      // (WSdev)
let BANK_ROM1:   i64 = 0xC3;      // (WSdev)
let CEEP_DATA:   i64 = 0xC4;      // (WSdev)
let CEEP_CMD:    i64 = 0xC6;      // (WSdev)
let CEEP_CTRL:   i64 = 0xC8;      // control (write) / status (read) (WSdev)
let RTC_CMD:     i64 = 0xCA;      // command (write) / status (read) (WSdev)
let RTC_DATA:    i64 = 0xCB;      // (WSdev)
let BANK16_RAM:  i64 = 0xD0;      // 2003 mapper 16-bit banks (WSdev)
let BANK16_ROM0: i64 = 0xD2;      // (WSdev)
let BANK16_ROM1: i64 = 0xD4;      // (WSdev)
