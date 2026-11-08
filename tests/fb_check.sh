#!/bin/sh
# Framebuffer golden-hash battery: render fixed test-ROM screens and
# compare the fbhash values against goldens (recorded 2026-11-07 with
# BG+sprites rendering in place). Catches rendering regressions.
# Usage: tests/fb_check.sh [path-to-sst-binary]
cd "$(dirname "$0")/.." || exit 1
SST=${1:-./tools/sst}
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
# m1 stops the first time Test All returns to the menu (tools/runner.goose),
# so the golden is the menu screen after one complete, failure-free pass.
check tests/roms/WSHWTest.wsc m1 -341173188216746214
check tests/roms/WSHWTest.wsc m7 -8074856431574525435
check tests/roms/WSTimingTest.ws pg0 -7186274187880256422
rm -f framebuffer.ppm
exit $fail
