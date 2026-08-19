# Goal Plugin

Mimics Claude Code's `/goal` functionality.

## Usage

* `/goal <condition>` – set or replace active goal for current session. Starts a turn immediately with the condition as directive.
* `/goal` – show status: condition, elapsed time, turns evaluated, last evaluator reason.
* `/goal clear` – clear active goal. Aliases: `stop`, `off`, `reset`, `none`, `cancel`.

## Behavior

* One goal per session, stored under `maki.env.state_dir()/goal/<session_id>.json`.
* On each `TurnEnd` autocmd, evaluates condition against transcript using a fast model subagent via `maki.agent.session` and `maki.agent.resolve_model`.
* Evaluator returns YES/NO + reason. On NO, guidance is injected via `maki.session.notify`. On YES, goal is marked achieved and cleared.
* Works alongside auto mode; does not change permissions.

## Limitations

* Transcript collection is placeholder; real implementation needs session history API.
* Evaluation is model-judged, not deterministic. Add turn caps in condition e.g. `or stop after 20 turns`.
