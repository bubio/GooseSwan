#!/bin/sh
# Fetch and build FluBBa's WonderSwan test ROMs into tests/roms/.
# The sources are pinned by commit so CI builds exactly the ROMs
# the framebuffer goldens in tests/fb_check.sh were recorded with.
# Needs: curl, unzip, nasm (installed by the workflow).
# WSCpuTest is deliberately not built here: its suites run for
# minutes each, so CI skips them (the local tests/roms ROM is the
# v0.7.1 release binary).
set -e
cd "$(dirname "$0")/.."
mkdir -p tests/roms
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
WSHWTEST_SHA=34e33d5bfaaabb8b09fa5a557e409efe9fbfd979
WSTIMING_SHA=025e606fc3b6615160ffdae485d992ffcad0c024
fetch() {
    if [ ! -d "tests/roms/$3" ]; then
        curl -fsSL -o "$tmp/$1.zip" "https://codeload.github.com/FluBBaOfWard/$1/zip/$2"
        rm -rf "$tmp/$1-$2"
        unzip -q "$tmp/$1.zip" -d "$tmp"
        mv "$tmp/$1-$2" "tests/roms/$3"
    fi
}
fetch WSHWTest "$WSHWTEST_SHA" WSHWTest-src
fetch WSTimingTest "$WSTIMING_SHA" WSTimingTest-src
(cd tests/roms/WSHWTest-src && nasm -f bin -o ../WSHWTest.wsc WSHWTest.asm)
(cd tests/roms/WSTimingTest-src && nasm -f bin -o ../WSTimingTest.ws timingtest.asm)
echo "test ROMs ready"
