# 2026-11-07 — PPU backgrounds + framebuffer harness (M3, slice 1)

## Result

- The PPU now renders both background layers (SCR1/SCR2) into a
  224×144 framebuffer of RGB444 values, following Swanium's ppu
  module: tile-map entries (tile/palette/bank/hflip/vflip), scroll
  wrap at 256×256, mono shade-pool palettes (ports 0x1C–0x3F) with
  the palettes 0–3/8–11 colour-0 opacity exception, colour palette
  RAM at WRAM 0xFE00, the SCR2 window (inside/outside), 2bpp tiles
  at 0x2000, 4bpp tiles at 0x4000 (planar and packed), and the
  colour-mode tile-bank bit.
- Lines render as they complete in `ws_line_events`, from live
  ports/RAM, so mid-frame register changes land on the right lines.
- Harness: `./src/sst ws <rom> <suite> fb` prints `fbhash=` (djb2-xor
  over the framebuffer) at the end of the run and writes
  `framebuffer.ppm` (P6, RGB444 expanded by ×17 per channel).

## Verification

- **Synthetic self-test** (`./src/sst ppu_test`, new): 24
  hand-computed pixel assertions across three scenes (mono palettes
  + transparency + scroll + hflip; SCR2 window inside/outside;
  colour RAM + colour transparency/backdrop + bank bit + 4bpp
  packed) — **24/24 pass**.
- **WSHWTest Test All end screen renders as readable text** matching
  the BG-map readout ("IO Registers", "Sound Noise Values", the
  noise-mode list, "Done."), and the hash is deterministic across
  runs (928216367990215109 twice).
- **WSHWTest Test Windows** renders its expected picture: the small
  tile patch the test draws at map rows 3–6 / cols 12–15 with the
  horizontal SCR2-window band through it.
- No regressions: both corpora exactly at baseline
  (8086 634,406/646,000; V20 2,980,747/3,125,000); WSHWTest Test All
  still passes; WSTimingTest spot pages (0 and 28) unchanged.

## Not yet done

- **Sprites** (attribute table, priority vs SCR2, sprite window,
  32-per-line limit) — the next PPU slice.
- LCD icon/segment port semantics and the "LCD off" state are not
  modelled (display enable is DISP_CTRL layer bits only).
- Golden-hash regression set: hashes are printed but not yet stored
  as goldens for a fixed battery of screens; worth adding once
  sprites land and the picture is complete.

## Next

Sprites slice, then a stored golden-hash battery over the test ROMs'
screens (WSCpuTest results, WSHWTest Test All/windows, WSTimingTest
pages).
