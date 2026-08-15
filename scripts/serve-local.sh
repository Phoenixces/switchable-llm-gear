#!/bin/bash
# serve-local.sh — launch vllm-mlx for a single model, in the foreground.
#
# Standalone helper for manual testing, or as a fallback target that the
# router can spawn. This is the local-server block of the reference
# run.sh extracted and simplified: no menu, no memory preflight, no Claude
# Code launch — just serve one model and block until Ctrl+C.
#
# Usage: serve-local.sh <hf_model_id> [port]
#   <hf_model_id>  HuggingFace MLX model id, e.g. mlx-community/gemma-4-e4b-it-4bit
#   [port]         Optional; defaults to vllm_port from config.json.
#
# bash 3.2 compatible (macOS): no associative arrays, no ${x,,}.
set -euo pipefail

# --- Resolve our own directory (macOS has no readlink -f; resolve manually) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../config/config.json"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: config.json not found at $CONFIG" >&2
    exit 1
fi

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
    echo "Usage: serve-local.sh <hf_model_id> [port]" >&2
    exit 1
fi

# --- Read config values via python3 (jq may be absent) ---
# A single python invocation prints the two fields we need, tab-separated,
# so the config is parsed exactly once.
_cfg=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print("%s\t%s" % (c.get("vllm_bin", ""), c.get("vllm_port", 8000)))
' "$CONFIG")
VLLM_BIN="${_cfg%%$'\t'*}"      # everything before the first tab
DEFAULT_PORT="${_cfg##*$'\t'}"  # everything after the last tab

# Second positional arg overrides the config default port.
PORT="${2:-$DEFAULT_PORT}"

if [[ -z "$VLLM_BIN" || ! -x "$VLLM_BIN" ]]; then
    echo "ERROR: vllm_bin not found or not executable: '$VLLM_BIN'" >&2
    echo "  (set \"vllm_bin\" in $CONFIG)" >&2
    exit 1
fi

echo "Starting vllm-mlx"
echo "  model: $MODEL"
echo "  port:  $PORT"
echo "  bin:   $VLLM_BIN"
echo ""

# --- Launch the server in the background so we can poll /health, then hand ---
# --- the foreground back to it via `wait` (Ctrl+C stops it).               ---
# Flags mirror run.sh's local-server block exactly.
VLLM_MLX_ENABLE_THINKING=false \
"$VLLM_BIN" serve "$MODEL" \
    --port "$PORT" \
    --max-tokens 16384 \
    --kv-cache-quantization \
    --cache-memory-percent 0.35 \
    --prefill-step-size 4096 \
    --stream-interval 4 \
    --timeout 600 \
    --enable-auto-tool-choice \
    --tool-call-parser auto \
    --tool-call-truncation-notice &
SERVER_PID=$!

# Stop the server if this script is interrupted or exits.
cleanup() {
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        echo "Stopping vllm-mlx (pid: $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# --- Poll /health until it reports "healthy", printing a live "waiting..." ---
printf "Waiting for server to become healthy"
while true; do
    if curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "healthy"; then
        printf "\n"
        echo "Server ready at http://127.0.0.1:$PORT — Ctrl+C to stop."
        break
    fi
    # Bail out early if the server process has already died.
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        printf "\n"
        echo "ERROR: vllm-mlx exited before becoming healthy." >&2
        exit 1
    fi
    printf " waiting..."
    sleep 2
done

# Leave the server running in the foreground; Ctrl+C triggers cleanup().
wait "$SERVER_PID"
