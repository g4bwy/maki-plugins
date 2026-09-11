local POLL_MS = 1000
local IDLE_POLL_MS = 15000
local ACTIVITY_COOLDOWN_SECS = 20
local WINDOW_SECS = 60
local FAIL_LIMIT = 3
local WIN_WIDTH = 42
local WIN_HEIGHT = 8
local PROBE_TIMEOUT_SECS = 5
local RESOLVE_RETRY_MS = 30000
local MAX_POS = 6

local COUNTER_NAMES = {
  gen = { "vllm:generation_tokens_total" },
  prompt = { "vllm:prompt_tokens_total" },
  cached = { "vllm:prompt_tokens_cached_total" },
  pcq = { "vllm:prefix_cache_queries_total", "vllm:gpu_prefix_cache_queries_total" },
  pch = { "vllm:prefix_cache_hits_total", "vllm:gpu_prefix_cache_hits_total" },
  sdd = { "vllm:spec_decode_num_drafts_total" },
  sdt = { "vllm:spec_decode_num_draft_tokens_total" },
  sda = { "vllm:spec_decode_num_accepted_tokens_total" },
}

local GAUGE_NAMES = {
  kv = { "vllm:kv_cache_usage_perc", "vllm:gpu_cache_usage_perc" },
  run = { "vllm:num_requests_running" },
  wait = { "vllm:num_requests_waiting" },
}

local PER_POS_NAME = "vllm:spec_decode_num_accepted_tokens_per_pos_total"

local function pick(raw, names)
  for _, n in ipairs(names) do
    if raw[n] then
      return raw[n], n
    end
  end
end

local function parse_metrics(text)
  local raw, raw_n, pos = {}, {}, nil
  for line in text:gmatch("[^\r\n]+") do
    if line:sub(1, 5) == "vllm:" then
      local head, vs = line:match("^(%S+)%s+(%S+)")
      local v = head and tonumber(vs)
      if v then
        local name = head:match("^[^{]+") or head
        if not name:match("_bucket$") and not name:match("_created$") then
          raw[name] = (raw[name] or 0) + v
          raw_n[name] = (raw_n[name] or 0) + 1
          if name == PER_POS_NAME then
            local p = tonumber(head:match('position="(%d+)"'))
            if p then
              pos = pos or {}
              pos[p + 1] = (pos[p + 1] or 0) + v
            end
          end
        end
      end
    end
  end
  if not next(raw) then
    return
  end
  local c, g = {}, {}
  for key, names in pairs(COUNTER_NAMES) do
    c[key] = pick(raw, names)
  end
  for key, names in pairs(GAUGE_NAMES) do
    local v, n = pick(raw, names)
    if v then
      g[key] = v / raw_n[n]
    end
  end
  return { c = c, g = g, pos = pos }
end

local function delta(a, b)
  if not a or not b then
    return
  end
  if b < a then
    return b
  end
  return b - a
end

local function compute(first, last)
  local dt = last.t - first.t
  if dt <= 0 then
    return
  end
  local d = {}
  for key in pairs(COUNTER_NAMES) do
    d[key] = delta(first.c[key], last.c[key])
  end
  if last.pos then
    d.pos = {}
    for i, v in pairs(last.pos) do
      if first.pos and first.pos[i] then
        d.pos[i] = delta(first.pos[i], v)
      end
    end
  end

  local s = {}
  if d.gen then
    s.decode = d.gen / dt
  end
  if d.prompt then
    s.prefill = math.max(d.prompt - (d.cached or d.pch or 0), 0) / dt
  end
  if d.pch and d.pcq and d.pcq > 0 then
    s.hit = 100 * d.pch / d.pcq
  end
  if not d.sdt then
    s.spec = "off"
  elseif d.sdt > 0 and d.sda then
    s.accept = 100 * d.sda / d.sdt
  else
    s.spec = "idle"
  end
  if d.sdd and d.sdd > 0 and d.sda then
    s.acc_len = 1 + d.sda / d.sdd
    if d.pos then
      s.pos = {}
      for i, v in pairs(d.pos) do
        s.pos[i] = v / d.sdd
      end
    end
  end
  s.kv, s.run, s.wait = last.g.kv, last.g.run, last.g.wait
  return s
end

local function fmt_rate(v)
  if not v then
    return "-"
  elseif v >= 1000 then
    return string.format("%6.0f", v)
  end
  return string.format("%6.1f", v)
end

local function fmt_pct(v)
  if not v then
    return "-"
  end
  return string.format("%.1f %%", v)
end

local function row(label, value, note)
  return {
    { string.format("%-13s ", label), "dim" },
    { value },
    { note and (" " .. note) or "", "dim" },
  }
end

local function render_lines(s, msg)
  local spec_txt, spec_note = "-", nil
  if s then
    if s.spec == "off" then
      spec_txt = "off"
    elseif s.spec == "idle" then
      spec_txt = "idle"
    elseif s.accept then
      spec_txt = fmt_pct(s.accept)
      if s.acc_len then
        spec_note = string.format("len %.2f", s.acc_len)
      end
    end
  end

  local pos_txt
  if s and s.pos then
    local vals = {}
    for i = 1, math.min(#s.pos, MAX_POS) do
      vals[#vals + 1] = string.format("%.1f", s.pos[i] or 0)
    end
    pos_txt = table.concat(vals, " ")
  end

  local lines = {
    row("decode", fmt_rate(s and s.decode), "t/s"),
    row("prefill", fmt_rate(s and s.prefill), "t/s"),
    row("pfx cache hit", fmt_pct(s and s.hit)),
    row("draft acc", spec_txt, spec_note),
    { { string.format("%-13s ", "per pos"), "dim" }, { pos_txt or "", "dim" } },
    {
      {
        msg
          or (s and string.format("kv %.0f%%  run %d  wait %d", (s.kv or 0) * 100, math.floor(s.run or 0), math.floor(s.wait or 0)))
          or "",
        "dim",
      },
    },
  }
  return lines
end

local function provider_base_url(provider)
  local url = maki.uv.os_getenv(provider:gsub("[^%w]", "_"):upper() .. "_BASE_URL")
  if url then
    return url
  end
  local dir = maki.env.legacy_dir() or maki.env.config_dir()
  if not dir then
    return
  end
  local text = maki.fs.read(maki.fs.joinpath(dir, "providers.toml"))
  if not text then
    return
  end
  local in_section = false
  for line in text:gmatch("[^\r\n]+") do
    local section = line:match("^%s*%[([^%]]+)%]%s*$")
    if section then
      in_section = section == provider
    elseif in_section then
      local u = line:match('^%s*base_url%s*=%s*"([^"]+)"')
      if u then
        return u
      end
    end
  end
end

local function resolve_endpoint()
  local model = maki.model.get()
  if not model or not model.provider then
    return nil, "no model"
  end
  local base = provider_base_url(model.provider)
  if not base then
    return nil, "provider " .. model.provider .. " has no base_url"
  end
  local origin = base:match("^(%a[%w+.-]*://[^/]+)")
  if not origin then
    return nil, "unparsable base_url " .. base
  end
  return { metrics = origin .. "/metrics", title = "vllm " .. origin:match("://(.*)$") }
end

local endpoint, endpoint_err
local samples = {}
local failures = 0
local confirmed = false
local dismissed = false
local busy = false
local last_activity = -math.huge
local rendered_sig
local buf, win, timer
local poll

local function next_delay()
  if not confirmed or busy or os.clock() - last_activity <= ACTIVITY_COOLDOWN_SECS then
    return POLL_MS
  end
  return IDLE_POLL_MS
end

local function stop()
  if timer then
    timer:stop()
    timer = nil
  end
end

local function schedule(ms)
  stop()
  timer = maki.defer_fn(poll, ms)
end

local function close_panel()
  if win and win:is_open() then
    win:close()
  end
  win, buf = nil, nil
  rendered_sig = nil
end

local function open_panel()
  if win and win:is_open() then
    return true
  end
  if dismissed or not endpoint then
    return false
  end
  win = nil
  buf = maki.ui.buf({ scratch = true })
  win = maki.ui.open_win(buf, {
    title = endpoint.title,
    anchor = "NE",
    row = 0,
    col = 0,
    width = WIN_WIDTH,
    height = WIN_HEIGHT,
    border = "rounded",
    focus = false,
    stack = true,
    zindex = 40,
  })
  return win ~= nil
end

local function lines_text(lines)
  local parts = {}
  for _, l in ipairs(lines) do
    if type(l) == "string" then
      parts[#parts + 1] = l
    else
      for _, span in ipairs(l) do
        parts[#parts + 1] = span[1]
      end
    end
    parts[#parts + 1] = "\n"
  end
  return table.concat(parts)
end

local function render(s, msg)
  if not open_panel() then
    return
  end
  local lines = render_lines(s, msg)
  local sig = lines_text(lines)
  if sig == rendered_sig then
    return
  end
  rendered_sig = sig
  buf:set_lines(lines)
end

poll = function()
  if dismissed then
    return
  end
  schedule(next_delay())
  if win and not win:is_open() then
    dismissed = true
    close_panel()
    stop()
    return
  end
  if not endpoint then
    endpoint, endpoint_err = resolve_endpoint()
    if not endpoint then
      if endpoint_err then
        maki.log.debug("token-metrics: " .. endpoint_err)
      end
      schedule(RESOLVE_RETRY_MS)
      return
    end
  end
  local resp, err = maki.net.request(endpoint.metrics, { timeout = PROBE_TIMEOUT_SECS, retry = 0 })
  local sample = resp and resp.status == 200 and parse_metrics(resp.body or "")
  if not sample then
    failures = failures + 1
    if not confirmed and failures >= FAIL_LIMIT then
      dismissed = true
      close_panel()
      stop()
      maki.notify(
        "token-metrics: " .. endpoint.metrics .. " is not a vLLM endpoint ("
          .. (err or (resp and "http " .. resp.status) or "no vllm metrics") .. ")",
        "warn"
      )
      return
    end
    render(nil, err or (resp and "http " .. resp.status) or "no vllm metrics")
    return
  end
  failures = 0
  confirmed = true
  local now = os.clock()
  sample.t = now
  samples[#samples + 1] = sample
  while #samples > 2 and now - samples[2].t <= WINDOW_SECS do
    table.remove(samples, 1)
  end
  local s = #samples >= 2 and compute(samples[1], samples[#samples]) or nil
  render(s, s == nil and "warming up" or nil)
end

local function reset()
  stop()
  close_panel()
  endpoint, endpoint_err = nil, nil
  samples = {}
  failures = 0
  confirmed = false
  dismissed = false
  busy = false
  last_activity = -math.huge
  schedule(0)
end

maki.api.create_autocmd("ModelChanged", { callback = reset })
maki.api.create_autocmd("SessionFocusChanged", { callback = reset })

maki.api.create_autocmd("TurnStart", {
  callback = function()
    busy = true
    last_activity = os.clock()
    if not dismissed then
      schedule(0)
    end
  end,
})

local function on_turn_end()
  busy = false
  last_activity = os.clock()
end

maki.api.create_autocmd("TurnEnd", { callback = on_turn_end })
maki.api.create_autocmd("TurnError", { callback = on_turn_end })

local function toggle()
  if not dismissed then
    dismissed = true
    stop()
    close_panel()
    maki.ui.flash("token metrics off")
  else
    reset()
    maki.ui.flash("token metrics on")
  end
end

maki.api.register_command({
  name = "/token-metrics",
  description = "Toggle the vLLM throughput panel (decode t/s, uncached prefill t/s, prefix cache hit %, draft acceptance).",
  nargs = 0,
  handler = toggle,
})

maki.keymap.set("n", "<C-y>", toggle, { desc = "Toggle vLLM metrics panel" })

schedule(250)

return {
  parse_metrics = parse_metrics,
  compute = compute,
  render_lines = render_lines,
  resolve_endpoint = resolve_endpoint,
}
