# Retitle Plugin

Maki names a session from the first 60 characters of your opening prompt. Long
sessions keep a title that says little. This plugin asks a model to summarize
each session instead, so the `/sessions` dialog shows what every session was
about.

## How it works

1. The plugin reads the stored transcript of a session from
   `~/.local/state/maki/sessions/<id>.jsonl`.
2. It builds a short digest: the first request, later user messages, the final
   assistant replies, and the sub-task names.
3. A tool-less subagent on your current model writes one title line.
4. `maki.session.set_title` stores it. The next `/sessions` shows it.

Closed sessions work, because the digest comes from the transcript on disk.

A slash command cannot reach a model. So `/retitle` sends one prompt to the
agent of your current session, and that agent calls the `retitle_sessions`
tool. You will see that turn in the transcript. The cost is one short model
call per session, and the title model call makes no tool use.

## Installation

1. Copy the module into maki's config dir:

   ```sh
   mkdir -p ~/.config/maki/lua
   cp init.lua ~/.config/maki/lua/retitle.lua
   ```

2. Add this line to `~/.config/maki/init.lua`:

   ```lua
   require("retitle")
   ```

3. Make sure `~/.config/maki/lua/plugin.toml` grants `fs_read`. The plugin
   needs it to find and read the session files.

4. Run `/reload` inside maki.

## Usage

- `/retitle` gives a new title to every session of the current project whose
  title is still the machine-made one.
- `/retitle current` does only the session you type in. `now`, `this`, and `.`
  mean the same.
- `/retitle 00b44fb2` does one session by id prefix, whatever its title says.
- `/retitle force` also replaces titles you set by hand with `/rename`.

Or say it in plain words: "retitle my sessions", or "title this session". The
agent calls the tool for you.

The plugin keeps hand-made titles safe. It recomputes maki's auto-generated
title for each session and replaces only an exact match. Without `force`, a
session you renamed stays as you left it.

## Settings

The module returns a `setup` function. Call it from `init.lua` after
`require("retitle")` if you want other behavior:

```lua
require("retitle").setup({ only_auto_titles = false })
```

With `only_auto_titles = false`, every `/retitle` run overwrites all titles.

## Known limits

- A session you never saved has no transcript to digest. The tool reports it
  as an error line and moves on.
- The transcript file grows while you work, so the digest of the current
  session may miss the newest messages.
- Titles are cut at 60 characters, the same limit maki uses.
