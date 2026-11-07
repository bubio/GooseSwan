#!/bin/sh
# Fetch SingleStepTests 8086 v1 case files into tests/data/.
# Usage: tests/fetch_data.sh 89 01 C6 ...   (opcode bytes, hex)
set -e
cd "$(dirname "$0")/.."
mkdir -p tests/data
for op in "$@"; do
    f="tests/data/$op.json"
    if [ ! -f "$f" ]; then
        curl -fsSL -o "$f.gz" "https://raw.githubusercontent.com/SingleStepTests/8086/master/v1/$op.json.gz"
        gunzip -kf "$f.gz"
        echo "fetched $op"
    fi
done
