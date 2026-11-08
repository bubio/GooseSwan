#!/bin/sh
# asiekierka/ws-test-suite pass/fail-marker ROMs. Marker tables are
# Swanium's (crates/core/tests/public_roms.rs), each confirmed there
# against the ROM's source. The ROMs are not redistributable, so this
# is opt-in: WS_TEST_SUITE=<dir> (default: the shared fixture path);
# skipped when the directory is missing.
# Usage: tests/ws_test_suite.sh [path-to-sst-binary]
cd "$(dirname "$0")/.." || exit 1
SST=${1:-./tools/sst}
DIR=${WS_TEST_SUITE:-/Volumes/CrucialX6/roms/WonderSwan/Tests/ws-test-suite}
[ -d "$DIR" ] || { echo "ws-test-suite: $DIR not found, skipped"; exit 0; }
pass=0; fail=0
check() {
    out=$("$SST" mark "$DIR/$1" "$2" 2>&1)
    case "$out" in
        PASS*) pass=$((pass + 1)); echo "ok   $1: $(echo "$out" | head -1)" ;;
        *) fail=$((fail + 1)); echo "FAIL $1"; echo "$out" | sed 's/^/     /' | head -${VERBOSE_LINES:-6} ;;
    esac
}
check mono/cpu/80186_quirks.ws R0:0,1:0,2:0
check mono/cpu/prefixes.ws R0:0,1:0,2:0,3:0,4:0,5:0,6:0
check mono/soc/interrupts.ws R0:7,1:4
check mono/cpu/interrupt_timing.ws R0:0,1:0,2:0,3:0,4:0,5:0,6:0,7:0,8:0,9:0,10:0,11:0,12:0,13:0,14:0
check mono/rtc/mapper.ws P0:1,0:0,1:1,1:0,2:1,2:0,3:1,3:0,4:1,4:0,5:1,5:0,6:1,6:0,7:1,7:0,8:1,8:0,9:1,9:0,10:1,10:0,11:1,11:0,12:1,13:1,13:0
check mono/display/mono_palettes_writemask.ws R0:1,1:1,2:1,3:1,4:1,5:1,6:1,7:1,8:1,9:1,10:1,11:1,12:1,13:1,14:1,15:1
check mono/sound/quirks.ws R0:2,1:0,2:2,3:0,4:1,5:2,6:3,7:1,8:0
EEC=P1:0,2:1,2:0,3:1,3:0,3:3,4:1,4:0,4:3,5:1,5:0,6:0,7:0,8:0,8:1,8:2,8:3,8:4,8:5,8:6,8:7,8:8,8:9,8:10,8:11,10:0,10:1,10:2,10:3,10:4
check mono/eeprom/cartridge_1kbit.ws $EEC
check mono/eeprom/cartridge_16kbit.ws $EEC
check mono/eeprom/internal.ws P1:1,1:0,2:1,2:0,2:3,3:1,3:0,3:3,4:0,5:1,5:0,6:0,7:0,8:0,8:1,8:2,8:3,9:1,9:0,10:1,10:0,11:0,12:0,13:0,13:1,13:2,13:3
check color/dma/alignment_access.wsc R0:2,1:0,2:0,3:0,4:0,5:0
check color/dma/gdma_timing.wsc R0:0,1:0,2:0,3:0,4:0,5:0,6:0,7:0,8:0,9:0,10:0,11:0,12:0
check color/dma/sound_dma.wsc R0:1,1:1,2:0,3:0,4:0,5:0,6:0,7:4,8:4,9:1,10:0
check wonderful/libc/strlen.ws R0:1
check wonderful/libc/strchr.ws R0:4
check wonderful/libc/memset.ws R0:6,1:6
check wonderful/libc/memcmp.ws R0:4,1:4
check wonderful/libc/memcpy.ws R0:5,1:5,2:5,3:5
check wonderful/libc/memccpy.ws R0:7
check wonderful/libc/setjmp.ws R0:0,1:0,2:0
check wonderful/libc/initfini.ws R0:0
check wonderful/libc/malloc.ws R0:1,1:1,2:1,3:0
echo "ws-test-suite: $pass passed, $fail failed"
[ "$fail" = 0 ]
