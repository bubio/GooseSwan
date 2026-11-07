# 2026-11-08 — M5 first slice: the audio sample stream

## What landed

The APU now generates the actual output stream, following
Swanium's apu output model (`audio_emit` in apu.goose):

- One stereo sample per 128 CPU cycles (24 kHz), accumulated in
  apu_tick and appended to `aud_buf` — but only while
  `aud_enabled` is set, so the headless test runners pay nothing.
- Wave mix: per enabled channel, sample x volume nibbles per side,
  the sum scaled by 32; channel 4's sample is the noise DAC level
  under the same gate as the mixer readback ports; channel 2 is
  skipped in voice mode.
- Voice: port 0x89 writes (CPU and SDMA alike, via the new
  `voice_feed`) feed a 2-tap moving-average reconstruction filter;
  the level is routed per port 0x94 (full / half / mute per side)
  and scaled by 64. The filter resets while voice mode is off.
- HyperVoice sums into the same domain via the existing
  `hv_output` (pinned in the SDMA slice).
- Output control (port 0x91): bit 7 set = stereo with i16 clamp;
  otherwise the mono speaker sum shifted by bits 1-2, clamped.
  (One divergence from Swanium: its wave-only fast path keeps
  mixing a disabled channel's stale sample; the general step path
  — and this implementation — contributes only enabled channels,
  matching the 0x96-0x9B readback.)

Bulk-tick note: samples within one apu_tick call all use the
channel state at the end of the call. The runner calls apu_tick
per instruction (deltas of a few dozen cycles), so in practice
each 128-cycle block is sampled at its own end state.

## Headless verification

- `sst apu_test` 83/83: 15 new checks pin the cadence (one sample
  per 128 cycles, remainder carried), the wave mix value (7200 =
  15 x 15 x 32), the speaker sum and shift, the voice low-pass
  (127 -> 63 -> 127) and its x64 routed value (8128), HyperVoice
  in the stream (16384) and the mono clamp at 32767.
- Real-ROM smoke: `sst ws WSHWTest.wsc m8 wav` writes a valid
  24 kHz stereo s16 WAV (1,045,237 samples) whose levels move with
  the mixer test's four tones (values consistent with the mix
  formula under the speaker shift the test selects). The m6 sweep
  suite's WAV is all silence, correctly: that test measures pitch
  registers and never raises a channel volume.
- Full regression unchanged: corpora at baseline (8086
  634406/646000, V20 2980747/3125000), ppu_test 39/39,
  eeprom_test 25/25, WSTimingTest 400/407 full harvest, WSHWTest
  Test All 0 failures, fb_check 3/3.

## Next in M5
The SDL3 window/input frontend (compile-checked here, run on a
real machine), save-data persistence (SRAM/EEPROM to files), and
then a real game end to end.
