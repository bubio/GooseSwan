#!/bin/sh
# Keep the core a pure library: it must typecheck on its own (so it
# cannot lean on anything the app or the tools declare), import only
# its own modules and std, and do no host I/O (files, stdout, process).
set -e
cd "$(dirname "$0")/.."
out=$(goose check core/core.goose 2>&1) || { echo "$out" >&2; exit 1; }
bad=$(grep -nE '^import ' core/*.goose | grep -vE 'import (std|cpu|bus|eeprom|rtc|ppu|apu|ports);' || true)
io=$(grep -nE '\b(print|read_file|write_file|write_stdout|exit|args)\(' core/*.goose || true)
if [ -n "$bad$io" ]; then
    echo "core purity check failed:" >&2
    [ -n "$bad" ] && echo "$bad" >&2
    [ -n "$io" ] && echo "$io" >&2
    exit 1
fi
echo "core purity: ok"
