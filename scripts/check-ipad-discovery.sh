#!/bin/bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
check="$repo/dist/ipad-checks/check-address"
if [[ ! -x "$check" ]]; then
  echo "Run npm run build:ipad first." >&2
  exit 1
fi
name="Shoebox (discovery-check-$$)"
log=$(mktemp)
/usr/bin/dns-sd -R "$name" _http._tcp local 7171 > "$log" 2>&1 &
publisher=$!
trap 'kill "$publisher" 2>/dev/null || true; wait "$publisher" 2>/dev/null || true; rm -f "$log"' EXIT
"$check" --discover "$name"
