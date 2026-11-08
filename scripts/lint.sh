#!/bin/sh
# Goose has no linter or formatter; its checker's warnings are the lint.
# Fail if any entry point (app, tools, the core on its own) has one.
set -e
cd "$(dirname "$0")/.."
status=0
warn_all=""
for entry in core/core.goose app/gooswan.goose tools/sst.goose; do
    out=$(goose check "$entry" 2>&1) || { echo "$out" >&2; exit 1; }
    warn_all="$warn_all$(printf '%s\n' "$out" | grep ': warning:' | sed "s|^$PWD/||" || true)
"
done
warn=$(printf '%s' "$warn_all" | grep . | sort -u || true)
if [ -n "$warn" ]; then echo "$warn" >&2; status=1; fi
[ $status -eq 0 ] && echo "lint: no warnings" || echo "lint: warnings above (goose check)" >&2
exit $status
