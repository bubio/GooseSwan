#!/bin/sh
# The GooseSwan regression battery: unit self-tests, the 8086
# corpus baseline, WSHWTest Test All, the framebuffer goldens and
# the full WSTimingTest harvest (400 passed / 7 failed is the
# fitted baseline; the 7 are the documented deferred set).
# Expects the corpus (scripts/fetch_corpus.sh) and the test ROMs
# (scripts/fetch_test_roms.sh) to be in place, and tools/sst built.
set -e
cd "$(dirname "$0")/.."
SST=./tools/sst
for t in ppu_test apu_test eeprom_test; do
    out=$($SST $t)
    echo "$out"
    echo "$out" | grep -q ", 0 failed" || { echo "FAIL: $t" >&2; exit 1; }
done
total=$($SST tests/data/*.json | awk -F'[= ]' '/total=/{t+=$3; p+=$5} END {print p"/"t}')
echo "8086 corpus: $total"
[ "$total" = "634406/646000" ] || { echo "FAIL: corpus baseline moved ($total)" >&2; exit 1; }
$SST ws tests/roms/WSHWTest.wsc m1 > /tmp/testall.txt 2>&1
if grep -qi failed /tmp/testall.txt; then echo "FAIL: WSHWTest Test All" >&2; exit 1; fi
echo "WSHWTest Test All: pass"
sh ./tests/fb_check.sh
pass=0
fail=0
for n in $(seq 0 28); do
    out=$($SST ws tests/roms/WSTimingTest.ws "pg$n")
    final=$(printf '%s\n' "$out" | awk '/^final screen/{buf=""; next} {buf=buf $0 "\n"} END{printf "%s", buf}')
    p=$(printf '%s' "$final" | grep -oE ':[.]+[0-9]+[.]+[0-9]+[.]+o[.]' | wc -l)
    f=$(printf '%s' "$final" | grep -oE ':[.]+[0-9]+[.]+[0-9]+[.]+x[.]' | wc -l)
    pass=$((pass + p))
    fail=$((fail + f))
done
echo "WSTimingTest harvest: $pass passed, $fail failed"
[ "$pass" = 400 ] && [ "$fail" = 7 ] || { echo "FAIL: timing baseline moved" >&2; exit 1; }
echo "all tests passed"
