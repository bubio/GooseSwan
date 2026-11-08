#!/bin/sh
# Build the harness (src/sst) and the frontend (src/gooseswan).
# With --test, also run the full regression battery. Expects the
# Goose compiler (pinned release, see the workflow) on PATH.
set -e
cd "$(dirname "$0")/.."
goose build src/sst.goose
goose build src/gooseswan.goose
if [ "$1" = "--test" ]; then ./scripts/run_tests.sh; fi
