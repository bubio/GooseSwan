#!/bin/sh
# Fetch NEC V20 native-mode corpora from SingleStepTests/v20 (v1_native).
# Usage: sh tests/fetch_v20.sh OPCODE ...
set -e
cd "$(dirname "$0")/.."
mkdir -p tests/data-v20
base="https://raw.githubusercontent.com/SingleStepTests/v20/main/v1_native"
for op in "$@"; do
  curl -fsSL --retry 3 --retry-delay 2 "$base/$op.json.gz" | gunzip > "tests/data-v20/$op.json"
  echo "fetched $op"
done
