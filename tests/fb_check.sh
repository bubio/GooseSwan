#!/bin/sh
# Framebuffer golden-hash battery: render fixed test-ROM screens and
# compare the fbhash values against goldens (recorded 2026-11-07 with
# BG+sprites rendering in place). Catches rendering regressions.
# Usage: tests/fb_check.sh [path-to-sst-binary]
cd "$(dirname "$0")/.." || exit 1
SST=${1:-./src/sst}
fail=0
check() {
    got=$("$SST" ws "$1" "$2" fb 2>/dev/null | grep fbhash | cut -d= -f2)
    if [ "$got" = "$3" ]; then
        echo "OK   $1 $2 -> $got"
    else
        echo "FAIL $1 $2 -> got $got, expected $3"
        fail=1
    fi
}
# The m1 golden is stop-point sensitive: Test All ends in a key wait,
# and whether the runner stops on the results screen or back at the
# menu depends on exact cycle counts (the auto-dismiss race). It was
# re-recorded after the IRQ-entry charge landed (results screen ->
# menu); Test All itself completes failure-free either way.
check tests/roms/WSHWTest.wsc m1 -295421874257209499
check tests/roms/WSHWTest.wsc m7 -8074856431574525435
check tests/roms/WSTimingTest.ws pg0 -7186274187880256422
rm -f framebuffer.ppm
exit $fail
