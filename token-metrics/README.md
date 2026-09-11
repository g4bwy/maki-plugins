# token-metrics

Live vLLM throughput HUD for maki, in a small popup pinned to the top-right
corner of the terminal. Shows up only when the focused session's model is
served by a vLLM endpoint; silent for everything else.

## What it displays

Windowed (last 60s) rates, computed from Prometheus counter deltas scraped off
the server's `/metrics`:

| Line        | Formula                                                                                     |
|-------------|---------------------------------------------------------------------------------------------|
| `decode`    | `Δvllm:generation_tokens_total / Δt`                                                          |
| `prefill`   | `(Δvllm:prompt_tokens_total − Δcached) / Δt`, cached = `prompt_tokens_cached_total`, falling back to `prefix_cache_hits_total` |
| `pfx cache` | `Δvllm:prefix_cache_hits_total / Δvllm:prefix_cache_queries_total` (token-level hit rate)    |
| `draft acc` | `Δvllm:spec_decode_num_accepted_tokens_total / Δ..._num_draft_tokens_total`, plus mean acceptance length `1 + accepted/drafts` |
| `per pos`   | per-position acceptance length: `Δ..._per_pos_total{position=i} / Δdrafts`                    |
| footer      | `kv_cache_usage`, running/waiting request gauges                                              |

Handles both current and legacy metric names (`gpu_prefix_cache_*`,
`gpu_cache_usage_perc`), counter resets, multi-engine label sums, and hides the
spec-decode lines as `off` when speculative decoding is disabled.

## How it finds the endpoint

`maki.model.get()` gives the provider slug → base URL is resolved the same way
maki does: `$<SLUG>_BASE_URL` env first, then `base_url` in `providers.toml`
(legacy `~/.maki/` then config dir). The `/v1` path is stripped and
`<origin>/metrics` is probed — vLLM serves metrics at the server root and does
not require the API key. Three failed probes without a single `vllm:` sample
⇒ declared not-vLLM, panel dismissed with a notice.

## Install

1. Copy `token_metrics.lua` into your maki config dir:
   `cp token_metrics.lua ~/.config/maki/lua/`
2. Load it from `~/.config/maki/init.lua`:
   `require("token_metrics")`
3. `maki.net.request` refuses plain `http://` and private IPs unless the host
   is allowlisted, so add your server to `maki.setup`:
   ```lua
   maki.setup({
     net = { allowed_private_hosts = { "localhost:8888", "fender.lan" } },
   })
   ```
4. `/reload`.

Permissions needed (declare in the `plugin.toml` governing the config dir):
`fs_read` (providers.toml), `env` (`*_BASE_URL`), `net` (the scrape).

## Usage

- The panel appears automatically when the current model's endpoint answers
  vLLM metrics, and follows model/session switches.
- Polling is activity-aware: 1s cadence while a turn is running (woken
  instantly on `TurnStart`) and for 20s after the last one, decaying to one
  scrape every 15s when idle. Redraws are skipped when the frame is unchanged.
  Measured cost: ~1.3 ms Lua parse per scrape (68 KB body), so an idle maki
  barely notices it.
- `/token-metrics` or `<C-y>` toggles it.
- If the panel is dismissed by a UI cancel (esc), `/token-metrics` brings it
  back.

## Tuning

Consts at the top of `token_metrics.lua`: `POLL_MS` (1000, busy cadence),
`IDLE_POLL_MS` (15000), `ACTIVITY_COOLDOWN_SECS` (20), `WINDOW_SECS` (60),
`WIN_WIDTH` (42), `FAIL_LIMIT` (3). Metrics from other clients of the same
server update at the idle cadence while this session is idle.

## Tests

Pure-logic + fake-`maki` harness (endpoint resolution, poll loop, window math,
dismiss/reopen), runnable outside maki:

```
lua5.1 token_metrics_harness.lua
```
