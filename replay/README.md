Export session logs to a format compatible with https://github.com/es617/claude-replay

Usage:

/replay <session-id> [output dir]

Default output dir is the current directory. The command writes one
`<session-id>.jsonl` for the main conversation plus one
`<session-id>.sub-N.jsonl` per sub-agent, then prints the claude-replay
command that turns them into HTML.

Convert to HTML:

claude-replay <output dir>/<session id>.jsonl [<output dir>/<session id>.jsonl.sub-1 ...] -o output.html

Large sessions
--------------

A long session passes 1 GiB, and the Lua inside maki will not hold a file that
size in one string. So the plugin reads a big session in 8 MiB windows with
`dd`, `base64` and `tr`, and writes output in batches. It holds only the main
conversation lines in memory; it re-reads each file to stream the sub-agents.

Put `dd`, `base64` and `tr` on PATH for sessions over 64 MiB. Without them the
plugin falls back to one whole read, which fails past 1 GiB with an error in
the flash bar instead of a crash.

Run the tests:

    lua5.1 replay_spec.lua          # conversion core, no I/O
