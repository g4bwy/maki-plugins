-- Pure conversion core for /replay: session id decoding, archive merge,
-- timestamp synthesis, and maki -> Claude Code message mapping. No I/O and
-- no maki API, so a standalone Lua 5.1 harness can drive it directly.

local M = {}

local BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local BASE58_RADIX = 58
local BYTE_RADIX = 256
local UUID_BYTES = 16
local HEX_DIGITS = "0123456789abcdef"
local MIN_REWIND_PREFIX = 2
local MAX_OVERLAP_SHIFT = 8
local TASK_TOOL_NAME = "task"

local base58_index = {}
for i = 1, #BASE58_ALPHABET do
  base58_index[BASE58_ALPHABET:sub(i, i)] = i - 1
end

-- Encode a byte array (table of 0..255) as base58, Bitcoin alphabet.
-- Repeated division by 58; leading zero bytes become leading "1"s.
function M.base58_encode(bytes)
  local value = {}
  for i = 1, #bytes do
    value[i] = bytes[i]
  end
  local leading = 0
  for i = 1, #value do
    if value[i] ~= 0 then
      break
    end
    leading = leading + 1
  end
  local digits = {}
  local first = leading + 1
  local n = #value
  while first <= n do
    local remainder = 0
    for j = first, n do
      local combined = remainder * BYTE_RADIX + value[j]
      value[j] = math.floor(combined / BASE58_RADIX)
      remainder = combined % BASE58_RADIX
    end
    digits[#digits + 1] = remainder
    while first <= n and value[first] == 0 do
      first = first + 1
    end
  end
  local out = {}
  for i = 1, leading do
    out[#out + 1] = "1"
  end
  for i = #digits, 1, -1 do
    out[#out + 1] = BASE58_ALPHABET:sub(digits[i] + 1, digits[i] + 1)
  end
  return table.concat(out)
end

-- Decode a base58 string into a byte array, or nil on an invalid character.
-- Leading "1"s become leading zero bytes, as in Bitcoin base58.
function M.base58_decode(s)
  local value = {}
  for i = 1, #s do
    local digit = base58_index[s:sub(i, i)]
    if not digit then
      return nil
    end
    local carry = digit
    for j = #value, 1, -1 do
      local combined = value[j] * BASE58_RADIX + carry
      value[j] = combined % BYTE_RADIX
      carry = math.floor(combined / BYTE_RADIX)
    end
    if carry > 0 then
      table.insert(value, 1, carry)
    end
  end
  local bytes = {}
  local i = 1
  while i <= #s and s:sub(i, i) == "1" do
    bytes[#bytes + 1] = 0
    i = i + 1
  end
  local j = 1
  while j <= #value and value[j] == 0 do
    j = j + 1
  end
  for k = j, #value do
    bytes[#bytes + 1] = value[k]
  end
  return bytes
end

local function byte_to_hex(byte)
  local hi = math.floor(byte / 16)
  local lo = byte % 16
  return HEX_DIGITS:sub(hi + 1, hi + 1) .. HEX_DIGITS:sub(lo + 1, lo + 1)
end

-- Decode a session id to its 16 bytes as hyphenated hex (8-4-4-4-12), or
-- nil when the string is not base58 of exactly 16 bytes.
function M.id_to_hex(id)
  local bytes = M.base58_decode(id)
  if not bytes or #bytes ~= UUID_BYTES then
    return nil
  end
  local hex = {}
  for i = 1, UUID_BYTES do
    hex[i] = byte_to_hex(bytes[i])
  end
  local flat = table.concat(hex)
  return flat:sub(1, 8)
    .. "-"
    .. flat:sub(9, 12)
    .. "-"
    .. flat:sub(13, 16)
    .. "-"
    .. flat:sub(17, 20)
    .. "-"
    .. flat:sub(21, 32)
end

-- Merge the raw msg lines of a newer file F into the accumulated lines A.
-- The file order is not strict conversation order (append batching), so the
-- join point is found by content, not by position:
--   1. F sharing a prefix of A (length >= 2) is a rewind: F is authoritative.
--   2. A's tail overlapping F's head (shift <= 8, length >= 2) means F
--      re-sent what A already has; keep A plus F's new tail.
--   3. Otherwise the files are disjoint (e.g. a second compaction) and
--      plain concatenation is right.
function M.merge_lines(accumulated, newer)
  local n_acc = #accumulated
  local n_new = #newer
  local prefix = 0
  local limit = math.min(n_acc, n_new)
  while prefix < limit and accumulated[prefix + 1] == newer[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix >= MIN_REWIND_PREFIX then
    return newer
  end
  for shift = 0, MAX_OVERLAP_SHIFT do
    local max_overlap = math.min(n_acc, n_new - shift)
    if max_overlap < MIN_REWIND_PREFIX then
      break
    end
    for overlap = max_overlap, MIN_REWIND_PREFIX, -1 do
      local match = true
      for i = 1, overlap do
        if accumulated[n_acc - overlap + i] ~= newer[shift + i] then
          match = false
          break
        end
      end
      if match then
        local merged = {}
        for i = 1, n_acc do
          merged[#merged + 1] = accumulated[i]
        end
        for i = shift + overlap + 1, n_new do
          merged[#merged + 1] = newer[i]
        end
        return merged
      end
    end
  end
  local merged = {}
  for i = 1, n_acc do
    merged[#merged + 1] = accumulated[i]
  end
  for i = 1, n_new do
    merged[#merged + 1] = newer[i]
  end
  return merged
end

-- Spread n lines over [start_ts, end_ts] weighted by byte length: line 1
-- lands on start_ts, line n on end_ts, interiors proportional to the
-- cumulative weight. end_ts <= start_ts collapses everything onto start_ts.
function M.synthesize_timestamps(start_ts, end_ts, weights)
  local n = #weights
  local stamps = {}
  if n == 0 then
    return stamps
  end
  if end_ts <= start_ts then
    for i = 1, n do
      stamps[i] = start_ts
    end
    return stamps
  end
  if n == 1 then
    stamps[1] = start_ts
    return stamps
  end
  local total = 0
  for i = 1, n do
    total = total + weights[i]
  end
  stamps[1] = start_ts
  local cumulative = weights[1]
  for i = 2, n - 1 do
    cumulative = cumulative + weights[i]
    stamps[i] = start_ts + math.floor((end_ts - start_ts) * cumulative / total)
  end
  stamps[n] = end_ts
  return stamps
end

-- Format an epoch-seconds timestamp as ISO 8601 UTC.
function M.iso_utc(ts)
  local t = os.date("!*t", ts)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function has_content(text)
  return type(text) == "string" and text:match("%S") ~= nil
end

-- Map one maki message to a Claude Code entry, or nil when it maps to
-- nothing renderable (an assistant message whose blocks all drop).
--
--   user, text blocks only  -> content is a single string (a non-empty
--                              display_text wins over the content text)
--   user, any tool_result   -> content is an array of the tool_result
--                              blocks; text blocks are dropped
--   assistant               -> content is an array of text / thinking /
--                              tool_use blocks, in source order;
--                              redacted_thinking and image drop
function M.map_message(msg)
  if msg.role == "assistant" then
    local blocks = {}
    for _, block in ipairs(msg.content or {}) do
      if block.type == "text" and has_content(block.text) then
        blocks[#blocks + 1] = { type = "text", text = block.text }
      elseif block.type == "thinking" and has_content(block.thinking) then
        blocks[#blocks + 1] = { type = "thinking", thinking = block.thinking }
      elseif block.type == "tool_use" then
        blocks[#blocks + 1] = { type = "tool_use", id = block.id, name = block.name, input = block.input }
      end
    end
    if #blocks == 0 then
      return nil
    end
    return { type = "assistant", message = { role = "assistant", content = blocks } }
  end
  local results = {}
  for _, block in ipairs(msg.content or {}) do
    if block.type == "tool_result" then
      local entry = { type = "tool_result", tool_use_id = block.tool_use_id, content = block.content }
      if block.is_error == true then
        entry.is_error = true
      end
      results[#results + 1] = entry
    end
  end
  if #results > 0 then
    return { type = "user", message = { role = "user", content = results } }
  end
  local text
  if has_content(msg.display_text) then
    text = msg.display_text
  else
    local parts = {}
    for _, block in ipairs(msg.content or {}) do
      if block.type == "text" and has_content(block.text) then
        parts[#parts + 1] = block.text
      end
    end
    text = table.concat(parts, "\n")
  end
  return { type = "user", message = { role = "user", content = text } }
end

-- Plan the sub-agent output files. Sub streams are keyed by the parent
-- task tool_use id; numbering follows task tool_use appearance in the
-- parent stream, then orphaned keys (no matching tool_use, e.g. dropped
-- by compaction) in first sub_msg line order. Windows: [ts of the parent
-- line holding the tool_use, ts of the parent line holding its result);
-- an interrupted task ends at the next parent line, an orphan spans the
-- whole session.
function M.plan_sub_files(parent_entries, sub_keys, start_ts, end_ts)
  local task_use_lines = {}
  local result_lines = {}
  for line, entry in ipairs(parent_entries) do
    for _, block in ipairs(entry.blocks or {}) do
      if block.type == "tool_use" and block.name == TASK_TOOL_NAME then
        task_use_lines[#task_use_lines + 1] = { id = block.id, line = line }
      elseif block.type == "tool_result" and not result_lines[block.tool_use_id] then
        result_lines[block.tool_use_id] = line
      end
    end
  end
  local key_set = {}
  for _, key in ipairs(sub_keys) do
    key_set[key] = true
  end
  local planned = {}
  local assigned = {}
  local n = 0
  local function add(key, t_start, t_end)
    n = n + 1
    planned[#planned + 1] = { key = key, n = n, t_start = t_start, t_end = t_end }
    assigned[key] = true
  end
  for _, use in ipairs(task_use_lines) do
    if key_set[use.id] and not assigned[use.id] then
      local t_start = parent_entries[use.line].ts
      local t_end
      local result_line = result_lines[use.id]
      if result_line then
        t_end = parent_entries[result_line].ts
      elseif use.line < #parent_entries then
        t_end = parent_entries[use.line + 1].ts
      else
        t_end = end_ts
      end
      add(use.id, t_start, t_end)
    end
  end
  for _, key in ipairs(sub_keys) do
    if not assigned[key] then
      add(key, start_ts, end_ts)
    end
  end
  return planned
end

-- Timestamp of sub line index of count, inside [t_start, t_end). The
-- (index - 0.5) keeps every line strictly before t_end when the span is
-- at least a second, so sub turns interleave ahead of the parent result
-- turn under a stable chronological sort.
function M.sub_timestamp(t_start, t_end, index, count)
  local span = math.max(t_end - t_start, 0)
  return t_start + math.floor(span * (index - 0.5) / count)
end

return M
