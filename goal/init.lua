local STATE_DIR = maki.env.state_dir()
local GOAL_DIR = maki.fs.joinpath(STATE_DIR, "goal")
maki.fs.mkdir(GOAL_DIR, { parents = true })

local function goal_path(session_id)
  return maki.fs.joinpath(GOAL_DIR, session_id .. ".json")
end

local function load_goal(session_id)
  local path = goal_path(session_id)
  local content, err = maki.fs.read(path)
  if err or not content then return nil end
  local ok, data = pcall(maki.json.decode, content)
  if ok and data then return data end
  return nil
end

local function save_goal(session_id, data)
  local path = goal_path(session_id)
  local content = maki.json.encode(data or {})
  maki.fs.atomic_write(path, content)
end

local function clear_goal(session_id)
  local path = goal_path(session_id)
  maki.fs.rm(path)
end

local function now_ts()
  return os.time()
end

local CLEAR_ALIASES = { clear = true, stop = true, off = true, reset = true, none = true, cancel = true }

local function format_status(g)
  if not g or not g.condition then
    return "No goal set"
  end
  local elapsed = os.difftime(now_ts(), g.start_ts or now_ts())
  local turns = g.turns or 0
  local reason = g.last_reason or ""
  return string.format(
    "Goal active\nCondition: %s\nStarted: %ds ago\nTurns evaluated: %d\nLast reason: %s",
    g.condition, elapsed, turns, reason
  )
end

local function build_evaluator_prompt(condition, transcript)
  return string.format([[
You are evaluating whether a completion condition is met.
Condition: %s

Conversation so far (most recent last):
%s

Answer with exactly:
YES or NO
Reason: <one short sentence>

Do not call tools. Base decision only on visible transcript.
]], condition, transcript or "")
end

local function evaluate_goal(session_id, condition, transcript)
  local ctx = { session_id = session_id }
  local model = maki.agent.resolve_model(ctx, { tier = "fast" })
  if not model then
    return { ok = false, reason = "No fast model configured" }
  end

  local sess = maki.agent.session(ctx, { name = "goal-evaluator", model_spec = model })
  if not sess then
    return { ok = false, reason = "Failed to create evaluator session" }
  end

  local prompt = build_evaluator_prompt(condition, transcript)
  local res = sess:prompt(prompt)
  sess:close()

  if not res or not res.text then
    return { ok = false, reason = "Evaluator returned no output" }
  end

  local text = res.text
  local yes = text:match("[Yy][Ee][Ss]") ~= nil
  local no = text:match("[Nn][Oo]") ~= nil
  local reason = text:match("Reason:%s*(.+)") or text:sub(1, 200)

  return { ok = true, yes = yes, no = no, reason = reason, raw = text }
end

local function handle_goal_command(opts)
  local args = opts.args or ""
  local fargs = opts.fargs or {}
  local session_id, err = maki.session.current()
  if err or not session_id then
    maki.ui.flash("No active session")
    return
  end

  local goal = load_goal(session_id) or {}

  if args == "" then
    local status = format_status(goal)
    maki.ui.flash(status)
    maki.log.info("goal status: " .. status)
    return
  end

  local first = fargs[1] or ""
  if CLEAR_ALIASES[first] or first == "clear" then
    clear_goal(session_id)
    maki.ui.flash("Goal cleared")
    maki.log.info("goal cleared for session " .. session_id)
    return
  end

  -- Set new goal
  local condition = args
  if condition == "" then
    maki.ui.flash("Usage: /goal <condition> or /goal clear")
    return
  end

  goal.condition = condition
  goal.start_ts = now_ts()
  goal.turns = 0
  goal.last_reason = ""
  goal.achieved = false
  save_goal(session_id, goal)

  maki.ui.flash("Goal set: " .. condition)
  maki.log.info("goal set for session " .. session_id .. ": " .. condition)

  -- Start first turn immediately by prompting session with condition
  maki.session.prompt(condition, { session = session_id })
end

maki.api.register_command({
  name = "/goal",
  description = "Set a completion condition and keep working toward it across turns until met.",
  nargs = "*",
  handler = function(opts)
    handle_goal_command(opts)
  end,
})

-- Autocmd to evaluate after each turn
maki.api.create_autocmd("TurnEnd", {
  callback = function(data)
    local session_id = data and data.session_id
    if not session_id then return end

    local goal = load_goal(session_id)
    if not goal or not goal.condition or goal.achieved then return end

    -- Simple transcript: for now use last turn summary via session?
    -- Placeholder: we need actual transcript. Use maki.session? For now build minimal placeholder.
    local transcript = ""
    -- In real implementation, collect from session history via maki.agent or session API.
    -- We'll attempt to fetch via maki.session? No transcript API exposed.
    -- Fallback: use empty transcript; evaluator will note lack of evidence.

    local eval = evaluate_goal(session_id, goal.condition, transcript)
    if not eval.ok then
      maki.log.warn("goal evaluation failed: " .. eval.reason)
      maki.ui.flash("goal evaluation failed")
      return
    end

    goal.turns = (goal.turns or 0) + 1
    goal.last_reason = eval.reason

    if eval.yes then
      goal.achieved = true
      save_goal(session_id, goal)
      maki.ui.flash("Goal achieved")
      maki.log.info("goal achieved for session " .. session_id)
      -- Optionally clear after achievement
      clear_goal(session_id)
      return
    end

    if eval.no then
      save_goal(session_id, goal)
      -- Continue working: inject reason as guidance for next turn
      local guidance = "Goal progress: " .. eval.reason .. ". Continue working toward condition: " .. goal.condition
      maki.session.notify(guidance, { session = session_id, wake = true })
      return
    end

    -- Ambiguous
    save_goal(session_id, goal)
    maki.ui.flash("Goal evaluation unclear")
  end,
})

-- Clean up goal on session reset
maki.api.create_autocmd("SessionReset", {
  callback = function(data)
    local session_id = data and data.session_id
    if session_id then
      clear_goal(session_id)
    end
  end,
})
