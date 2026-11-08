#!/bin/sh
# Package a built gooswan binary (gooswan, or gooswan.exe on Windows)
# into the distribution zip gooswan-<platform>-<arch>.zip: the binary
# and README.md, no directory hierarchy (mirrors BubiBoyLite's packaging).
set -e
cd "$(dirname "$0")/.."
bin=$1
platform=$2
arch=$3
name=$(basename "$bin")
tmp=$(mktemp -d)
cp "$bin" "$tmp/$name"
chmod +x "$tmp/$name"
cp README.md "$tmp/README.md"
(cd "$tmp" && zip -q -X "gooswan-$platform-$arch.zip" "$name" README.md)
mv "$tmp/gooswan-$platform-$arch.zip" .
rm -rf "$tmp"
echo "gooswan-$platform-$arch.zip"
