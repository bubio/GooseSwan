#!/bin/sh
# Check the core on its own (scripts/check_core.sh) and lint every entry
# point (scripts/lint.sh: no goose check warnings), then build the
# harness (tools/sst) and the frontend (app/gooswan).
# With --test, also run the full regression battery. Expects the
# Goose compiler (pinned release, see the workflow) on PATH.
set -e
cd "$(dirname "$0")/.."
sh ./scripts/check_core.sh
sh ./scripts/lint.sh
goose build tools/sst.goose
goose build app/gooswan.goose
if [ "$1" = "--test" ]; then sh ./scripts/run_tests.sh; fi
