-- Wiki-style Contents pane for the chat transcript.
--
-- A left split lists every user turn; folding one open shows its thinking
-- and reply blocks. Clicking or pressing M-CR scrolls the chat to the
-- picked block; clicking the marker folds. Needs a maki build with
-- maki.ui.transcript_outline, maki.ui.scroll_to_block and window click
-- events (win:recv type "click").

local PANE_WIDTH = 34
local TITLE = " Contents "
local NUM_W = 3
local COL_PREFIX_W = NUM_W + 3
local SUB_PREFIX = string.rep(" ", COL_PREFIX_W) .. ". "
local MARKER_COLLAPSED = "▸"
local MARKER_EXPANDED = "▾"
local MARKER_NONE = " "
local EMPTY_LABEL = "no turns yet"
local NOT_MAIN = "Contents tracks the main transcript"
local NO_JUMP_API = "this maki build lacks the transcript outline api"
local NAV_KEYS = { "<M-j>", "<M-k>", "<M-CR>", "<M-Up>", "<M-Down>", "<M-o>" }

local pane = nil

-- The outline call already filtered to jumpable blocks and ranked them in
-- display order; grouping is all that is left. A turn opens a group, the
-- thinking and reply entries that follow join it. Kind counts stay global
-- (children before the first turn would count too), because they are the
-- ordinals maki.ui.scroll_to_block answers to.
local function build_turns()
  local items, err = maki.ui.transcript_outline()
  if not items then
    return nil, err
  end
  local turns = {}
  local seen = { thinking = 0, reply = 0 }
  for _, item in ipairs(items) do
    if item.kind == "turn" then
      turns[#turns + 1] = { text = item.text, blocks = {}, kind_seen = {} }
    else
      seen[item.kind] = seen[item.kind] + 1
      if #turns > 0 then
        local turn = turns[#turns]
        turn.kind_seen[item.kind] = (turn.kind_seen[item.kind] or 0) + 1
        turn.blocks[#turn.blocks + 1] = {
          kind = item.kind,
          n = seen[item.kind],
          label = item.kind .. " " .. turn.kind_seen[item.kind],
        }
      end
    end
  end
  return turns
end

local ELLIPSIS = "..."
local function clip(text, width)
  if width <= 0 then
    return ""
  end
  if maki.ui.display_width(text) <= width then
    return text
  end
  if width <= #ELLIPSIS then
    return maki.ui.truncate_text(text, width).head
  end
  return maki.ui.truncate_text(text, width - #ELLIPSIS).head .. ELLIPSIS
end

local function render(p)
  if #p.turns == 0 then
    p.buf:set_lines({ { { EMPTY_LABEL, "dim" } } })
    p.row_map = {}
    p.row_headers = {}
    return
  end
  local lines, row_map, row_headers = {}, {}, {}
  local text_width = p.width - COL_PREFIX_W
  for n, turn in ipairs(p.turns) do
    local expanded = p.expanded[n]
    local marker = MARKER_NONE
    if #turn.blocks > 0 then
      marker = expanded and MARKER_EXPANDED or MARKER_COLLAPSED
    end
    row_map[#lines + 1] = { kind = "turn", n = n, turn = n }
    row_headers[#lines + 1] = true
    lines[#lines + 1] = {
      { string.format("%" .. NUM_W .. "d ", n), "tool" },
      { marker .. " ", "path" },
      { clip(turn.text, text_width) },
    }
    if expanded then
      for _, b in ipairs(turn.blocks) do
        row_map[#lines + 1] = { kind = b.kind, n = b.n, turn = n }
        lines[#lines + 1] = { { SUB_PREFIX .. b.label, "dim" } }
      end
    end
  end
  p.buf:set_lines(lines)
  p.row_map = row_map
  p.row_headers = row_headers
end

local function entry_key(e)
  return e.kind .. "#" .. e.n
end

local function row_of_key(p, key)
  for row, e in ipairs(p.row_map) do
    if entry_key(e) == key then
      return row
    end
  end
end

local function clamp_cursor(p)
  if #p.row_map == 0 then
    p.cursor = nil
    return
  end
  local turn_row = row_of_key(p, "turn#" .. p.cursor_turn)
  p.cursor = row_of_key(p, p.cursor_key) or turn_row or math.min(p.cursor or 1, #p.row_map)
  p.cursor_turn = p.row_map[p.cursor].turn
  p.cursor_key = entry_key(p.row_map[p.cursor])
  p.win:set_cursor(p.cursor)
end

local function jump(p, e)
  if p.task ~= "main" then
    maki.ui.flash(NOT_MAIN)
    return
  end
  local ok, err = maki.ui.scroll_to_block(e.kind, e.n)
  if not ok then
    maki.ui.flash(err)
  end
end

local function move(p, delta)
  if #p.row_map == 0 then
    return
  end
  p.cursor = math.min(math.max((p.cursor or 1) + delta, 1), #p.row_map)
  local e = p.row_map[p.cursor]
  p.cursor_turn, p.cursor_key = e.turn, entry_key(e)
  p.win:set_cursor(p.cursor)
end

local function toggle_turn(p, n)
  p.expanded[n] = not p.expanded[n] or nil
  render(p)
  clamp_cursor(p)
end

local function handle_key(p, key)
  if key == "<M-j>" or key == "<M-Down>" then
    move(p, 1)
  elseif key == "<M-k>" or key == "<M-Up>" then
    move(p, -1)
  elseif key == "<M-o>" and p.cursor then
    toggle_turn(p, p.row_map[p.cursor].turn)
  elseif key == "<M-CR>" and p.cursor then
    jump(p, p.row_map[p.cursor])
  end
end

local function loop(p)
  while true do
    local ev = p.win:recv()
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      handle_key(p, ev.key)
    elseif ev.type == "click" then
      local e = p.row_map[ev.row]
      if e then
        p.cursor = ev.row
        p.cursor_turn, p.cursor_key = e.turn, entry_key(e)
        p.win:set_cursor(ev.row)
        if p.row_headers[ev.row] and ev.col <= COL_PREFIX_W then
          toggle_turn(p, e.turn)
        else
          jump(p, e)
        end
      end
    elseif ev.type == "resize" then
      p.width = ev.width
      render(p)
      clamp_cursor(p)
    end
  end
  if pane == p then
    pane = nil
  end
end

local function rebuild()
  local p = pane
  if not p or not p.win:is_open() then
    return
  end
  local turns, err = build_turns()
  if not turns then
    maki.ui.flash(err)
    return
  end
  p.turns = turns
  render(p)
  clamp_cursor(p)
end

local function open()
  if not maki.ui.transcript_outline or not maki.ui.scroll_to_block then
    maki.ui.flash(NO_JUMP_API)
    return
  end
  local p = {
    buf = maki.ui.buf({ scratch = true }),
    turns = {},
    row_map = {},
    row_headers = {},
    expanded = {},
    width = PANE_WIDTH,
    task = "main",
    cursor_turn = 1,
    cursor_key = "turn#1",
  }
  local turns, err = build_turns()
  if not turns then
    maki.ui.flash(err)
    return
  end
  p.turns = turns
  p.win = maki.ui.open_win(p.buf, {
    title = TITLE,
    split = "left",
    width = PANE_WIDTH,
    border = "rounded",
    focus = false,
    cursor_line = true,
    keys = NAV_KEYS,
    footer = { { "M-j/k", "move" }, { "M-o", "fold" }, { "M-CR", "jump" } },
  })
  p.width = p.win.width
  render(p)
  clamp_cursor(p)
  pane = p
  maki.async.run(function()
    loop(p)
  end)
end

local function toggle()
  if pane then
    local p = pane
    pane = nil
    p.win:close()
  else
    open()
  end
end

maki.api.register_command({
  name = "/toc",
  description = "Toggle a left pane of turns; click the marker or press M-o to fold, click or M-CR to jump",
  handler = toggle,
})

local function dump()
  local items, err = maki.ui.transcript_outline()
  if not items then
    maki.log.error("toc dump: " .. tostring(err))
    return
  end
  for i, item in ipairs(items) do
    maki.log.info(string.format("toc dump: %d %s %q", i, item.kind, item.text))
  end
  maki.log.info("toc dump: " .. #items .. " jumpable blocks")
  maki.ui.flash("toc: outline dumped to log")
end

maki.api.register_command({
  name = "/toc-dump",
  description = "Write the transcript and turn classification to the log for debugging",
  handler = dump,
})

maki.keymap.set("n", "<M-t>", toggle, { desc = "Toggle contents pane" })

maki.api.create_autocmd({ "TurnStart", "TurnEnd", "ToolDone" }, {
  callback = function()
    if pane then
      maki.async.run(rebuild)
    end
  end,
})

maki.api.create_autocmd("CompactionDone", {
  callback = function()
    if not pane then
      return
    end
    pane.expanded = {}
    pane.cursor_turn = 1
    pane.cursor_key = "turn#1"
    maki.async.run(rebuild)
  end,
})

maki.api.create_autocmd({ "SessionFocusChanged", "SessionReset" }, {
  callback = function()
    if not pane then
      return
    end
    pane.task = "main"
    pane.cursor_turn = 1
    pane.cursor_key = "turn#1"
    pane.expanded = {}
    maki.async.run(rebuild)
  end,
})

maki.api.create_autocmd("TaskFocusChanged", {
  callback = function(ev)
    if pane then
      pane.task = ev.data.id
    end
  end,
})
