local PLUGIN = "/home/gab/test/maki-plugins/token-metrics/token_metrics.lua"

local scrape_v29 = [[
# HELP vllm:generation_tokens_total Number of generation tokens.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total{engine="0",model_name="Qwen3-30B"} 1000.0
vllm:generation_tokens_total{engine="1",model_name="Qwen3-30B"} 500.0
vllm:prompt_tokens_total{engine="0",model_name="Qwen3-30B"} 4000.0
vllm:prefix_cache_queries_total{engine="0",model_name="Qwen3-30B"} 5000.0
vllm:prefix_cache_hits_total{engine="0",model_name="Qwen3-30B"} 2500.0
vllm:prompt_tokens_total_created{engine="0",model_name="Qwen3-30B"} 1.7e+09
vllm:spec_decode_num_drafts_total{engine="0",model_name="Qwen3-30B"} 200.0
vllm:spec_decode_num_draft_tokens_total{engine="0",model_name="Qwen3-30B"} 600.0
vllm:spec_decode_num_accepted_tokens_total{engine="0",model_name="Qwen3-30B"} 300.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="Qwen3-30B",position="0"} 200.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="Qwen3-30B",position="1"} 75.0
vllm:num_requests_running{engine="0",model_name="Qwen3-30B"} 2.0
vllm:num_requests_waiting{engine="0",model_name="Qwen3-30B"} 0.0
vllm:kv_cache_usage_perc{engine="0",model_name="Qwen3-30B"} 0.12
vllm:time_to_first_token_seconds_bucket{le="0.1",engine="0",model_name="Qwen3-30B"} 4.0
vllm:iteration_tokens_total_sum{engine="0",model_name="Qwen3-30B"} 1234.0
vllm:iteration_tokens_total_count{engine="0",model_name="Qwen3-30B"} 100.0
]]

local scrape_v29_later = [[
vllm:generation_tokens_total{engine="0",model_name="Qwen3-30B"} 2500.0
vllm:generation_tokens_total{engine="1",model_name="Qwen3-30B"} 1000.0
vllm:prompt_tokens_total{engine="0",model_name="Qwen3-30B"} 9000.0
vllm:prefix_cache_queries_total{engine="0",model_name="Qwen3-30B"} 7000.0
vllm:prefix_cache_hits_total{engine="0",model_name="Qwen3-30B"} 3500.0
vllm:spec_decode_num_drafts_total{engine="0",model_name="Qwen3-30B"} 400.0
vllm:spec_decode_num_draft_tokens_total{engine="0",model_name="Qwen3-30B"} 1200.0
vllm:spec_decode_num_accepted_tokens_total{engine="0",model_name="Qwen3-30B"} 600.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="Qwen3-30B",position="0"} 400.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="Qwen3-30B",position="1"} 175.0
vllm:num_requests_running{engine="0",model_name="Qwen3-30B"} 2.0
vllm:kv_cache_usage_perc{engine="0",model_name="Qwen3-30B"} 0.12
]]

local scrape_old_nospec = [[
vllm:generation_tokens_total{model_name="llama-3"} 100.0
vllm:prompt_tokens_total{model_name="llama-3"} 1000.0
vllm:gpu_prefix_cache_queries_total{model_name="llama-3"} 2000.0
vllm:gpu_prefix_cache_hits_total{model_name="llama-3"} 600.0
vllm:gpu_cache_usage_perc{model_name="llama-3"} 0.5
]]

local providers_toml = [[
[llama-cpp]
protocol = "openai"
base_url = "http://fender.lan:8080"

[vllm]
display_name = "Custom (vllm)"
protocol = "openai"
base_url = "http://fender.lan:8000/v1"
api_key_env = "VLLM_API_KEY"
]]

local env = {}
local captured = { scheduled = {}, autocmds = {}, commands = {}, keymaps = {}, notices = {}, flashes = {}, logs = {} }
local wins = {}
local net_calls = {}
local scrapes, scrape_i = {}, 0

local function set_scrapes(s)
  scrapes = s
  scrape_i = 0
end

local function default_net(url)
  net_calls[#net_calls + 1] = { url = url }
  scrape_i = scrape_i + 1
  return { body = scrapes[scrape_i] or scrapes[#scrapes], status = 200, content_type = "text/plain" }
end

local function line_text(line)
  if type(line) == "string" then
    return line
  end
  local parts = {}
  for _, span in ipairs(line) do
    parts[#parts + 1] = span[1]
  end
  return table.concat(parts)
end

local fake_clock = 100
os.clock = function()
  fake_clock = fake_clock + 5
  return fake_clock
end

maki = {
  defer_fn = function(cb, ms)
    local t = { cb = cb, ms = ms, stopped = false }
    captured.scheduled[#captured.scheduled + 1] = t
    return { stop = function() t.stopped = true end }
  end,
  log = { debug = function(m) captured.logs[#captured.logs + 1] = m end },
  notify = function(m, level) captured.notices[#captured.notices + 1] = { m, level } end,
  ui = {
    flash = function(m) captured.flashes[#captured.flashes + 1] = m end,
    buf = function()
      local b = { lines = {} }
      function b:set_lines(ls)
        self.lines = ls
        self.updates = (self.updates or 0) + 1
      end
      return b
    end,
    open_win = function(buf, opts)
      local w = { opts = opts, buf = buf, open = true }
      function w:is_open() return self.open end
      function w:close() self.open = false end
      wins[#wins + 1] = w
      return w
    end,
  },
  api = {
    create_autocmd = function(event, opts) captured.autocmds[event] = opts.callback end,
    register_command = function(spec) captured.commands[spec.name] = spec end,
  },
  keymap = { set = function(mode, lhs, rhs) captured.keymaps[lhs] = rhs end },
  model = { get = function() return { provider = "vllm", id = "Qwen3-30B", spec = "vllm/Qwen3-30B" } end },
  env = {
    legacy_dir = function() return nil end,
    config_dir = function() return "/fake/config" end,
  },
  fs = {
    joinpath = function(a, b) return a .. "/" .. b end,
    read = function(path)
      if path == "/fake/config/providers.toml" then
        return providers_toml
      end
    end,
  },
  uv = { os_getenv = function(name) return env[name] end },
  net = { request = default_net },
}

local M = assert(loadfile(PLUGIN))()

local function pending_ms()
  local ms
  for _, t in ipairs(captured.scheduled) do
    if not t.stopped then ms = t.ms end
  end
  return ms
end

local function take_tick()
  for i = #captured.scheduled, 1, -1 do
    if captured.scheduled[i].stopped then table.remove(captured.scheduled, i) end
  end
  local t = assert(captured.scheduled[1], "no tick scheduled")
  table.remove(captured.scheduled, 1)
  t.cb()
end

local function panel_text()
  local shown = {}
  for _, l in ipairs(wins[#wins].buf.lines) do shown[#shown + 1] = line_text(l) end
  return table.concat(shown, "\n")
end

set_scrapes({ scrape_v29, scrape_v29_later })

-- tick 1: resolve endpoint from providers.toml, first scrape, panel opens warming up
take_tick()
assert(net_calls[1].url == "http://fender.lan:8000/metrics", "metrics url: " .. tostring(net_calls[1].url))
assert(#wins == 1 and panel_text():match("warming up"))
assert(wins[1].opts.title == "vllm fender.lan:8000", "title: " .. wins[1].opts.title)
assert(wins[1].opts.anchor == "NE" and wins[1].opts.focus == false and wins[1].opts.row == 0 and wins[1].opts.col == 0)

-- tick 2: second scrape -> rates from 5s window
take_tick()
local text = panel_text()
assert(text:match("decode%s+200%.0"), text)
assert(text:match("prefill%s+400%.0"), text)
assert(text:match("pfx cache hit%s+50%.0 %%"), text)
assert(text:match("draft acc%s+50%.0 %% len 2%.50"), text)
assert(text:match("per pos%s+1%.0 0%.5"), text)
assert(text:match("kv 12%%  run 2  wait 0"), text)

-- env <SLUG>_BASE_URL overrides providers.toml
env.VLLM_BASE_URL = "http://gpubox:8001/v1"
captured.autocmds.ModelChanged({})
take_tick()
assert(net_calls[#net_calls].url == "http://gpubox:8001/metrics", "env override: " .. net_calls[#net_calls].url)

-- provider without base_url -> no probe, silent, slow retry
env.VLLM_BASE_URL = nil
maki.model.get = function() return { provider = "anthropic", id = "opus", spec = "anthropic/opus" } end
captured.autocmds.ModelChanged({})
local before = #net_calls
take_tick()
assert(#net_calls == before, "must not probe without base_url")
local pending
for _, t in ipairs(captured.scheduled) do if not t.stopped then pending = t end end
assert(pending and pending.ms == 30000, "expected slow retry, got " .. tostring(pending and pending.ms))

-- old server: gpu_ aliases, no spec decode families -> "off"
maki.model.get = function() return { provider = "vllm", id = "llama-3", spec = "vllm/llama-3" } end
set_scrapes({ scrape_old_nospec })
captured.autocmds.ModelChanged({})
take_tick()
take_tick()
text = panel_text()
assert(text:match("draft acc%s+off"), text)
assert(text:match("decode%s+0%.0"), text)
assert(text:match("kv 50%%"), text)

-- non-vllm endpoint: 3 failed probes -> warn notify + dismiss + stop
maki.net.request = function()
  net_calls[#net_calls + 1] = { url = "x" }
  return { body = "# some metrics\nllamacpp_requests_total 1\n", status = 200 }
end
captured.autocmds.ModelChanged({})
take_tick()
take_tick()
take_tick()
assert(#captured.notices == 1 and captured.notices[1][2] == "warn", "expected warn notice")
assert(wins[#wins].open == false, "panel should be dismissed")
assert(#captured.scheduled == 0 or captured.scheduled[1].stopped, "loop should stop")

-- command toggles back on
maki.net.request = default_net
set_scrapes({ scrape_v29, scrape_v29_later })
captured.commands["/token-metrics"].handler({})
assert(captured.flashes[#captured.flashes] == "token metrics on")
take_tick()
assert(wins[#wins].open == true, "command should reopen panel")
take_tick()
assert(panel_text():match("decode%s+200%.0"), panel_text())

-- <C-y> keymap toggles the panel off then on
assert(captured.keymaps["<C-y>"])
captured.keymaps["<C-y>"]()
assert(wins[#wins].open == false and captured.flashes[#captured.flashes] == "token metrics off")
set_scrapes({ scrape_v29, scrape_v29_later })
captured.keymaps["<C-y>"]()
take_tick()
take_tick()
assert(wins[#wins].open == true and panel_text():match("decode%s+200%.0"), panel_text())

-- TurnStart wakes the poll loop to fast cadence; TurnEnd keeps it fast through
-- the cooldown, then it decays to the idle interval; identical frames skip redraw
maki.net.request = default_net
set_scrapes({ scrape_v29, scrape_v29_later })
captured.autocmds.TurnStart({})
assert(pending_ms() == 0, "TurnStart should poll now")
take_tick()
assert(pending_ms() == 1000, "busy cadence")
captured.autocmds.TurnEnd({})
take_tick()
assert(pending_ms() == 1000, "cooldown cadence")
local decayed = false
for _ = 1, 15 do
  take_tick()
  if pending_ms() == 15000 then decayed = true break end
end
assert(decayed, "never decayed to idle cadence")
local cur_win = wins[#wins]
take_tick()
local updates_after_steady = cur_win.buf.updates
take_tick()
assert(cur_win.buf.updates == updates_after_steady, "unchanged frame should skip set_lines")
assert(M.parse_metrics("garbage") == nil)
assert(M.parse_metrics('vllm:foo_bucket{le="1"} 2.0') == nil)
local s1 = M.parse_metrics(scrape_v29)
local s2 = M.parse_metrics(scrape_v29_later)
s1.t, s2.t = 0, 10
local st = M.compute(s1, s2)
assert(math.abs(st.decode - 200) < 1e-9, st.decode)
assert(math.abs(st.hit - 50) < 1e-9)
assert(math.abs(st.acc_len - 2.5) < 1e-9)
assert(math.abs(st.pos[1] - 1.0) < 1e-9 and math.abs(st.pos[2] - 0.5) < 1e-9)

-- counter reset: b < a -> treat delta as new value
local s3 = M.parse_metrics('vllm:generation_tokens_total{model_name="x"} 10.0\n')
s3.t = 20
local st2 = M.compute(s2, s3)
assert(st2.decode == 1.0, st2.decode)
assert(st2.hit == nil and st2.prefill == nil)

-- cached counter preferred over pch for uncached prefill
local c1 = M.parse_metrics("vllm:prompt_tokens_total{model_name=\"x\"} 100.0\nvllm:prompt_tokens_cached_total{model_name=\"x\"} 80.0\nvllm:prefix_cache_queries_total{model_name=\"x\"} 100.0\nvllm:prefix_cache_hits_total{model_name=\"x\"} 80.0\n")
local c2 = M.parse_metrics("vllm:prompt_tokens_total{model_name=\"x\"} 300.0\nvllm:prompt_tokens_cached_total{model_name=\"x\"} 100.0\nvllm:prefix_cache_queries_total{model_name=\"x\"} 300.0\nvllm:prefix_cache_hits_total{model_name=\"x\"} 100.0\n")
c1.t, c2.t = 0, 10
local st3 = M.compute(c1, c2)
assert(math.abs(st3.prefill - 18) < 1e-9, st3.prefill)
assert(math.abs(st3.hit - 10) < 1e-9, st3.hit)

print("ALL OK")
