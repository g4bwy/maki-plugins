-- Session time tracker.
--
-- /time opens a popup, styled like the built-in /usage modal, that splits a
-- session's time into idle, inference (API requests), tool calls, and sub-agents.
--
-- The transcript is the source of truth for history: maki stamps every message
-- with `created_at` (epoch ms), so on open the panel reads
-- `maki.session.messages()` once and splits the whole session, correct whether
-- the plugin watched it (hot) or is seeing it for the first time (cold). After
-- that it advances the buckets in constant time from the live TurnStart /
-- TurnEnd / ToolStart / ToolDone events, so a redraw never re-walks the
-- transcript. It is a focused float with a recv loop that runs in the command
-- handler and closes on Esc, exactly like the bundled sessions/tasks/model
-- pickers. The one mistake that DID hang the app was rebuilding the whole
-- transcript (hundreds of messages, thousands of Lua tables) on every tick: on
-- the single shared Lua thread that starves the turn's own work and the popup's
-- key handling. Read the transcript once on open, then only touch in-memory
-- state in the loop.
--
-- How each gap between consecutive stamped messages is charged, by the message
-- that ends it:
--
--   assistant reached        ->  inference   (the model was generating)
--   a tool result reached    ->  tool call, or sub-agent if the call was `task`
--                                or `batch` (a sub-agent ran until it landed)
--   a user prompt reached    ->  idle        (the session waited for input)
--
-- Sub-agent time is a separate total, never folded into the main tool calls. It
-- is the wall window the parent spent blocked on a `task`/`batch` call, from the
-- assistant message that issued it to the tool result that closed it (a batched
-- result closes the whole parallel set at once, charged once). A sub-agent moved
-- to the background runs while the parent does other work, so that concurrent
-- wall time belongs to whatever the parent was doing, not twice to both. The
-- plugin cannot split a sub-agent's own inference versus its own tools: that lives
-- in the sub-agent transcript, which no plugin API returns. So main + sub-agents
-- totals the session's wall clock. Messages from before maki recorded `created_at`
-- carry none, so a session that predates the field is timed from its first stamped
-- message onward.

local TITLE = " Session time "
local PREFIX = "  "
local LABEL_W = 25
local VAL_W = 11
local PCT_W = 4
local COL_GAP = 2
local TICK_MS = 1000
local HINT = "Esc"
local MS = 1000

-- Two column budgets decide the width. The data grid is #PREFIX + LABEL_W +
-- VAL_W + COL_GAP + PCT_W. The footer ("  N turns   M tool calls   <status>")
-- is wider, so it drives the window. FOOTER_W sizes the longest real status,
-- "inference in progress", with roomy counts. Two columns are the border.
local ROW_W = #PREFIX + LABEL_W + VAL_W + COL_GAP + PCT_W
local FOOTER_W = #("  88 turns   888 tools   88 sub-agents   sub-agent running")
local CONTENT_W = math.max(ROW_W, FOOTER_W)
local WIN_WIDTH = CONTENT_W + 3  -- border, plus a right-margin cell
local WIN_HEIGHT = 11

local STATE_IDLE, STATE_INFER, STATE_TOOL, STATE_SUB = "idle", "infer", "tool", "sub"

-- Tool calls that run a sub-agent rather than doing local work. Their wall time
-- is tracked as sub-agent time, never folded into the main "tool calls". Nested
-- sub-agents are counted under the parent turn they ran inside, so main + sub is
-- a session wall-clock total.
local SUBAGENT_TOOLS = { task = true, batch = true }

-- Per-session live accumulator. Filled from the transcript on open, then moved
-- in constant time by events and the redraw tick.
local sessions = {}
local popup = nil

local function now_ms()
  return math.floor(os.time() * MS)
end

local function focused_id()
  return maki.session.current()
end

local function has_type(message, want)
  for _, block in ipairs(message.content or {}) do
    if block.type == want then
      return true
    end
  end
  return false
end

local function is_prompt(message)
  return message.role == "user"
    and (message.kind == nil or message.kind == "turn")
    and not has_type(message, "tool_result")
    and has_type(message, "text")
end

local function block_field(block, field)
  local v = block[field]
  if type(v) == "table" then
    return nil
  end
  return v
end

-- Which of a message's tool_results close a sub-agent call. The tool name comes
-- from the matching tool_use block, collected up front from every message.
local function closes_subagent(message, names)
  for _, block in ipairs(message.content or {}) do
    if block.type == "tool_result" then
      if names[block_field(block, "tool_use_id")] then
        return true
      end
    end
  end
  return false
end

-- Walk the transcript once and split it into the four buckets (ms), plus turn,
-- tool-call and sub-agent-run counts. Called only when a session starts watched.
local function reconstruct(sid)
  local messages, err = maki.session.messages({ session = sid })
  if not messages then
    return nil, err
  end
  local names = {}
  for _, message in ipairs(messages) do
    for _, block in ipairs(message.content or {}) do
      if block.type == "tool_use" then
        names[block_field(block, "id")] = SUBAGENT_TOOLS[block_field(block, "name")] or false
      end
    end
  end
  local idle, infer, tool, sub, turns, calls, sub_runs, prev = 0, 0, 0, 0, 0, 0, 0, nil
  for _, message in ipairs(messages) do
    local prompt = is_prompt(message)
    if prompt then
      turns = turns + 1
    end
    for _, block in ipairs(message.content or {}) do
      if block.type == "tool_use" then
        if names[block_field(block, "id")] then
          sub_runs = sub_runs + 1
        else
          calls = calls + 1
        end
      end
    end
    local ts = tonumber(message.created_at)
    if ts then
      if prev and ts > prev then
        local gap = ts - prev
        if has_type(message, "tool_result") then
          if closes_subagent(message, names) then
            sub = sub + gap
          else
            tool = tool + gap
          end
        elseif message.role == "assistant" then
          infer = infer + gap
        elseif prompt then
          idle = idle + gap
        end
      end
      prev = ts
    end
  end
  return {
    idle = idle,
    infer = infer,
    tool = tool,
    sub = sub,
    turns = turns,
    calls = calls,
    sub_runs = sub_runs,
    last = prev,
  }
end

-- Return the live accumulator for a session, seeding it from the transcript the
-- first time it is watched this run.
local function watched(sid)
  if not sid then
    return nil
  end
  local s = sessions[sid]
  if not s then
    local base, err = reconstruct(sid)
    if not base then
      return nil, err
    end
    s = {
      idle = base.idle,
      infer = base.infer,
      tool = base.tool,
      sub = base.sub,
      turn_count = base.turns,
      tool_count = base.calls,
      sub_count = base.sub_runs,
      state = STATE_IDLE,
      tools = 0,
      subs = 0,
      in_turn = false,
      -- Continue from the transcript's last stamped message, so the wait since
      -- the last reply counts as idle. Falls back to now for an all-unstamped
      -- (pre-change) session, which then shows only live time.
      last = base.last or now_ms(),
    }
    sessions[sid] = s
  end
  return s
end

-- Move the elapsed time since the last settle into the bucket the session is in.
-- The in-progress turn is not a message yet, so this is how live time accrues.
local function settle(s)
  local elapsed = now_ms() - s.last
  if elapsed > 0 then
    s[s.state] = s[s.state] + elapsed
    s.last = s.last + elapsed
  end
end

local function recalc(s)
  if s.tools > 0 then
    s.state = STATE_TOOL
  elseif s.subs > 0 then
    s.state = STATE_SUB
  elseif s.in_turn then
    s.state = STATE_INFER
  else
    s.state = STATE_IDLE
  end
end

-- Apply one live transition. Cheap and non-blocking: never touches the
-- transcript, so it runs fine while a turn is in flight.
local function apply(sid, mutate)
  local s = sessions[sid]
  if not s then
    return
  end
  settle(s)
  mutate(s)
  recalc(s)
end

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    apply(ev.data and ev.data.session_id, function(s)
      s.in_turn = true
      s.turn_count = s.turn_count + 1
    end)
  end,
})

maki.api.create_autocmd({ "TurnEnd", "TurnError" }, {
  callback = function(ev)
    apply(ev.data and ev.data.session_id, function(s)
      s.in_turn = false
    end)
  end,
})

maki.api.create_autocmd("ToolStart", {
  callback = function(ev)
    local data = ev.data
    local subagent = data and SUBAGENT_TOOLS[data.tool]
    apply(data and data.session_id, function(s)
      if subagent then
        s.subs = s.subs + 1
      else
        s.tools = s.tools + 1
      end
    end)
  end,
})

maki.api.create_autocmd("ToolDone", {
  callback = function(ev)
    local data = ev.data
    local subagent = data and SUBAGENT_TOOLS[data.tool]
    apply(data and data.session_id, function(s)
      if subagent then
        if s.subs > 0 then
          s.subs = s.subs - 1
        end
        s.sub_count = s.sub_count + 1
      else
        if s.tools > 0 then
          s.tools = s.tools - 1
        end
        s.tool_count = s.tool_count + 1
      end
    end)
  end,
})

local function forget(ev)
  local sid = ev.data and ev.data.session_id
  if sid then
    sessions[sid] = nil
  end
end

maki.api.create_autocmd({ "SessionEnd", "SessionReset" }, { callback = forget })

-- The footer status line: turn, tool-call and sub-agent counts, and what runs now.
local function activity(s)
  local head = string.format("%d turns   %d tools   %d sub-agents  ", s.turn_count, s.tool_count, s.sub_count)
  if s.state == STATE_TOOL then
    return head .. "tool running"
  elseif s.state == STATE_SUB then
    return head .. "sub-agent running"
  elseif s.state == STATE_INFER then
    return head .. "inferring"
  end
  return head .. "waiting for input"
end

local function duration(secs)
  if secs <= 0 then
    return "0s"
  end
  return maki.ui.humantime(secs)
end

local function percent(secs, total)
  if total <= 0 then
    return "-"
  end
  return string.format("%d%%", math.floor(secs * 100 / total + 0.5))
end

local function row(label, secs, total, value_style)
  local value = duration(secs)
  local pad = VAL_W - #value
  if pad < 0 then
    pad = 0
  end
  return {
    { PREFIX .. string.format("%-" .. LABEL_W .. "s", label), "dim" },
    { string.rep(" ", pad) .. value, value_style },
    { string.rep(" ", COL_GAP) .. string.format("%" .. PCT_W .. "s", percent(secs, total)), "dim" },
  }
end

-- Render lines from a live accumulator. Pure: it touches no session state, so it
-- is safe to call from the update loop while an agent turn holds the UI.
local function render(s)
  local idle_s, infer_s, tool_s, sub_s =
    math.floor(s.idle / MS), math.floor(s.infer / MS), math.floor(s.tool / MS), math.floor(s.sub / MS)
  local wall = idle_s + infer_s + tool_s + sub_s
  local footer = maki.ui.truncate_text(PREFIX .. activity(s), CONTENT_W).head
  return {
    { { PREFIX .. "Session timing", "keybind_section" } },
    "",
    row("wall clock", wall, wall, "tool"),
    row("idle (awaiting input)", idle_s, wall),
    row("inference (api requests)", infer_s, wall),
    row("tool calls", tool_s, wall),
    row("sub-agents", sub_s, wall, "tool"),
    "",
    { { footer, "dim" } },
  }
end

-- Fold in elapsed time and repaint from the in-memory accumulator.
local function draw(p)
  local s = sessions[p.sid]
  if not s then
    return
  end
  settle(s)
  p.buf:set_lines(render(s))
end

-- The command handler IS the loop, exactly like the bundled sessions picker: a
-- focused float, recv on a tick, Esc closes. recv suspends this coroutine, so
-- agent-turn events and the autocmds that update `sessions` keep running, and the
-- key the user presses comes straight back. Tearing this out into a background
-- task, or opening the float without focus, is what broke Esc.
local function open()
  local sid = focused_id()
  if not sid then
    maki.ui.flash("no focused session")
    return
  end
  if not watched(sid) then
    maki.ui.flash("no timing data for this session")
    return
  end
  local p = { buf = maki.ui.buf({ scratch = true }), sid = sid }
  p.win = maki.ui.open_win(p.buf, {
    title = TITLE,
    width = WIN_WIDTH,
    height = WIN_HEIGHT,
    border = "rounded",
    title_pos = "center",
    footer = { { HINT, "close" } },
    session = sid,
    focus = true,
  })
  popup = p
  draw(p)
  while popup == p do
    local ev = p.win:recv(TICK_MS)
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      if ev.key == "<Esc>" or ev.key == "q" then
        break
      end
    else
      draw(p)
    end
  end
  if popup == p then
    popup = nil
  end
  p.win:close()
  sessions[sid] = nil
end

maki.api.register_command({
  name = "/time",
  description = "Show a popup of session time: wall clock split into idle, inference, and tool calls.",
  nargs = 0,
  handler = open,
})
