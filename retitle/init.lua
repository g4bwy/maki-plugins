-- retitle.lua
-- Give sessions pertinent titles for the /sessions dialog.
--
-- Maki names a session with the first 60 characters of its opening prompt.
-- This plugin asks the session's own model to summarize each session
-- instead, from a digest of its transcript on disk (first request, later
-- user turns, final assistant replies, subagent names).
--
-- Two entry points:
--   /retitle            bridge command; asks this session's agent to call the
--                       retitle_sessions tool (slash commands have no model
--                       access of their own). Without args it retitles every
--                       auto-titled session; `current` (or `now`/`this`) does
--                       only the session you are typing in.
--   retitle_sessions    the tool. Targets sessions of the current project
--                       whose title is still maki's auto-generated one, so a
--                       manual /rename is never overwritten unless the call
--                       names a session or passes force.

local truncate = require("maki.truncate")

local MAX_TITLE = 60
local DEFAULT_TITLE = "New session"
local MAX_DIGEST = 3500
local MAX_CONCURRENT = 4

local SYSTEM = [[You name past coding-agent sessions for a session picker.
You receive a digest of one session: its first user request, later user
messages, the final assistant replies, and any sub-task names.

Reply with one title line that tells a developer what the session was about
and what it produced or investigated. Rules:
- At most 60 characters.
- A short plain phrase or verb clause, lowercase is fine.
- No quotes, no trailing punctuation, no "Session about" prefix, no date.
- Output only the title, nothing else.]]

local settings = {
  -- Skip sessions whose title was set by hand, unless force is passed.
  only_auto_titles = true,
}

local function setup(opts)
  if opts and type(opts.only_auto_titles) == "boolean" then
    settings.only_auto_titles = opts.only_auto_titles
  end
end

-- ---------- text helpers ----------

local function collapse_ws(s)
  return (s:gsub("%s+", " "):match("^ *(.-) *$") or "")
end

-- Largest byte index <= n that ends a whole UTF-8 character.
local function utf8_floor(s, n)
  local i = math.min(n, #s)
  while i > 0 do
    local b = s:byte(i)
    if b >= 128 and b < 192 then
      i = i - 1 -- continuation byte, walk back to the character start
    elseif b >= 192 then
      return i - 1 -- start byte: the character runs past n, drop it
    else
      return i
    end
  end
  return 0
end

local function cut(s, n)
  if #s <= n then
    return s
  end
  return s:sub(1, utf8_floor(s, n)) .. "…"
end

-- Mirrors maki-storage generate_title: the first 60 characters of the first
-- user text, cut at a word boundary with an ellipsis. A title equal to this
-- (or to "New session") was machine-made and is safe to replace.
local function auto_title(first_text)
  if not first_text or first_text == "" then
    return DEFAULT_TITLE
  end
  local text = collapse_ws(first_text)
  if text == "" then
    return DEFAULT_TITLE
  end
  if #text <= MAX_TITLE then
    return text
  end
  local head = text:sub(1, utf8_floor(text, MAX_TITLE))
  local rpos = head:reverse():find(" ", 1, true)
  local pos = rpos and (#head - rpos + 1)
  if pos and pos > MAX_TITLE / 2 then
    return head:sub(1, pos - 1) .. "…"
  end
  return head .. "…"
end

local function is_title_auto(title, first_text)
  title = title or DEFAULT_TITLE
  return title == DEFAULT_TITLE or title == auto_title(first_text)
end

-- Model output can still misbehave: take the first line, strip decoration.
local function sanitize_title(raw)
  local line = tostring(raw):match("^[^\r\n]*") or ""
  line = line:gsub('^[%s"\'`*:%-]+', "")
  line = line:gsub('[%s"\'`*]+$', "")
  line = collapse_ws(line)
  if line == "" then
    return nil
  end
  return cut(line, MAX_TITLE)
end

-- ---------- transcript digest ----------

local function session_file(id)
  local dir = maki.env.state_dir()
  if not dir then
    return nil, "cannot locate the maki state dir"
  end
  local path = maki.fs.joinpath(dir, "sessions", id .. ".jsonl")
  local meta = maki.fs.metadata(path)
  if not meta then
    return nil, "no transcript file for session " .. id
  end
  return path
end

-- Read the session log and pull out the few things that say what happened.
-- Only msg and meta lines are JSON-decoded; tool output lines are skipped by
-- prefix so a 2 MB transcript stays cheap.
local function build_digest(id)
  local path, err = session_file(id)
  if not path then
    return nil, err
  end
  local raw
  raw, err = maki.fs.read(path)
  if not raw then
    return nil, "cannot read transcript: " .. tostring(err)
  end

  local first_user_text
  local later_user = {}
  local assistant_tail = {}
  local user_turns, tool_calls = 0, 0
  local meta_title, subagent_names, plan_path
  -- sub_msg lines (subagent turns) and out lines (tool output) are skipped
  -- by prefix, so a 2 MB transcript costs few decodes.
  for line in raw:gmatch("[^\n]+") do
    local kind = line:sub(1, 10)
    if kind == '{"t":"msg"' then
      local ok, rec = pcall(maki.json.decode, line)
      if ok and type(rec) == "table" then
        local d = rec.d
        local content = d and type(d.content) == "table" and d.content
        if content then
          if d.role == "user" then
            local text
            for _, b in ipairs(content) do
              if type(b) == "table" and b.type == "text" and type(b.text) == "string"
                  and b.text ~= "" then
                text = b.text
                break
              end
            end
            if text then
              user_turns = user_turns + 1
              if not first_user_text then
                first_user_text = text
              elseif #later_user < 4 then
                later_user[#later_user + 1] = cut(collapse_ws(text), 120)
              end
            end
          elseif d.role == "assistant" then
            for _, b in ipairs(content) do
              if type(b) == "table" then
                if b.type == "tool_use" then
                  tool_calls = tool_calls + 1
                elseif b.type == "text" and type(b.text) == "string" and b.text ~= "" then
                  assistant_tail[#assistant_tail + 1] = cut(collapse_ws(b.text), 220)
                  while #assistant_tail > 2 do
                    table.remove(assistant_tail, 1)
                  end
                end
              end
            end
          end
        end
      end
    elseif line:sub(1, 10) == '{"t":"meta"' then
      local ok, rec = pcall(maki.json.decode, line)
      if ok and type(rec) == "table" then
        -- Each meta line is the whole current state, so later lines replace
        -- what earlier ones said.
        meta_title = rec.title or DEFAULT_TITLE
        plan_path = rec.plan_path
        subagent_names = nil
        if type(rec.subagents) == "table" and #rec.subagents > 0 then
          subagent_names = {}
          for _, s in ipairs(rec.subagents) do
            if type(s) == "table" and type(s.name) == "string" then
              subagent_names[#subagent_names + 1] = cut(collapse_ws(s.name), 80)
            end
          end
        end
      end
    end
  end

  if not first_user_text then
    return nil, "session has no user text to summarize"
  end
  if not meta_title then
    meta_title = auto_title(first_user_text)
  end

  local parts = {}
  parts[#parts + 1] = ("Stats: %d user turns, %d tool calls."):format(user_turns, tool_calls)
  if subagent_names and #subagent_names > 0 then
    parts[#parts + 1] = "Sub-tasks run: " .. table.concat(subagent_names, "; ")
  end
  if plan_path then
    parts[#parts + 1] = "Plan file: " .. tostring(plan_path)
  end
  parts[#parts + 1] = "\nFirst request:\n" .. cut(collapse_ws(first_user_text), 700)
  if #later_user > 0 then
    parts[#parts + 1] = "\nLater user messages:\n- " .. table.concat(later_user, "\n- ")
  end
  if #assistant_tail > 0 then
    parts[#parts + 1] = "\nFinal assistant replies:\n- " .. table.concat(assistant_tail, "\n- ")
  end
  local digest = table.concat(parts, "\n")

  -- Keep the first request and trim the tail if the whole thing is too big.
  if #digest > MAX_DIGEST then
    digest = cut(digest, MAX_DIGEST)
  end
  return digest, first_user_text, meta_title
end

-- ---------- one session at a time ----------

local function gen_title(ctx, digest)
  -- model_spec omitted: the titling run uses the session's current model.
  local sess, sess_err = maki.agent.session(ctx, {
    system = SYSTEM,
    -- tools omitted on purpose: an empty Lua table serializes as a JSON
    -- object, and the host wants an array. Omitting means "no tools".
    mcp = false,
    thinking = "off",
    name = "retitle",
  })
  if sess_err then
    return nil, sess_err
  end

  local ok, title, err = pcall(function()
    local result, perr = sess:prompt(digest)
    if perr then
      return nil, perr
    end
    return sanitize_title(result and result.text or "")
  end)
  sess:close()

  if not ok then
    return nil, "title subagent failed: " .. tostring(title)
  end
  return title, err
end

-- Returns { id, short, old, new, status }
local function retitle_one(ctx, s, force)
  local out = { id = s.id, short = tostring(s.id):sub(1, 8), old = s.title or DEFAULT_TITLE }

  local digest, first_text, meta_title = build_digest(s.id)
  if not digest then
    out.status = first_text -- build_digest returned (nil, err)
    return out
  end
  if out.old == DEFAULT_TITLE then
    out.old = meta_title -- the stored scan can be behind the file
  end
  if not force and not is_title_auto(out.old, first_text) then
    out.status = "skipped (title looks hand-made; use force to overwrite)"
    return out
  end

  local title, err = gen_title(ctx, digest)
  if not title then
    out.status = "error: " .. tostring(err)
    return out
  end
  local _, set_err = maki.session.set_title({ id = s.id, title = title })
  if set_err then
    out.status = "error: " .. tostring(set_err)
    return out
  end
  out.new = title
  out.status = "renamed"
  return out
end

-- ---------- entry points ----------

local function find_target(sessions, wanted)
  local exact = nil
  local prefix, prefix_count = nil, 0
  for _, s in ipairs(sessions) do
    local id = tostring(s.id)
    if id == wanted then
      exact = s
    elseif id:sub(1, #wanted):lower() == wanted:lower() then
      prefix, prefix_count = s, prefix_count + 1
    end
  end
  if exact then
    return exact
  end
  if prefix_count == 1 then
    return prefix
  end
  if prefix_count > 1 then
    return nil, wanted .. " matches " .. prefix_count .. " sessions; give a longer id prefix"
  end
  return nil, "no session in this project matches " .. wanted
end

maki.api.register_tool({
  name = "retitle_sessions",
  kind = "session",
  description = [[Generate a pertinent summary title for sessions of the current project, so the /sessions dialog shows what each one was about.

- No id and no current: retitles every session whose title is still maki's auto-generated one (the truncated first prompt).
- current: retitle only the focused session (what this call runs in), whatever its current title.
- id: retitle one session by id or unique id prefix, whatever its current title.
- force: also replace titles the user set by hand with /rename.

The digest is read from stored transcripts, so sessions that are closed are fine. Reports one line per session.]],
  schema = {
    type = "object",
    properties = {
      current = { type = "boolean", description = "Re-title only the focused session, whatever its current title." },
      id = { type = "string", description = "Session id (or unique prefix) to retitle; omit for all auto-titled sessions." },
      force = { type = "boolean", description = "Also overwrite manually renamed sessions. Default false." },
    },
  },
  handler = function(input, ctx)
    local stored, err = maki.session.list()
    if not stored then
      return { llm_output = "error: " .. tostring(err), is_error = true }
    end

    -- Live titles beat the background scan, which may be one save behind.
    local live, _ = maki.session.live()
    if live then
      local by_id = {}
      for _, s in ipairs(stored) do
        by_id[tostring(s.id)] = s
      end
      for _, s in ipairs(live) do
        local known = by_id[tostring(s.id)]
        if known then
          known.title = s.title or known.title
        else
          stored[#stored + 1] = { id = s.id, title = s.title, updated_at = s.updated_at }
        end
      end
    end
    if #stored == 0 then
      return { llm_output = "no sessions stored for this project" }
    end

    local force = input.force == true or settings.only_auto_titles == false
    local targets = {}
    local wanted = input.id
    if input.current then
      local cur, cur_err = maki.session.current()
      if not cur then
        return { llm_output = "error: no focused session: " .. tostring(cur_err), is_error = true }
      end
      wanted = tostring(cur)
    end
    if wanted and wanted ~= "" then
      local one, find_err = find_target(stored, wanted)
      if not one and input.current then
        -- A brand-new session can be missing from the background scan; the
        -- transcript path is enough to retitle it anyway.
        one = { id = wanted, title = nil }
      end
      if not one then
        return { llm_output = "error: " .. find_err, is_error = true }
      end
      -- An explicitly named session is retitled whatever it is called now.
      targets = { one }
      force = true
    else
      for _, s in ipairs(stored) do
        targets[#targets + 1] = s
      end
    end

    local results = {}
    local fns = {}
    for i, s in ipairs(targets) do
      fns[i] = function()
        -- pcall per session: one unreadable transcript (bad UTF-8, torn
        -- file) must not sink the whole batch.
        local ok, r = pcall(retitle_one, ctx, s, force)
        if ok then
          results[i] = r
        else
          results[i] = {
            id = s.id,
            short = tostring(s.id):sub(1, 8),
            old = s.title or DEFAULT_TITLE,
            status = "error: " .. tostring(r),
          }
        end
      end
    end
    maki.async.join(MAX_CONCURRENT, fns)

    local lines, renamed, skipped = {}, 0, 0
    for _, r in ipairs(results) do
      if r then
        if r.status == "renamed" then
          renamed = renamed + 1
          lines[#lines + 1] = ('%s  "%s"  ->  "%s"'):format(r.short, r.old, r.new)
        else
          skipped = skipped + 1
          lines[#lines + 1] = ("%s  %s  [%s]"):format(r.short, r.old, r.status)
        end
      end
    end
    local head = ("Retitled %d of %d session(s) in this project (%d skipped or failed):"):format(
      renamed, #results, skipped)
    return {
      llm_output = truncate(head .. "\n" .. table.concat(lines, "\n"), 80, 8000),
      annotation = head,
    }
  end,
})

-- Slash commands have no agent ctx, so /retitle cannot call the model itself.
-- It hands the job to this session's agent, which has one and can call the
-- tool. Words map to tool arguments: current/now/this/. -> current = true,
-- force -> force = true, anything else -> an id prefix.
local CURRENT_WORDS = { current = true, now = true, this = true, ["."] = true }

local function run_retitle(opts)
  local words = opts.fargs or {}
  local parts = {}
  for _, w in ipairs(words) do
    local lw = w:lower()
    if lw == "force" then
      parts[#parts + 1] = "force = true"
    elseif CURRENT_WORDS[lw] then
      parts[#parts + 1] = "current = true"
    else
      parts[#parts + 1] = ('id = "%s"'):format(w)
    end
  end
  local request
  if #parts > 0 then
    request = "Call the retitle_sessions tool now with these arguments: " .. table.concat(parts, ", ")
  else
    request = "Call the retitle_sessions tool now with no arguments"
  end
  local _, err = maki.session.prompt(
    request .. ". Do not do anything else. Then show me the tool's report as a short list."
  )
  if err then
    maki.ui.flash("retitle: " .. tostring(err))
  else
    maki.ui.flash("retitle: asking this session's agent to title your sessions")
  end
end

maki.api.register_command({
  name = "/retitle",
  description = "Summarize session titles with the current model (args: [current|force|<session id prefix>])",
  nargs = "*",
  handler = run_retitle,
})

return { setup = setup }
