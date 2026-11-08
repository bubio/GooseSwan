#!/bin/sh
# Package a built gooseswan binary into the distribution zip
# gooseswan-<platform>-<arch>.zip: the binary and README.md, no
# directory hierarchy (mirrors BubiBoyLite's packaging).
set -e
cd "$(dirname "$0")/.."
bin=$1
platform=$2
arch=$3
tmp=$(mktemp -d)
cp "$bin" "$tmp/gooseswan"
chmod +x "$tmp/gooseswan"
cp README.md "$tmp/README.md"
(cd "$tmp" && zip -q -X "gooseswan-$platform-$arch.zip" gooseswan README.md)
mv "$tmp/gooseswan-$platform-$arch.zip" .
rm -rf "$tmp"
echo "gooseswan-$platform-$arch.zip"
