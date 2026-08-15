# RUN — using switchable-llm-gear

Step-by-step to switch Claude Code between **local** LLMs and **Claude provider**
models, live in one session.

---

## One-time setup

1. **Config** — copy template, fill in your gateway token + local paths:
   ```bash
   cp config/config.example.json config/config.json
   ```
   Edit `config/config.json`:
   - `provider_auth_token` — your gateway UUID
   - `vllm_bin` — absolute path to your `vllm-mlx` binary
   - `hf_cache` — HuggingFace cache dir (detects which local models are installed)

2. **Build the gauge**:
   ```bash
   MAKE_APP=1 bash gear/build.sh
   ```
   → produces `gear/build/Gear.app`.

3. **Shell alias** (already added to `~/.zshrc`):
   ```bash
   alias ccgear='bash .../switchable-llm-gear/scripts/switcher.sh'
   ```
   Open a new terminal (or `source ~/.zshrc`) to pick it up.

---

## Two ways to start Claude — you pick

| Command  | What you get |
|----------|--------------|
| `claude` | **Normal** Claude Code. No router, no gauge. Your usual session. |
| `ccgear` | **Switchable** session: routes through the gear router **and** opens the floating gauge, so you can hot-swap between local + Claude models. |

There is no auto-launch hook — switchable mode happens only when you type `ccgear`.

---

## Switchable session (`ccgear`)

### 1. Launch
```bash
ccgear
```
Starts the router on `:9000` (if not up), opens the gauge (if not already open), and
launches Claude Code routed at the router. Work in Claude normally — it starts on
`default_target` from your config.
> Suppress the gauge for one launch with `GEAR_NO_UI=1 ccgear` (router still routes).

### 2. Switch — pick from a dropdown
The gauge has two dropdowns on top (**Local ▾** / **Cloud ▾**) over a needle gauge;
the needle points at the active model.
- **To a Claude/cloud model:** open **Cloud ▾**, pick one:
  `Claude 4.5 Haiku · 4.5 Sonnet · 4.5 Opus · 4.6 Sonnet · 4.6 Opus · 4.7 Opus · 4.8 Opus`
  → switch is instant, needle sweeps right (red half).
- **To a local model:** open **Local ▾**, pick one (only installed models show, e.g.
  `Gemma-4-E4B`, `GLM-4.7-Flash`)
  → needle sweeps left (blue half). **First switch to a given local model boots
  vllm-mlx and loads weights — ~10–60s.** The center readout shows "switching…" with
  a spinner until healthy.

Your Claude conversation is **preserved** across every switch — no restart. The next
message you send goes to the newly-selected backend.

---

## Typical flows

**Cheap/offline drafting on local, then Claude for the hard part:**
1. `ccgear` → work on a provider model.
2. Gauge → **Local ▾ → GLM-4.7-Flash** for bulk/cheap turns.
3. Gauge → **Cloud ▾ → Claude 4.8 Opus** when you need the strong model.

**All-local session:**
1. `ccgear` (gauge opens automatically).
2. **Local ▾ → Gemma-4-E4B** (wait for load), keep working. Switch to another local
   model anytime (restarts vllm-mlx for the new one).

---

## Check / control without the gauge

```bash
# is the router up + what's active + what's installed?
curl -s localhost:9000/state | python3 -m json.tool

# start the router only (no Claude launch); no-op if already up
bash scripts/ensure-up.sh

# switch from the CLI instead of the gauge
curl -s -XPOST localhost:9000/switch \
  -H 'content-type: application/json' \
  -d '{"kind":"local","model_id":"<model_id from /state catalog>"}'
```

---

## Troubleshooting

- **Gauge dropdowns empty / "router offline":** router isn't up. Run
  `bash scripts/ensure-up.sh`, then reopen the gauge. Check `run/router.log`.
- **Local switch hangs / fails:** watch `run/vllm.log` — model load errors show there.
  Confirm the model is cached (`Local ▾` only lists installed ones).
- **Multiple gauge windows:** `pkill -9 -f Gear.app/Contents/MacOS/Gear`, then
  `open gear/build/Gear.app` once.
- **Provider calls fail:** verify `provider_auth_token` in `config/config.json` and
  that the gateway at `provider_base_url` is reachable.
