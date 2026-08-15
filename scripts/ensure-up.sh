#!/bin/bash
# ensure-up.sh — idempotently bring the router proxy up.
#
# Starts router.py (listening on router_port from config.json) detached, unless
# it is already answering /health. Safe to call repeatedly and from a hook: it
# is fast, never blocks for long, and ALWAYS ends with `exit 0` so it can never
# fail the caller.
#
# bash 3.2 compatible (macOS): no associative arrays, no ${x,,}.
#
# NOTE: `set -e` is deliberately NOT used here — a hook must never be aborted by
# an intermediate non-zero status (e.g. a failed curl probe is expected).
set -uo pipefail

# --- Resolve our own directory (this is where router.py + config.json live) ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/../config/config.json"

# Read router_port via python3 (jq may be absent). Default to 9000 on any error.
ROUTER_PORT=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("router_port", 9000))
except Exception:
    print(9000)
' "$CONFIG" 2>/dev/null)
ROUTER_PORT="${ROUTER_PORT:-9000}"

HEALTH_URL="http://127.0.0.1:$ROUTER_PORT/health"

# --- Already up? Then we're done. ---
if curl -s -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "router already up on :$ROUTER_PORT"
    exit 0
fi

# --- Start the router detached so it outlives this script (and the hook). ---
echo "starting router on :$ROUTER_PORT ..."
nohup python3 "$DIR/../router/router.py" > "$DIR/../run/router.log" 2>&1 &
disown 2>/dev/null || true   # some bash builds lack `disown`; nohup covers us

# --- Poll up to ~15s for /health to come alive. ---
ready=0
i=0
while [[ $i -lt 15 ]]; do
    if curl -s -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [[ "$ready" -eq 1 ]]; then
    echo "router up on :$ROUTER_PORT"
else
    # Do not fail the caller — just report and let them proceed / retry.
    echo "router did not report healthy within 15s; see $DIR/../run/router.log" >&2
fi

# TODO(gear-app): once the gear UI binary exists, launch it here (detached,
# non-fatal if missing). Something like:
#   GEAR_BIN="$DIR/gear/gear"
#   if [[ -x "$GEAR_BIN" ]]; then
#       nohup "$GEAR_BIN" > "$DIR/gear.log" 2>&1 &
#       disown 2>/dev/null || true
#   fi
# Must NOT fail this script if the binary is absent — keep the `exit 0` below.

# Never error out the caller (this runs from a hook).
exit 0
