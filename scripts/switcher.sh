#!/bin/bash
# switcher.sh — front door: launch Claude Code routed through the gear router.
#
# Run this instead of `cclocal`. It guarantees the router proxy is up (via
# ensure-up.sh) and then launches Claude Code pointed at the router on
# 127.0.0.1:<router_port>. The router — not Claude — decides which backend
# (local vllm-mlx or remote gateway) each request goes to, and injects the real
# provider auth itself, so we deliberately never hand Claude the real token.
#
# This mirrors the reference run.sh env array + hardening flags, changing only
# the base URL (-> router) and the auth (-> a dummy, since the router auths).
#
# bash 3.2 compatible (macOS): no associative arrays, no ${x,,}.
set -euo pipefail

# --- Resolve our own directory + sibling scripts / config ---
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/../config/config.json"

# MCP config is reused from the reference project (sibling of this repo).
MCP_CONFIG="$DIR/../../claude-code-local-llm/mcp-local.json"

if ! command -v claude >/dev/null 2>&1; then
    echo "ERROR: Claude Code CLI ('claude') not found on PATH." >&2
    exit 1
fi

# --- Read router_port via python3 (jq may be absent). ---
ROUTER_PORT=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get("router_port", 9000))
' "$CONFIG")
ROUTER_PORT="${ROUTER_PORT:-9000}"

# --- Guarantee the router is running (idempotent, never fails the caller). ---
bash "$DIR/ensure-up.sh"

# The router listens here; Claude Code talks only to this address.
BASE_URL="http://127.0.0.1:$ROUTER_PORT"

# Placeholder model id. The router remaps every request to the active target's
# real model, so this value only needs to be a plausible Claude alias that
# Claude Code accepts for its Opus/Sonnet/Haiku slots.
MODEL="claude-sonnet-latest"

# Per-request output cap. Matches run.sh: generous enough that a whole-file
# Write/Edit (serialized into one tool-use JSON) isn't truncated mid-content.
CC_OUTPUT_TOKENS=8192

# --- Session id for router-side session tracking. Prefer a real Claude session
# --- id if the environment exposes one; otherwise generate a stable-per-launch
# --- id from PID + epoch. bash 3.2 safe.
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
    SESSION_ID="gear-$$-$(date +%s)"
fi

# --- Inject the session header the router reads on each passthrough request.
# --- Claude Code forwards ANTHROPIC_CUSTOM_HEADERS (newline-separated
# --- "Name: value" pairs) on every Anthropic API request. Extend, don't
# --- clobber, if the caller already set it.
_GEAR_SESSION_HEADER="X-Gear-Session: ${SESSION_ID}|${PWD}"
if [ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ]; then
    ANTHROPIC_CUSTOM_HEADERS="${ANTHROPIC_CUSTOM_HEADERS}
${_GEAR_SESSION_HEADER}"
else
    ANTHROPIC_CUSTOM_HEADERS="${_GEAR_SESSION_HEADER}"
fi

# --- Environment for Claude Code (mirrors run.sh's CLAUDE_ENV). ---
# ANTHROPIC_API_KEY is a dummy: the router injects the real provider_auth_token
# itself, so the real UUID never reaches the `claude` process.
CLAUDE_ENV=(
    "ANTHROPIC_BASE_URL=$BASE_URL"
    "ANTHROPIC_API_KEY=not-needed"
    "ANTHROPIC_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL"
    "CLAUDE_CODE_SUBAGENT_MODEL=$MODEL"
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS=$CC_OUTPUT_TOKENS"
    "CLAUDE_CODE_ATTRIBUTION_HEADER=0"
    "DISABLE_PROMPT_CACHING=1"
    "DISABLE_AUTOUPDATER=1"
    "DISABLE_TELEMETRY=1"
    "DISABLE_ERROR_REPORTING=1"
    "DISABLE_NON_ESSENTIAL_MODEL_CALLS=1"
    "ANTHROPIC_CUSTOM_HEADERS=$ANTHROPIC_CUSTOM_HEADERS"
)

# Proactive guidance so the token-capped local models write big files in parts
# instead of one oversized (and silently truncated) tool call. Same text as run.sh.
_WRITE_IN_PARTS_GUIDANCE="When creating or substantially editing a file longer than ~150 lines, do NOT emit it in a single Write/Edit tool call. First create the file with an initial section, then append each remaining section with separate, smaller Write/Edit calls. This local model's output is token-capped; an oversized single tool call is truncated and silently dropped."

CLAUDE_FLAGS=(
    --strict-mcp-config
    --mcp-config "$MCP_CONFIG"
    --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
    # Pre-allow the same 8 built-in tools so auto mode never makes its
    # model-based safety-classifier call (a slow local model can't service it
    # in time). Tool set stays scoped to these 8 via --tools above.
    --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
    --append-system-prompt "$_WRITE_IN_PARTS_GUIDANCE"
    # Inline --settings wins last, overriding any ANTHROPIC_BASE_URL/AUTH_TOKEN
    # baked into ~/.claude/settings.json (settings.json env loads after shell
    # env, so `env -u` alone is not enough). Pins everything at the router and a
    # blank auth token — the router supplies the real provider credentials.
    --settings "{\"env\":{\"ANTHROPIC_BASE_URL\":\"$BASE_URL\",\"ANTHROPIC_AUTH_TOKEN\":\"\",\"ANTHROPIC_API_KEY\":\"not-needed\",\"ANTHROPIC_MODEL\":\"$MODEL\",\"ANTHROPIC_DEFAULT_OPUS_MODEL\":\"$MODEL\",\"ANTHROPIC_DEFAULT_SONNET_MODEL\":\"$MODEL\",\"ANTHROPIC_DEFAULT_HAIKU_MODEL\":\"$MODEL\"}}"
)

# --- Banner ---
echo ""
echo "  Routing through gear router on :$ROUTER_PORT"
echo "  Turn the gear to switch models."
echo ""

# --- Open the floating gauge (detached) so local+provider switching is available.
# --- Skip if it's already running. GEAR_NO_UI=1 suppresses it.
GEAR_APP="$DIR/../gear/build/Gear.app"
if [ "${GEAR_NO_UI:-}" != "1" ]; then
    if ! pgrep -f "Gear.app/Contents/MacOS/Gear" >/dev/null 2>&1; then
        if [ -d "$GEAR_APP" ]; then
            open "$GEAR_APP" 2>/dev/null || true
        else
            echo "  (gauge not built — run: MAKE_APP=1 bash gear/build.sh)" >&2
        fi
    fi
fi

# --- Launch Claude Code. `env -u` strips any real creds from the parent shell ---
# --- so they cannot leak past the dummy values we set above.                  ---
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    "${CLAUDE_ENV[@]}" \
    claude "${CLAUDE_FLAGS[@]}"
