-- Spec for the /replay plugin. Runs inside maki (maki.test_helpers) or
-- standalone: lua ~/.config/maki/lua/replay_spec.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
if dir then
  package.path = dir .. "?.lua;" .. package.path
end

local core = require("replay_core")

local ok, th = pcall(require, "maki.test_helpers")
if not ok then
  th = {}
  local failures = {}
  local count = 0
  function th.case(name, fn)
    count = count + 1
    local res, err = pcall(fn)
    if not res then
      failures[#failures + 1] = name .. ": " .. tostring(err)
    end
  end
  function th.eq(actual, expected, msg)
    if actual ~= expected then
      error((msg or "") .. "\nexpected: " .. tostring(expected) .. "\n  actual: " .. tostring(actual), 0)
    end
  end
  function th.report()
    print(count .. " cases run")
    if #failures > 0 then
      print(table.concat(failures, "\n\n"))
      os.exit(1)
    end
    print("all spec cases passed under " .. _VERSION)
  end
end

local case = th.case
local eq = th.eq

local ENCODED_1_TO_16 = "8DfbjXLth7APvt3qQPgtf"
local ENCODED_0_TO_15 = "12drXXUifSrRnXLGbXg8E"
local CD_HEX = "019f8029-255f-7480-a1ad-a06609c4f89e"

local function bytes_from(first, count)
  local bytes = {}
  for i = 0, count - 1 do
    bytes[i + 1] = first + i
  end
  return bytes
end

case("base58_roundtrip_1_to_16", function()
  local bytes = bytes_from(1, 16)
  eq(core.base58_encode(bytes), ENCODED_1_TO_16)
  local back = core.base58_decode(ENCODED_1_TO_16)
  eq(#back, 16)
  for i = 1, 16 do
    eq(back[i], i)
  end
end)

case("base58_leading_zero_byte", function()
  local encoded = core.base58_encode(bytes_from(0, 16))
  eq(encoded, ENCODED_0_TO_15)
  local back = core.base58_decode(ENCODED_0_TO_15)
  eq(#back, 16)
  for i = 1, 16 do
    eq(back[i], i - 1)
  end
end)

case("base58_id_to_hex_known", function()
  eq(core.id_to_hex("CdDZ1scyaX1gUhVrkaWEZ"), CD_HEX)
end)

case("base58_rejects_bad_char", function()
  eq(core.id_to_hex("OdDZ1scyaX1gUhVrkaWEZ"), nil)
end)

case("base58_rejects_wrong_length", function()
  eq(core.id_to_hex("2j87v4grC"), nil)
end)

case("merge_plain_concat", function()
  local merged = core.merge_lines({ "a", "b" }, { "c", "d" })
  eq(table.concat(merged, ","), "a,b,c,d")
end)

case("merge_tail_overlap", function()
  local merged = core.merge_lines({ "a", "b", "c", "d" }, { "x", "c", "d", "e" })
  eq(table.concat(merged, ","), "a,b,c,d,e")
end)

case("merge_min_overlap_rejects_1_line", function()
  local merged = core.merge_lines({ "p", "r1" }, { "p", "r2" })
  eq(table.concat(merged, ","), "p,r1,p,r2")
end)

case("merge_rewind_prefix", function()
  local merged = core.merge_lines({ "a", "b", "c", "d" }, { "a", "b" })
  eq(table.concat(merged, ","), "a,b")
end)

case("merge_rewind_plus_growth", function()
  local merged = core.merge_lines({ "a", "b", "c", "d" }, { "a", "b", "x", "y" })
  eq(table.concat(merged, ","), "a,b,x,y")
end)

case("merge_second_compaction", function()
  local merged = core.merge_lines({ "p", "s1", "x" }, { "p", "s2", "x" })
  eq(table.concat(merged, ","), "p,s1,x,p,s2,x")
end)

case("timestamps_single_line", function()
  local stamps = core.synthesize_timestamps(100, 200, { 5 })
  eq(table.concat(stamps, ","), "100")
end)

case("timestamps_end_le_start_all_start", function()
  local stamps = core.synthesize_timestamps(100, 100, { 5, 5, 5 })
  eq(table.concat(stamps, ","), "100,100,100")
end)

case("timestamps_weights", function()
  local stamps = core.synthesize_timestamps(0, 10, { 25, 25, 25, 25 })
  eq(table.concat(stamps, ","), "0,5,7,10")
end)

case("timestamps_monotonic", function()
  local stamps = core.synthesize_timestamps(0, 100, { 7, 3, 25, 1, 9, 40, 18, 5, 11 })
  for i = 2, #stamps do
    assert(stamps[i] >= stamps[i - 1], "not monotonic at line " .. i)
  end
  eq(stamps[1], 0)
  eq(stamps[#stamps], 100)
end)

case("iso_utc_vectors", function()
  eq(core.iso_utc(0), "1970-01-01T00:00:00Z")
  eq(core.iso_utc(1784561608), "2026-07-20T15:33:28Z")
  eq(core.iso_utc(1787146926), "2026-08-19T13:42:06Z")
end)

local function user_text(texts)
  local content = {}
  for _, text in ipairs(texts) do
    content[#content + 1] = { type = "text", text = text }
  end
  return { role = "user", content = content }
end

case("map_user_text_joins", function()
  local mapped = core.map_message(user_text({ "one", "two" }))
  eq(mapped.type, "user")
  eq(mapped.message.role, "user")
  eq(mapped.message.content, "one\ntwo")
end)

case("map_user_display_text_wins", function()
  local msg = user_text({ "ai text" })
  msg.display_text = "raw text"
  eq(core.map_message(msg).message.content, "raw text")
end)

case("map_user_empty_display_text_falls_back", function()
  local msg = user_text({ "[Cancelled by user]" })
  msg.display_text = ""
  eq(core.map_message(msg).message.content, "[Cancelled by user]")
end)

case("map_user_tool_results", function()
  local msg = {
    role = "user",
    content = {
      { type = "tool_result", tool_use_id = "t1", content = "ok" },
      { type = "tool_result", tool_use_id = "t2", content = "boom", is_error = true },
      { type = "tool_result", tool_use_id = "t3", content = "fine", is_error = false },
    },
  }
  local content = core.map_message(msg).message.content
  eq(#content, 3)
  eq(content[1].tool_use_id, "t1")
  eq(content[1].is_error, nil)
  eq(content[2].is_error, true)
  eq(content[3].is_error, nil)
end)

case("map_user_mixed_drops_text", function()
  local msg = {
    role = "user",
    content = {
      { type = "text", text = "look at this" },
      { type = "tool_result", tool_use_id = "t1", content = "ok" },
    },
  }
  local content = core.map_message(msg).message.content
  eq(#content, 1)
  eq(content[1].type, "tool_result")
end)

case("map_assistant_block_order", function()
  local msg = {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "hmm" },
      { type = "redacted_thinking", data = "x" },
      { type = "text", text = "hello" },
      { type = "tool_use", id = "t1", name = "bash", input = { command = "ls" } },
      { type = "image", source = {} },
      { type = "text", text = "   " },
    },
  }
  local content = core.map_message(msg).message.content
  eq(#content, 3)
  eq(content[1].type, "thinking")
  eq(content[2].type, "text")
  eq(content[2].text, "hello")
  eq(content[3].type, "tool_use")
  eq(content[3].id, "t1")
  eq(content[3].name, "bash")
end)

case("map_assistant_all_dropped_nil", function()
  local msg = {
    role = "assistant",
    content = {
      { type = "redacted_thinking", data = "x" },
      { type = "image", source = {} },
      { type = "text", text = "" },
    },
  }
  eq(core.map_message(msg), nil)
end)

local function entry(role, blocks, ts)
  return { role = role, blocks = blocks, ts = ts }
end

local function task_use(id)
  return { type = "tool_use", id = id, name = "task", input = {} }
end

local function tool_result(id)
  return { type = "tool_result", tool_use_id = id, content = "done" }
end

case("plan_sub_numbering_orphans_last", function()
  local parent = {
    entry("assistant", { task_use("a") }, 10),
    entry("user", { tool_result("a") }, 20),
    entry("assistant", { task_use("b") }, 30),
    entry("user", { tool_result("b") }, 40),
  }
  local planned = core.plan_sub_files(parent, { "a", "b", "orphan" }, 0, 100)
  eq(#planned, 3)
  eq(planned[1].key, "a")
  eq(planned[1].n, 1)
  eq(planned[2].key, "b")
  eq(planned[2].n, 2)
  eq(planned[3].key, "orphan")
  eq(planned[3].n, 3)
  eq(planned[3].t_start, 0)
  eq(planned[3].t_end, 100)
end)

case("plan_sub_windows_result_and_interrupted", function()
  local parent = {
    entry("assistant", { task_use("a") }, 10),
    entry("user", { tool_result("a") }, 20),
    entry("assistant", { task_use("b") }, 30),
    entry("user", { { type = "text", text = "next" } }, 50),
  }
  local planned = core.plan_sub_files(parent, { "a", "b" }, 0, 100)
  eq(planned[1].t_start, 10)
  eq(planned[1].t_end, 20)
  eq(planned[2].t_start, 30)
  eq(planned[2].t_end, 50)
end)

case("sub_timestamps_interior", function()
  local stamps = {}
  for i = 1, 4 do
    stamps[i] = core.sub_timestamp(10, 20, i, 4)
  end
  eq(table.concat(stamps, ","), "11,13,16,18")
  for i = 1, 4 do
    assert(stamps[i] >= 10 and stamps[i] < 20, "outside window at line " .. i)
    if i > 1 then
      assert(stamps[i] >= stamps[i - 1], "not monotonic at line " .. i)
    end
  end
end)

case("sub_timestamps_degenerate", function()
  for i = 1, 3 do
    eq(core.sub_timestamp(42, 42, i, 3), 42)
  end
end)

th.report()
