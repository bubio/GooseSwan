# 2026-11-08 — Frontend audio: streaming output, audio-paced emulation

The frontend now streams audio through one SDL3 audio stream (app/hostaudio.c)
and runs as many machine frames per present as keep that stream ~4 frames
(53 ms) ahead, so the device clock sets the speed. This fixed choppy music.

## Cause (measured; the core was not the bottleneck)

- Core speed: `run_frame` with audio on takes 0.5 ms on average, 6 ms worst
  case (FF4, Clock Tower, Makaimura, Last Alive, Wizardry; 1500 frames each).
  The budget is 13.25 ms.
- `gfx::frame()` returns at about 60 Hz on a 60 Hz display, even with
  NO_VSYNC. The loop ran one machine frame per present, so the machine ran at
  60 fps instead of 75.47: 1510 frames took 25.4 s, not 20.0 s, and only 80%
  of the needed audio was produced.
- The audio package only plays separate voices, and a new voice starts at the
  next device block. Playing one ~13 ms sound per frame left gaps and
  overlaps at every frame boundary.

## Change

- `app/hostaudio.c` + `app/gooswan.build`: open / push s16 / queued / close
  on an SDL3 device stream (24 kHz stereo; SDL resamples to the device).
  Goose ships no SDL3 headers, so the C file declares the few SDL3 functions
  it uses. libSDL3 is already linked in through the gfx package.
- Main loop: before each present, run frames while queued < 1272 stereo
  frames (at most 8 per present). If no frame is due, sleep 1 ms and redraw
  the last picture. When no audio device is available, a timer decides when
  a frame is due.

| Alternative | Why not |
|---|---|
| Keep the audio package and add buffering | It cannot append to a playing sound. Voice starts are quantised to device blocks. |
| Pace frames with a timer (as before) | Presenting is capped at 60 Hz, so one frame per present can never reach 75.47 Hz. |

## Verification (macOS arm64, Goose v2026.3)

- lint: no warnings. `gooswan <ff4> 1510 check`: 0 mismatches, 20.9 s wall
  (the old build took 25.4 s).
- A temporary probe of queue depth per present over 1510 frames: lowest
  714 stereo frames (~30 ms), and the queue never ran dry.
- Not run locally: the Linux CI smoke with the dummy audio driver.

## Non-goals

- Dynamic rate control (tiny resampling to track drift). The device clock
  already paces the emulation.
