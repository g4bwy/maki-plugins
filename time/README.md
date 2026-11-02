# Session Time Plugin

Splits a session's time into idle, inference (API requests), tool calls, and
sub-agent runs. `/time` opens a popup in the style of maki's own `/usage` modal.
It reports both hot (the plugin watched the whole session) and cold (you open it
on a session it never saw, after a reload or restart), because it reads the timing
from the transcript rather than from memory.

## What it tracks

| Line | Meaning |
|------|---------|
| `wall clock` | The session time the plugin accounts for: `idle + inference + tool + sub-agents`. |
| `idle (awaiting input)` | Time waiting between a finished reply and the next prompt. |
| `inference (api requests)` | Time the model spent generating, request start to response. |
| `tool calls` | Time a local tool ran (`read`, `bash`, an MCP call, ...). |
| `sub-agents` | Time the session was blocked on a `task` or `batch` call. Tracked apart, never counted as a tool call. |

The four lower lines add up to `wall clock`. Each shows a percentage share, and a
footer gives the turn count, the tool-call count, the sub-agent count, and what
the session is doing now.

## How it measures

maki stamps every transcript message with `created_at` (epoch milliseconds). The
plugin reads the transcript through `maki.session.messages()` and charges the
gap that ends at each message by what that message is:

```
message is a tool result    ->  sub-agents, if the call was `task`/`batch`; else tool call
message is an assistant     ->  inference
message is a user prompt    ->  idle (the wait before you sent it)
```

The tool's name is read from its `tool_use` block by id, so a result that closes a
`task` or `batch` call goes to sub-agents, and any other result to tool calls.

The turn in progress is not a message yet, so while a request or tool is live the
panel adds the seconds since the last message to the matching bucket, from the
`TurnStart` / `ToolStart` / `ToolDone` events. Rebuilding happens only while the
popup is open, so there is no background cost and nothing to persist: the
transcript is the store, and it survives reload, restart, and compaction.

## Requirements

This needs a maki built with per-message timestamps on the transcript. Upstream
maki does not store them yet. Two source changes are required (see `core.patch`
in this directory, apply with `git apply` in a maki checkout, then
`cargo build --release`):

- `Message` gains a storage-only `created_at: Option<u64>`, serialized in the
  hand-written `impl Serialize` (skipped when absent, so it is additive and needs
  no log-format bump). Providers build their wire body by hand, so the field never
  reaches an API.
- `History::push` sets `created_at` on append, and `maki.session.messages` /
  `export` forward it to Lua.

Messages written before that change carry no timestamp, so a pre-existing session
shows time only from its first stamped message on.

## Installation

1. Copy the module into maki's config dir:

   ```sh
   mkdir -p ~/.config/maki/lua
   cp init.lua ~/.config/maki/lua/time.lua
   ```

2. Load it from `~/.config/maki/init.lua`:

   ```lua
   require("time")
   ```

3. The plugin calls `maki.session.messages()`, which needs `session_read`. Add it
   to the grant file that covers the plugin, for example
   `~/.config/maki/plugin.toml`:

   ```toml
   [permissions]
   session_read = true
   ```

4. Restart maki, or run `/reload`.

## Usage

Run `/time` to open the panel, and `/time` again to close it. It redraws once a
second and folds in live time as turns and tools run, so a running turn climbs in
real time. The panel shows the session that was focused when you opened it.

The panel is passive: it never takes keyboard focus, so you keep typing in the
chat behind it, and it cannot strand the keyboard or freeze the app while a turn
runs. That is deliberate. A focused plugin window whose update loop also calls
`maki.session.*` parks the single Lua thread on the UI thread, and a finishing
turn waiting on that thread deadlocks the whole UI (you had to force-kill maki).
The update loop here only touches in-memory state, so it cannot cause that.

The panel reads the transcript once, when you open it, then advances from live
events. Re-reading the transcript on every redraw would starve the shared Lua
thread the same way.

## Limitations

- Whole seconds on screen. Buckets accumulate in milliseconds, so many fast calls
  still add up, but a single sub-second gap shows as `0s`.
- Sub-agent time is the window the parent was blocked on a `task`/`batch` call. It
  is not the sub-agent's own work broken into inference and tools: that split lives
  in the sub-agent transcript, which no plugin API returns (only a core change
  could expose it). A sub-agent moved to the background (Ctrl+B) runs while the
  parent does other things, so its wall time is counted under whatever the parent
  was doing then, not added twice.
- The idle line is the wait between replies. Time with maki fully closed is not in
  the transcript gaps, so it is not counted, rather than guessed as idle.
- A message that is neither an assistant reply, a tool result, nor a user prompt (a
  background notice, a context update) does not start or end a bucket; the gap
  around it is left out rather than misfiled.
