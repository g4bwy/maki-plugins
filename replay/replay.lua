-- /replay: export a maki session (including archived pre-compaction turns
-- and sub-agents) as Claude Code JSONL files for claude-replay. Sub-agents
-- have no native claude-replay support, so each gets its own .sub-N.jsonl
-- passed as an extra CLI input; timestamps are synthesized so the merged
-- replay interleaves parent and sub turns in the right order.
--
-- A long session passes a gigabyte, and Luau refuses a single string that
-- big, so this file never holds one: the source is read a window at a time,
-- and only the parent msg stream is kept in memory. Sub-agent bodies stay on
-- disk until the pass that writes them out, and output goes out in batches.

local core = require("replay_core")

local SESSIONS_DIR = "sessions"
local ARCHIVE_DIR = "archive"
local ARCHIVE_FILE = "^(%d+)%.jsonl$"
local SESSION_ID_TYPE = "session-id"
local USAGE = "Usage: /replay [session-id] [output-dir]"
local REPLAY_BIN = "claude-replay"
local REPLAY_OUT = "replay.html"
local MAX_CLI_INPUTS = 20

-- Read and write sizes. The streaming path only matters for files over
-- whole_read_bytes, and one window is a dd block, so these are exposed as the
-- value of this module: a test can shrink them and drive the same code over a
-- fixture of a few kilobytes.
local tuning = {
  -- Files up to this size are read in one call; bigger ones are streamed.
  whole_read_bytes = 64 * 1024 * 1024,
  -- Bytes copied per dd call. Also the largest line a session can carry.
  window_bytes = 8 * 1024 * 1024,
  window_limit = 4096,
  window_timeout_ms = 30000,
  -- Output held across every open file before it is flushed.
  group_bytes = 8 * 1024 * 1024,
}

-- The largest string the interpreter will allocate: Luau caps one at 1 GiB,
-- which is why a session file that big cannot be read in a single call at all.
local STRING_LIMIT = 1024 * 1024 * 1024

-- Copy one window of the file to stdout as base64, with no line wrapping.
-- Base64 is the only shape that survives the trip intact: the job reader
-- splits output on newlines and drops carriage returns, so a raw window
-- would lose the line endings the window boundaries are counted in. The path
-- reaches the shell only as $REPLAY_FILE, never as command text, so a session
-- id can name a file and nothing else.
local WINDOW_CMD = "dd if=\"$REPLAY_FILE\" bs=%d skip=%d count=1 status=none | base64 | tr -d '\\n'"

local function flash(msg)
  maki.ui.flash(msg)
end

local function file_size(path)
  local meta = maki.fs.metadata(path)
  return meta and meta.size or 0
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

-- Run {cmd} through the shell with $REPLAY_FILE set to {path}, and return
-- everything it wrote to stdout.
local function capture(path, cmd)
  local started, id = pcall(maki.fn.jobstart, cmd, {
    env = { REPLAY_FILE = path },
    tail = 0,
  })
  if not started then
    return nil, tostring(id)
  end
  local waited, result = pcall(maki.fn.jobwait, id, tuning.window_timeout_ms)
  if not waited then
    maki.fn.jobstop(id)
    return nil, tostring(result)
  end
  if not result then
    maki.fn.jobstop(id)
    return nil, "timed out reading " .. path
  end
  if result.exit_code ~= 0 then
    local why = result.stderr ~= nil and result.stderr ~= "" and (": " .. result.stderr) or ""
    return nil, string.format("cannot read %s (exit %d)%s", path, result.exit_code, why)
  end
  return result.stdout or ""
end

local function read_window(path, window)
  local encoded, err = capture(path, string.format(WINDOW_CMD, tuning.window_bytes, window))
  if err then
    return nil, err
  end
  local compact = (encoded:gsub("%s", ""))
  if compact == "" then
    return ""
  end
  local decoded, data = pcall(maki.base64.decode, compact)
  if not decoded then
    return nil, "cannot decode what was read from " .. path
  end
  return data
end

-- Read the whole file in one call. The interpreter refuses a string over
-- 1 GiB, so this answers for a small file, or for a big one on a machine
-- without the tools the streaming path needs, where it fails loudly.
local function read_whole(path, on_line)
  local reader = core.new_line_reader(on_line)
  local ok, content = pcall(maki.fs.read, path)
  if not ok then
    return tostring(content)
  end
  if not content then
    return "cannot read " .. path
  end
  local stop = reader:push(content)
  if stop then
    return stop
  end
  return reader:finish()
end

-- Copy the file window by window. Answers with the handler's own message when
-- it asked to stop, and with a message plus "read" when the copy itself failed.
local function read_streamed(path, on_line)
  local reader = core.new_line_reader(on_line)
  for window = 0, tuning.window_limit - 1 do
    local data, err = read_window(path, window)
    if err then
      return err, "read"
    end
    local stop = reader:push(data)
    if stop then
      return stop
    end
    if #data < tuning.window_bytes then
      return reader:finish()
    end
  end
  return path .. " is larger than " .. tuning.window_limit .. " windows", "read"
end

-- Hand every line of {path} to {on_line} in order, holding no more of the file
-- than one window plus one line. {on_line} may answer with an error message to
-- stop the read, which is then returned.
local function read_lines(path, on_line)
  local size = file_size(path)
  if size <= tuning.whole_read_bytes then
    return read_whole(path, on_line)
  end
  local err, kind = read_streamed(path, on_line)
  if not err then
    return nil
  end
  if kind == "read" and size < STRING_LIMIT then
    -- dd, base64 or tr is missing (a bare container, Windows). A file the
    -- interpreter can still hold whole is read the plain way instead.
    return read_whole(path, on_line)
  end
  return err
end

-- Classify one line: its record type, and its sub-agent key for a sub_msg
-- line. The prefix maki writes answers both without parsing, which matters
-- because most of a session is `out` tool-output records the export drops.
-- header and meta lines are decoded here as well, since the passes need the
-- fields inside them, and so is any line that does not carry the standard
-- prefix: a key order or spacing change then still lands in the right bucket.
-- Returns nil for a line that is not a record at all.
local function classify(line)
  local t, sub = core.classify(line)
  if t and t ~= "header" and t ~= "meta" then
    return t, sub
  end
  local rec = maki.json.decode(line)
  if type(rec) ~= "table" then
    return nil
  end
  return rec.t, rec.sub, rec
end

-- Read one source file. Raw msg lines are kept verbatim, because the merge
-- compares them as exact strings and re-serializing decoded JSON could
-- reorder or reformat keys. Sub-agent streams are only named and counted:
-- their bodies are re-read by the pass that writes them.
local function scan_file(path)
  local parsed = { path = path, msgs = {}, sub_order = {}, sub_counts = {} }
  local err = read_lines(path, function(line)
    local t, sub, rec = classify(line)
    if t == "msg" then
      parsed.msgs[#parsed.msgs + 1] = line
    elseif t == "sub_msg" and sub then
      if not parsed.sub_counts[sub] then
        parsed.sub_order[#parsed.sub_order + 1] = sub
      end
      parsed.sub_counts[sub] = (parsed.sub_counts[sub] or 0) + 1
    elseif t == "header" and not parsed.header then
      parsed.header = rec
    elseif t == "meta" then
      parsed.last_meta = rec
    end
    return nil
  end)
  return parsed, err
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

-- Output files, written in batches: one fs call per line would cost tens of
-- thousands of them, and concatenating a whole file first would put the
-- string limit back in our way. Every file of one export shares a single
-- memory budget, so a session with many sub-agents does not hold a buffer per
-- stream. Each writer opens its file with a write, so a re-run replaces the
-- previous export, and appends to it from then on.
local function new_group()
  local group = { members = {}, bytes = 0 }

  function group:flush_all()
    for _, writer in ipairs(self.members) do
      local err = writer:flush()
      if err then
        return err
      end
    end
    return nil
  end

  function group:writer(path, seed)
    local writer = { path = path, buf = { seed .. "\n" }, bytes = #seed + 1, body = 0, started = false }
    self.bytes = self.bytes + writer.bytes
    self.members[#self.members + 1] = writer

    function writer:flush()
      if self.body == 0 then
        -- Nothing worth opening a file for yet. A stream whose lines all
        -- dropped must leave no file behind, so the seed line waits too.
        return nil
      end
      if self.bytes == 0 then
        return nil
      end
      local text = table.concat(self.buf)
      local ok, err
      if self.started then
        ok, err = maki.fs.append(self.path, text)
      else
        ok, err = maki.fs.write(self.path, text)
        self.started = true
      end
      group.bytes = group.bytes - self.bytes
      self.buf = {}
      self.bytes = 0
      if not ok then
        return err or ("cannot write " .. self.path)
      end
      return nil
    end

    function writer:add(line)
      local bytes = #line + 1
      self.buf[#self.buf + 1] = line .. "\n"
      self.bytes = self.bytes + bytes
      self.body = self.body + 1
      group.bytes = group.bytes + bytes
      if group.bytes >= tuning.group_bytes then
        return group:flush_all()
      end
      return nil
    end

    return writer
  end

  return group
end

-- Write the sub-agent streams carried by one source file. Lines are counted
-- whether or not they map to something renderable, so a stream keeps the same
-- index the plan spread its timestamps over.
local function emit_subs(parsed, index, owners, plan_of, writer_of)
  local seen = {}
  return read_lines(parsed.path, function(line)
    local t, key = classify(line)
    local owner = t == "sub_msg" and owners[key] or nil
    if not owner or owner.file ~= index or not plan_of[key] then
      return nil
    end
    local count = (seen[key] or 0) + 1
    seen[key] = count
    local rec = maki.json.decode(line)
    local msg = rec and rec.d
    local mapped = msg and core.map_message(msg)
    if not mapped then
      return nil
    end
    local plan = plan_of[key]
    local stamp = core.sub_timestamp(plan.t_start, plan.t_end, count, owner.count)
    local out, err = entry_line(mapped, stamp)
    if not out then
      return err or "cannot encode a sub-agent line"
    end
    return writer_of[key]:add(out)
  end)
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

  -- The live file is read first because its header names the archive
  -- directory, which can differ from the form the user typed (legacy hex
  -- filenames).
  local current_parsed, err = scan_file(current)
  if err then
    flash("replay: " .. err)
    return
  end
  local header = current_parsed.header
  local archive_id = header and header.id or id

  -- Sources in merge order: archived compaction files oldest first, then the
  -- live file.
  local files = {}
  for _, archive in ipairs(list_archives(maki.fs.joinpath(sessions_dir, ARCHIVE_DIR, archive_id))) do
    local parsed, scan_err = scan_file(archive.path)
    if scan_err then
      flash("replay: " .. scan_err)
      return
    end
    files[#files + 1] = parsed
  end
  files[#files + 1] = current_parsed

  local merged = {}
  local owners = {}
  local sub_keys = {}
  local seen_key = {}
  for index, parsed in ipairs(files) do
    merged = core.merge_lines(merged, parsed.msgs)
    -- The last file that carries a stream owns it: that is the one with the
    -- full transcript of the sub-agent, so earlier copies are stale.
    for _, key in ipairs(parsed.sub_order) do
      owners[key] = { file = index, count = parsed.sub_counts[key] }
      if not seen_key[key] then
        seen_key[key] = true
        sub_keys[#sub_keys + 1] = key
      end
    end
  end

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
  local planned = core.plan_sub_files(entries, sub_keys, s, e)

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

  local group = new_group()
  local parent = group:writer(maki.fs.joinpath(out_dir, id .. ".jsonl"), id_line)
  for _, entry in ipairs(entries) do
    local line, line_err = entry_line(entry.mapped, entry.ts)
    if not line then
      flash("replay: " .. (line_err or "cannot encode a line"))
      return
    end
    local write_err = parent:add(line)
    if write_err then
      flash("replay: " .. write_err)
      return
    end
  end
  local turns = parent.body

  -- The decoded parent stream has done its work: the plan is made and its
  -- lines are out, so drop it before the sub-agent pass reads the files again.
  for _, entry in ipairs(entries) do
    entry.blocks = nil
    entry.mapped = nil
  end
  entries = nil
  merged = nil
  weights = nil
  stamps = nil

  local plan_of = {}
  local writer_of = {}
  for _, plan in ipairs(planned) do
    plan_of[plan.key] = plan
    writer_of[plan.key] = group:writer(maki.fs.joinpath(out_dir, string.format("%s.sub-%d.jsonl", id, plan.n)), id_line)
  end

  for index, parsed in ipairs(files) do
    local owned = false
    for _, plan in ipairs(planned) do
      if owners[plan.key].file == index then
        owned = true
        break
      end
    end
    if owned then
      local sub_err = emit_subs(parsed, index, owners, plan_of, writer_of)
      if sub_err then
        flash("replay: " .. sub_err)
        return
      end
    end
  end

  local flush_err = group:flush_all()
  if flush_err then
    flash("replay: " .. flush_err)
    return
  end

  local written = { parent.path }
  for _, plan in ipairs(planned) do
    local writer = writer_of[plan.key]
    if writer.body > 0 then
      written[#written + 1] = writer.path
      turns = turns + writer.body
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

-- Read/write sizes, exposed so a test can drive the streaming path over a
-- fixture too small to need it in production.
return tuning
