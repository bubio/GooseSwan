# 2026-11-07 — PPU sprites + golden hashes (M3, slice 2)

## Result

- Sprites are rendered, following Swanium's ppu model: the attribute
  table at `(port 0x04 & 0x3F) << 9`, `SPR_FIRST`/`SPR_COUNT` (ports
  0x05/0x06), entries in table order with **at most 32 sprites per
  scanline** (transparent entries still consume slots), X wrapping
  at 256, Y wrapping at 256, flips, palettes 8–15 (entry palette + 8).
- Compositing matches hardware priority: a priority-0 sprite shows
  over SCR1 but behind an opaque SCR2 pixel; a priority-1 sprite
  shows in front of SCR2; where SCR2 is transparent the first opaque
  sprite (either priority) wins. Sprites with the window attribute
  are hidden inside the sprite window (ports 0x0C–0x0F) when the
  sprite window is enabled.
- One documented simplification vs Swanium: the attribute table is
  sampled live per scanline instead of being latched per frame.

## Verification

- `sst ppu_test` grew a sprite scene (table order, palette offset,
  the palettes 8–11 colour-0 opacity exception vs palette 12
  transparency, both priority cases, sprite window hide/show, the
  32-per-line limit including the "slot 5 visible" control, and Y
  wrap): **39/39 pass** (24 background checks still green).
- **Golden-hash battery** (`tests/fb_check.sh`, new): WSHWTest Test
  All and Test Windows hashes are byte-identical to the pre-sprite
  run, proving sprite support did not disturb background-only
  screens; WSTimingTest page 0 added as a third golden. 3/3 OK.
- No regressions: both corpora exactly at baseline
  (8086 634,406/646,000; V20 2,980,747/3,125,000).

## Remaining PPU gaps

- LCD icon/segment port and the LCD-off state are unmodelled.
- Per-frame sprite latching (only matters for games that rewrite
  OAM mid-frame).
- No test ROM exercises sprites heavily; real-game smoke tests come
  with M5's frontend.

## Next

M3 is functionally complete for the test assets. Next candidates:
M4 leftovers (wave APU channels + DMA), or the serial TX timing
model that would close WSTimingTest's last two timing cases.
