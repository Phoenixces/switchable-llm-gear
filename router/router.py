#!/usr/bin/env python3
"""
switchable-llm-gear/router.py

A fixed-URL routing proxy for Claude Code.

Point Claude Code at it via:
    export ANTHROPIC_BASE_URL=http://127.0.0.1:9000

The router forwards Anthropic Messages API traffic to ONE of two backends,
chosen by live mutable state guarded by a lock:

  - "provider": an Anthropic-shaped gateway (remote), reached via x-api-key.
  - "local":    a locally-managed vllm-mlx server serving an MLX model.

Because the URL Claude Code talks to never changes, you can hot-swap the
backend model mid-session (POST /switch) without restarting Claude Code.

Standard library only. macOS, Python 3.9+.
"""

import atexit
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "..", "config", "config.json")
CATALOG_PATH = os.path.join(HERE, "catalog.json")
STATE_PATH = os.path.join(HERE, "..", "run", "state.json")
VLLM_LOG = os.path.join(HERE, "..", "run", "vllm.log")
VLLM_LOG_OLD = os.path.join(HERE, "..", "run", "vllm.log.1")

# Timeouts (seconds)
SWITCH_HEALTH_TIMEOUT = 600      # explicit /switch may download GBs on first pull
LAZY_HEALTH_TIMEOUT = 120        # passthrough lazy-start expects an already-cached model
HEALTH_POLL_INTERVAL = 1.0

# Hop-by-hop headers we must not blindly copy through a proxy.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

# ---------------------------------------------------------------------------
# Config / catalog loading
# ---------------------------------------------------------------------------


def _load_json(path):
    with open(path, "r") as f:
        return json.load(f)


CONFIG = _load_json(CONFIG_PATH)
CATALOG = _load_json(CATALOG_PATH)

PROVIDER_BASE_URL = CONFIG["provider_base_url"].rstrip("/") + "/"  # ensure trailing slash
PROVIDER_AUTH_TOKEN = CONFIG["provider_auth_token"]
ANTHROPIC_VERSION = CONFIG.get("anthropic_version", "2023-06-01")
VLLM_BIN = CONFIG["vllm_bin"]
HF_CACHE = CONFIG["hf_cache"]
VLLM_PORT = int(CONFIG["vllm_port"])
ROUTER_PORT = int(CONFIG["router_port"])
DEFAULT_TARGET = CONFIG["default_target"]

VLLM_BASE = "http://127.0.0.1:%d" % VLLM_PORT


# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------


def local_ids():
    return [e["id"] for e in CATALOG.get("local", [])]


def provider_ids():
    return [e["id"] for e in CATALOG.get("provider", [])]


def provider_entries_by_tier(tier):
    """Provider catalog entries whose tier matches, preserving catalog order."""
    return [e for e in CATALOG.get("provider", []) if e.get("tier") == tier]


def hf_cache_dirname(model_id):
    """HuggingFace hub cache dir naming: models--<org>--<name>."""
    return "models--" + model_id.replace("/", "--")


def local_cached(model_id):
    """True if the model appears present in the HF hub cache."""
    return os.path.isdir(os.path.join(HF_CACHE, hf_cache_dirname(model_id)))


def catalog_with_cached():
    """Return a copy of the catalog with each local entry annotated 'cached'.

    Also exposes 'local_installed': the subset of local entries where
    cached==True (same per-entry object shape), so callers can show only
    models actually present in the HF cache. 'local' keeps the full list.
    """
    out = {"provider": list(CATALOG.get("provider", []))}
    locals_out = []
    for e in CATALOG.get("local", []):
        e2 = dict(e)
        e2["cached"] = local_cached(e["id"])
        locals_out.append(e2)
    out["local"] = locals_out
    out["local_installed"] = [dict(e) for e in locals_out if e.get("cached")]
    return out


# ---------------------------------------------------------------------------
# Active-target state (persisted + in-memory, lock-guarded)
# ---------------------------------------------------------------------------

_state_lock = threading.Lock()
_active = None  # {"kind": "local"|"provider", "model_id": "<id>"}


def _valid_target(kind, model_id):
    if kind == "local":
        return model_id in local_ids()
    if kind == "provider":
        return model_id in provider_ids()
    return False


def load_state():
    """Load persisted state; fall back to config.default_target. Validate."""
    global _active
    target = None
    if os.path.exists(STATE_PATH):
        try:
            target = _load_json(STATE_PATH)
        except Exception as e:
            sys.stderr.write("[router] failed to read state.json: %s\n" % e)
            target = None
    if not target or not _valid_target(target.get("kind"), target.get("model_id")):
        target = dict(DEFAULT_TARGET)
    _active = {"kind": target["kind"], "model_id": target["model_id"]}


def persist_state(target):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(target, f)
    os.replace(tmp, STATE_PATH)


def get_active():
    with _state_lock:
        return dict(_active)


def set_active(kind, model_id):
    global _active
    with _state_lock:
        _active = {"kind": kind, "model_id": model_id}
        persist_state(_active)


# ---------------------------------------------------------------------------
# Session tracking (in-memory, from injected X-Gear-Session header)
# ---------------------------------------------------------------------------

SESSION_TTL_SECS = 45  # prune sessions unseen for longer than this. No explicit
                       # close signal exists, so a closed session drops after it
                       # goes silent this long. Kept short so the count reflects
                       # reality fast; a live-but-idle session reappears on its
                       # next request. Gauge polls /state every 5s.

_sessions_lock = threading.Lock()
SESSIONS = {}  # {session_id: {"cwd": <cwd>, "last_seen": <epoch seconds>}}


def touch_session(header_value):
    """Record a passthrough request from a session.

    header_value is the raw 'X-Gear-Session' value: '<session_id>|<cwd>'.
    Split on the FIRST '|' only (cwd may itself contain '|'). Ignore blanks.
    """
    if not header_value:
        return
    session_id, sep, cwd = header_value.partition("|")
    session_id = session_id.strip()
    if not session_id:
        return
    with _sessions_lock:
        SESSIONS[session_id] = {"cwd": cwd, "last_seen": time.time()}


def sessions_snapshot():
    """Prune stale sessions, then return a list sorted most-recent first."""
    now = time.time()
    with _sessions_lock:
        stale = [sid for sid, s in SESSIONS.items()
                 if now - s["last_seen"] > SESSION_TTL_SECS]
        for sid in stale:
            del SESSIONS[sid]
        items = [
            {
                "session_id": sid,
                "cwd": s["cwd"],
                "last_seen": s["last_seen"],
                "age_secs": int(now - s["last_seen"]),
            }
            for sid, s in SESSIONS.items()
        ]
    items.sort(key=lambda x: x["last_seen"], reverse=True)
    return items


# ---------------------------------------------------------------------------
# vllm-mlx lifecycle
# ---------------------------------------------------------------------------

_vllm_lock = threading.Lock()          # serialize start/stop
_vllm_proc = None                      # subprocess.Popen or None
_vllm_current_model = None             # model id the running proc serves, or None


def _rotate_vllm_log():
    """Rotate vllm.log -> vllm.log.1 so each launch starts a fresh log."""
    try:
        if os.path.exists(VLLM_LOG):
            os.replace(VLLM_LOG, VLLM_LOG_OLD)
    except Exception as e:
        sys.stderr.write("[router] log rotate failed: %s\n" % e)


def _proc_alive():
    return _vllm_proc is not None and _vllm_proc.poll() is None


def stop_vllm():
    """Terminate the vllm subprocess and clear tracking state."""
    global _vllm_proc, _vllm_current_model
    with _vllm_lock:
        if _vllm_proc is not None:
            if _vllm_proc.poll() is None:
                sys.stderr.write("[router] stopping vllm (model=%s)\n" % _vllm_current_model)
                try:
                    _vllm_proc.terminate()
                    try:
                        _vllm_proc.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        sys.stderr.write("[router] vllm did not stop; killing\n")
                        _vllm_proc.kill()
                        _vllm_proc.wait(timeout=10)
                except Exception as e:
                    sys.stderr.write("[router] error stopping vllm: %s\n" % e)
            _vllm_proc = None
        _vllm_current_model = None


def start_vllm(model_id):
    """
    Ensure vllm-mlx is running the requested model. If a different model is
    running, stop it first. No-op if the requested model is already up.
    """
    global _vllm_proc, _vllm_current_model
    with _vllm_lock:
        if _proc_alive() and _vllm_current_model == model_id:
            return  # already serving the right model

        # Wrong model (or dead proc) -> tear down before (re)launch.
        if _vllm_proc is not None:
            if _vllm_proc.poll() is None:
                sys.stderr.write(
                    "[router] switching vllm model %s -> %s\n"
                    % (_vllm_current_model, model_id)
                )
                try:
                    _vllm_proc.terminate()
                    try:
                        _vllm_proc.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        _vllm_proc.kill()
                        _vllm_proc.wait(timeout=10)
                except Exception as e:
                    sys.stderr.write("[router] error stopping old vllm: %s\n" % e)
            _vllm_proc = None
            _vllm_current_model = None

        _rotate_vllm_log()

        env = dict(os.environ)
        env["VLLM_MLX_ENABLE_THINKING"] = "false"

        cmd = [
            VLLM_BIN, "serve", model_id,
            "--port", str(VLLM_PORT),
            "--max-tokens", "16384",
            "--kv-cache-quantization",
            "--cache-memory-percent", "0.35",
            "--prefill-step-size", "4096",
            "--stream-interval", "4",
            "--timeout", "600",
            "--enable-auto-tool-choice",
            "--tool-call-parser", "auto",
            "--tool-call-truncation-notice",
        ]
        sys.stderr.write("[router] launching vllm: %s\n" % " ".join(cmd))
        logf = open(VLLM_LOG, "ab", buffering=0)
        _vllm_proc = subprocess.Popen(
            cmd, stdout=logf, stderr=subprocess.STDOUT, env=env, close_fds=True
        )
        _vllm_current_model = model_id


def wait_healthy(timeout):
    """Poll vllm /health until the body reports 'healthy'. Return bool."""
    deadline = time.time() + timeout
    url = VLLM_BASE + "/health"
    while time.time() < deadline:
        # If the subprocess died, no point in waiting further.
        if not _proc_alive():
            sys.stderr.write("[router] vllm process exited before becoming healthy\n")
            return False
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                body = resp.read().decode("utf-8", "replace").lower()
                if "healthy" in body:
                    return True
        except Exception:
            pass  # not up yet
        time.sleep(HEALTH_POLL_INTERVAL)
    return False


def vllm_is_up():
    """Quick liveness/health check for /state reporting."""
    if not _proc_alive():
        return False
    try:
        with urllib.request.urlopen(VLLM_BASE + "/health", timeout=2) as resp:
            body = resp.read().decode("utf-8", "replace").lower()
            return "healthy" in body
    except Exception:
        return False


def ensure_local(model_id, timeout):
    """Make sure vllm is up and serving model_id; block until healthy or timeout."""
    start_vllm(model_id)
    return wait_healthy(timeout)


# ---------------------------------------------------------------------------
# Provider model-id mapping
# ---------------------------------------------------------------------------


def classify_tier(model_str):
    """Classify a model string into a provider tier by substring."""
    s = (model_str or "").lower()
    if "opus" in s:
        return "opus"
    if "sonnet" in s:
        return "sonnet"
    if "haiku" in s:
        return "haiku"
    return None


def map_provider_model(body_model, active_model_id):
    """
    Map whatever 'model' Claude Code sent to a concrete provider catalog id.

    Rules:
      1. If it already starts with "anthropic--", trust it and keep as-is.
      2. Otherwise classify its tier (opus/sonnet/haiku by substring):
         - if the active provider model_id is of that same tier, use it
           (respects the user's explicit selection within the tier);
         - else use the first catalog provider entry of that tier.
      3. If tier can't be determined or has no catalog entry, fall back to
         the active model_id.
    """
    if isinstance(body_model, str) and body_model.startswith("anthropic--"):
        return body_model

    tier = classify_tier(body_model)
    if tier:
        # Prefer the active selection if it matches the requested tier.
        active_entry = next(
            (e for e in CATALOG.get("provider", []) if e["id"] == active_model_id),
            None,
        )
        if active_entry and active_entry.get("tier") == tier:
            return active_model_id
        matches = provider_entries_by_tier(tier)
        if matches:
            return matches[0]["id"]

    return active_model_id


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "switchable-llm-gear/1.0"

    # ---- small helpers ----------------------------------------------------

    def _is_localhost(self):
        return self.client_address[0] in ("127.0.0.1", "::1", "localhost")

    def _send_json(self, code, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:
            pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def log_message(self, fmt, *args):
        # Quiet the default per-request access log; we log meaningful events to stderr.
        pass

    # ---- HTTP verbs -------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/state":
            return self._handle_state()
        if path == "/health":
            return self._send_json(200, {"ok": True})
        return self._handle_passthrough("GET")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/switch":
            return self._handle_switch()
        return self._handle_passthrough("POST")

    # Anthropic traffic can use other verbs; route them all through passthrough.
    def do_PUT(self):
        return self._handle_passthrough("PUT")

    def do_DELETE(self):
        return self._handle_passthrough("DELETE")

    def do_PATCH(self):
        return self._handle_passthrough("PATCH")

    # ---- control API ------------------------------------------------------

    def _handle_state(self):
        if not self._is_localhost():
            return self._send_json(403, {"error": "control API is localhost-only"})
        active = get_active()
        up = vllm_is_up()
        self._send_json(
            200,
            {
                "active": active,
                "vllm_up": up,
                "vllm_model": _vllm_current_model if up else None,
                "catalog": catalog_with_cached(),
                "sessions": sessions_snapshot(),
            },
        )

    def _handle_switch(self):
        if not self._is_localhost():
            return self._send_json(403, {"error": "control API is localhost-only"})
        try:
            body = self._read_body()
            req = json.loads(body.decode("utf-8")) if body else {}
        except Exception as e:
            return self._send_json(400, {"error": "invalid JSON body: %s" % e})

        kind = req.get("kind")
        model_id = req.get("model_id")
        if not _valid_target(kind, model_id):
            return self._send_json(
                400,
                {"error": "unknown %r model_id %r for that kind" % (kind, model_id)},
            )

        if kind == "local":
            # Persist selection first so passthrough sees it immediately, then
            # bring vllm up on that model and block until healthy.
            set_active(kind, model_id)
            ready = ensure_local(model_id, SWITCH_HEALTH_TIMEOUT)
            if not ready:
                return self._send_json(
                    504,
                    {
                        "ok": False,
                        "ready": False,
                        "error": "vllm did not become healthy in time",
                    },
                )
            return self._send_json(200, {"ok": True, "ready": True})

        # provider: no local server needed. Stop vllm to free RAM.
        set_active(kind, model_id)
        stop_vllm()
        return self._send_json(200, {"ok": True, "ready": True})

    # ---- Anthropic passthrough -------------------------------------------

    def _handle_passthrough(self, method):
        # Record session activity (launcher injects X-Gear-Session on /v1/* reqs).
        touch_session(self.headers.get("X-Gear-Session"))

        try:
            body = self._read_body()
        except Exception as e:
            return self._send_json(502, {"error": "failed reading request body: %s" % e})

        active = get_active()

        # Determine whether the client asked to stream (best-effort JSON parse).
        parsed = None
        is_json = False
        if body:
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "json" in ctype or body[:1] in (b"{", b"["):
                try:
                    parsed = json.loads(body.decode("utf-8"))
                    is_json = isinstance(parsed, dict)
                except Exception:
                    parsed = None
                    is_json = False

        client_wants_stream = bool(is_json and parsed.get("stream") is True)

        # Build target base URL + outbound headers, rewriting body model.
        try:
            if active["kind"] == "local":
                base, out_headers, out_body = self._prepare_local(
                    parsed, is_json, body, active
                )
            else:
                base, out_headers, out_body = self._prepare_provider(
                    parsed, is_json, body, active
                )
        except _UpstreamReady as e:
            # local start failed
            return self._send_json(502, {"error": str(e)})

        # Preserve path + query exactly.
        url = base.rstrip("/") + self.path

        req = urllib.request.Request(url, data=out_body if out_body else None, method=method)
        for k, v in out_headers.items():
            req.add_header(k, v)

        try:
            # No global read timeout: streaming responses can be long-lived.
            resp = urllib.request.urlopen(req, timeout=None)
        except urllib.error.HTTPError as e:
            # Upstream returned a non-2xx; relay its status + body faithfully.
            return self._relay_error_response(e)
        except Exception as e:
            sys.stderr.write("[router] upstream request failed: %s\n" % e)
            return self._send_json(
                502, {"error": {"type": "router_upstream_error", "message": str(e)}}
            )

        # Decide streaming vs buffered based on request flag OR response ctype.
        resp_ctype = (resp.headers.get("Content-Type") or "").lower()
        streaming = client_wants_stream or "text/event-stream" in resp_ctype

        if streaming:
            self._stream_response(resp)
        else:
            self._buffer_response(resp)

    def _prepare_local(self, parsed, is_json, body, active):
        """Prepare a request to the local vllm server. Lazy-starts vllm."""
        model_id = active["model_id"]
        # Lazy-start: ensure vllm is up on the active model (cached => fast).
        if not (_proc_alive() and _vllm_current_model == model_id and vllm_is_up()):
            ok = ensure_local(model_id, LAZY_HEALTH_TIMEOUT)
            if not ok:
                raise _UpstreamReady(
                    "local model %s not ready within %ds" % (model_id, LAZY_HEALTH_TIMEOUT)
                )

        # Rewrite body "model" -> active local HF id.
        out_body = body
        if is_json:
            parsed = dict(parsed)
            parsed["model"] = model_id
            out_body = json.dumps(parsed).encode("utf-8")

        # vllm needs no auth. Strip inbound auth; do not send any.
        headers = self._forward_headers(strip_auth=True, set_provider_auth=False)
        if is_json:
            headers["Content-Type"] = "application/json"
        return VLLM_BASE, headers, out_body

    def _prepare_provider(self, parsed, is_json, body, active):
        """Prepare a request to the remote provider gateway."""
        out_body = body
        if is_json:
            parsed = dict(parsed)
            parsed["model"] = map_provider_model(parsed.get("model"), active["model_id"])
            out_body = json.dumps(parsed).encode("utf-8")

        headers = self._forward_headers(strip_auth=True, set_provider_auth=True)
        headers["Content-Type"] = "application/json"
        headers["anthropic-version"] = ANTHROPIC_VERSION
        return PROVIDER_BASE_URL, headers, out_body

    def _forward_headers(self, strip_auth, set_provider_auth):
        """
        Build outbound headers from inbound ones, dropping hop-by-hop and
        (optionally) inbound auth. Host/Content-Length are recomputed by urllib.
        """
        out = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in HOP_BY_HOP:
                continue
            if lk in ("host", "content-length"):
                continue
            # Router-internal header; never forward upstream.
            if lk == "x-gear-session":
                continue
            if strip_auth and lk in ("authorization", "x-api-key"):
                continue
            out[k] = v
        if set_provider_auth:
            out["x-api-key"] = PROVIDER_AUTH_TOKEN
        return out

    # ---- response relays --------------------------------------------------

    def _copy_response_headers(self, resp, streaming):
        """Copy upstream response headers, dropping hop-by-hop as appropriate."""
        for k, v in resp.headers.items():
            lk = k.lower()
            if lk in HOP_BY_HOP:
                continue
            # When streaming we chunk ourselves and don't know length up-front.
            if streaming and lk == "content-length":
                continue
            self.send_header(k, v)

    def _stream_response(self, resp):
        """Stream the upstream response body to the client without buffering."""
        try:
            self.send_response(resp.status)
            self._copy_response_headers(resp, streaming=True)
            # We use chunked transfer since we don't have a Content-Length.
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                # HTTP/1.1 chunked framing: <hexlen>\r\n<data>\r\n
                self.wfile.write(b"%X\r\n" % len(chunk))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")  # terminating chunk
            self.wfile.flush()
        except Exception as e:
            sys.stderr.write("[router] streaming relay error: %s\n" % e)
        finally:
            try:
                resp.close()
            except Exception:
                pass

    def _buffer_response(self, resp):
        """Buffer a non-streaming upstream response and relay it."""
        try:
            data = resp.read()
            self.send_response(resp.status)
            self._copy_response_headers(resp, streaming=False)
            # Ensure a correct Content-Length regardless of upstream framing.
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data:
                self.wfile.write(data)
                self.wfile.flush()
        except Exception as e:
            sys.stderr.write("[router] buffered relay error: %s\n" % e)
        finally:
            try:
                resp.close()
            except Exception:
                pass

    def _relay_error_response(self, http_error):
        """Relay an upstream HTTPError (non-2xx) status + body to the client."""
        try:
            data = http_error.read() or b""
        except Exception:
            data = b""
        sys.stderr.write(
            "[router] upstream HTTP %s for %s\n" % (http_error.code, self.path)
        )
        try:
            self.send_response(http_error.code)
            ctype = None
            try:
                ctype = http_error.headers.get("Content-Type")
            except Exception:
                pass
            self.send_header("Content-Type", ctype or "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data:
                self.wfile.write(data)
                self.wfile.flush()
        except Exception as e:
            sys.stderr.write("[router] error relaying upstream error: %s\n" % e)


class _UpstreamReady(Exception):
    """Raised internally when a local backend fails to become ready."""
    pass


# ---------------------------------------------------------------------------
# Signal / exit handling
# ---------------------------------------------------------------------------


def _install_shutdown_hooks():
    atexit.register(stop_vllm)

    def _handler(signum, frame):
        sys.stderr.write("[router] signal %d received; shutting down\n" % signum)
        stop_vllm()
        # Re-raise default behavior: exit.
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    load_state()
    _install_shutdown_hooks()

    active = get_active()
    server = ThreadingHTTPServer(("127.0.0.1", ROUTER_PORT), Handler)
    server.daemon_threads = True

    print(
        "[router] listening on http://127.0.0.1:%d  active target: kind=%s model_id=%s"
        % (ROUTER_PORT, active["kind"], active["model_id"]),
        flush=True,
    )
    print(
        "[router] point Claude Code at: export ANTHROPIC_BASE_URL=http://127.0.0.1:%d"
        % ROUTER_PORT,
        flush=True,
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_vllm()
        server.server_close()


if __name__ == "__main__":
    main()
