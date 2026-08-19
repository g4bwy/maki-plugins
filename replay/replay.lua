-- /replay: export a maki session (including archived pre-compaction turns
-- and sub-agents) as Claude Code JSONL files for claude-replay. Sub-agents
-- have no native claude-replay support, so each gets its own .sub-N.jsonl
-- passed as an extra CLI input; timestamps are synthesized so the merged
-- replay interleaves parent and sub turns in the right order.

local core = require("replay_core")

local SESSIONS_DIR = "sessions"
local ARCHIVE_DIR = "archive"
local ARCHIVE_FILE = "^(%d+)%.jsonl$"
local SESSION_ID_TYPE = "session-id"
local USAGE = "Usage: /replay [session-id] [output-dir]"
local REPLAY_BIN = "claude-replay"
local REPLAY_OUT = "replay.html"
local MAX_CLI_INPUTS = 20

local function flash(msg)
  maki.ui.flash(msg)
end

local function split_lines(content)
  local lines = {}
  for line in content:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

-- Sessions arrive as base58 <id>.jsonl, but legacy v4-uuid sessions live on
-- disk under their hex filename, so fall back through the decoded hex
-- candidates before giving up.
local function find_session_file(sessions_dir, id)
  local candidates = { id .. ".jsonl" }
  local hex = core.id_to_hex(id)
  if hex then
    candidates[#candidates + 1] = hex .. ".jsonl"
    candidates[#candidates + 1] = hex:gsub("%-", "") .. ".jsonl"
  end
  for _, name in ipairs(candidates) do
    local path = maki.fs.joinpath(sessions_dir, name)
    local meta = maki.fs.metadata(path)
    if meta and meta.is_file then
      return path
    end
  end
  return nil
end

-- Archive filenames are epoch millis, so numeric order is age order.
local function list_archives(archive_dir)
  local entries = maki.fs.dir(archive_dir)
  if not entries then
    return {}
  end
  local archives = {}
  for _, entry in ipairs(entries) do
    local ms = entry[1]:match(ARCHIVE_FILE)
    if entry[2] == "file" and ms then
      archives[#archives + 1] = { ms = tonumber(ms), path = maki.fs.joinpath(archive_dir, entry[1]) }
    end
  end
  table.sort(archives, function(a, b)
    return a.ms < b.ms
  end)
  return archives
end

-- Classify one file's lines. Raw msg lines are kept verbatim: the merge
-- compares them as exact strings, and re-serializing decoded JSON could
-- reorder or reformat keys.
local function parse_lines(lines)
  local msgs = {}
  local subs = {}
  local sub_order = {}
  local header
  local last_meta
  for _, line in ipairs(lines) do
    local rec = maki.json.decode(line)
    if type(rec) == "table" then
      if rec.t == "msg" then
        msgs[#msgs + 1] = line
      elseif rec.t == "sub_msg" then
        local list = subs[rec.sub]
        if not list then
          list = {}
          subs[rec.sub] = list
          sub_order[#sub_order + 1] = rec.sub
        end
        list[#list + 1] = line
      elseif rec.t == "header" and not header then
        header = rec
      elseif rec.t == "meta" then
        last_meta = rec
      end
    end
  end
  return { msgs = msgs, subs = subs, sub_order = sub_order, header = header, last_meta = last_meta }
end

local function encode_line(value)
  local line, err = maki.json.encode(value)
  if err then
    return nil, err
  end
  return line
end

local function entry_line(mapped, ts)
  return encode_line({ type = mapped.type, message = mapped.message, timestamp = core.iso_utc(ts) })
end

local function write_jsonl(path, lines)
  local ok, err = maki.fs.write(path, table.concat(lines, "\n") .. "\n")
  if not ok then
    return err
  end
  return nil
end

local function export(id, out_dir)
  local state_dir = maki.env.state_dir()
  if not state_dir then
    flash("replay: no state dir available")
    return
  end
  local sessions_dir = maki.fs.joinpath(state_dir, SESSIONS_DIR)
  local current = find_session_file(sessions_dir, id)
  if not current then
    flash("replay: unknown session " .. id)
    return
  end

  local content, read_err = maki.fs.read(current)
  if read_err then
    flash("replay: " .. read_err)
    return
  end
  local current_parsed = parse_lines(split_lines(content))
  -- Archive dirs are keyed by the canonical base58 id in the header, which
  -- can differ from the form the user typed (legacy hex filenames).
  local header = current_parsed.header
  local archive_id = header and header.id or id

  local merged = {}
  local sub_msgs = {}
  local sub_key_order = {}
  local sub_key_seen = {}
  local function absorb(parsed)
    merged = core.merge_lines(merged, parsed.msgs)
    for key, list in pairs(parsed.subs) do
      sub_msgs[key] = list
    end
    for _, key in ipairs(parsed.sub_order) do
      if not sub_key_seen[key] then
        sub_key_seen[key] = true
        sub_key_order[#sub_key_order + 1] = key
      end
    end
  end

  for _, archive in ipairs(list_archives(maki.fs.joinpath(sessions_dir, ARCHIVE_DIR, archive_id))) do
    local archive_content, err = maki.fs.read(archive.path)
    if err then
      flash("replay: " .. err)
      return
    end
    absorb(parse_lines(split_lines(archive_content)))
  end
  absorb(current_parsed)

  -- The current file's meta is the only fresh one; archives' metas are stale.
  local meta = current_parsed.last_meta

  local s = header and header.created_at or 0
  local e = meta and meta.updated_at
  if not e then
    local file_meta = maki.fs.metadata(current)
    if file_meta and file_meta.mtime then
      e = math.floor(file_meta.mtime)
    end
  end
  if not e or e <= s then
    e = s
  end

  local entries = {}
  local weights = {}
  for _, raw in ipairs(merged) do
    local rec = maki.json.decode(raw)
    local msg = rec and rec.d
    local mapped = msg and core.map_message(msg)
    if mapped then
      entries[#entries + 1] = { role = msg.role, blocks = msg.content, mapped = mapped }
      weights[#weights + 1] = #raw
    end
  end
  local stamps = core.synthesize_timestamps(s, e, weights)
  for i, entry in ipairs(entries) do
    entry.ts = stamps[i]
  end
  local planned = core.plan_sub_files(entries, sub_key_order, s, e)

  local dir_meta = maki.fs.metadata(out_dir)
  if not (dir_meta and dir_meta.is_dir) then
    local _, mkdir_err = maki.fs.mkdir(out_dir, { parents = true })
    if mkdir_err then
      flash("replay: cannot create output dir: " .. mkdir_err)
      return
    end
  end

  local id_line, enc_err = encode_line({ type = SESSION_ID_TYPE, id = id })
  if not id_line then
    flash("replay: " .. enc_err)
    return
  end

  local parent_lines = { id_line }
  for _, entry in ipairs(entries) do
    local line, err = entry_line(entry.mapped, entry.ts)
    if not line then
      flash("replay: " .. err)
      return
    end
    parent_lines[#parent_lines + 1] = line
  end
  local parent_path = maki.fs.joinpath(out_dir, id .. ".jsonl")
  local write_err = write_jsonl(parent_path, parent_lines)
  if write_err then
    flash("replay: " .. write_err)
    return
  end

  local written = { parent_path }
  local turns = #entries
  for _, plan in ipairs(planned) do
    local sub_lines = sub_msgs[plan.key] or {}
    local out = {}
    for i, raw in ipairs(sub_lines) do
      local rec = maki.json.decode(raw)
      local msg = rec and rec.d
      local mapped = msg and core.map_message(msg)
      if mapped then
        local ts = core.sub_timestamp(plan.t_start, plan.t_end, i, #sub_lines)
        local line, err = entry_line(mapped, ts)
        if not line then
          flash("replay: " .. err)
          return
        end
        out[#out + 1] = line
      end
    end
    if #out > 0 then
      local sub_path = maki.fs.joinpath(out_dir, string.format("%s.sub-%d.jsonl", id, plan.n))
      local all = { id_line }
      for _, line in ipairs(out) do
        all[#all + 1] = line
      end
      local err = write_jsonl(sub_path, all)
      if err then
        flash("replay: " .. err)
        return
      end
      written[#written + 1] = sub_path
      turns = turns + #out
    end
  end

  local cmd_files = {}
  local left_out = 0
  for i, path in ipairs(written) do
    if i <= MAX_CLI_INPUTS then
      cmd_files[#cmd_files + 1] = path
    else
      left_out = left_out + 1
    end
  end
  local cmd = REPLAY_BIN .. " " .. table.concat(cmd_files, " ") .. " -o " .. REPLAY_OUT
  local flash_msg = cmd .. "  (Replay export: " .. #written .. " files, " .. turns .. " turns in " .. out_dir .. ")"
  if left_out > 0 then
    flash_msg = flash_msg
      .. "  ("
      .. left_out
      .. " sub file(s) not listed: claude-replay caps at "
      .. MAX_CLI_INPUTS
      .. " inputs)"
  end
  flash(flash_msg)
end

maki.api.register_command({
  name = "replay",
  description = "Export a maki session as Claude Code JSONL for claude-replay",
  nargs = "*",
  handler = function(opts)
    local fargs = opts.fargs or {}
    if #fargs > 2 then
      flash(USAGE)
      return
    end
    local id
    if fargs[1] then
      id = fargs[1]
    else
      local current_id, err = maki.session.current()
      if err then
        flash("replay: " .. err)
        return
      end
      id = current_id
    end
    export(id, maki.fs.abspath(fargs[2] or "."))
  end,
})
