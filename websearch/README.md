# Websearch Plugin

Replaces maki's builtin `websearch` tool (Exa AI, hosted, needs an API key) with a
self-hosted [SearXNG](https://docs.searxng.org/) instance. Same tool name, so nothing
else in your config or prompts has to change.

## Requirements

A SearXNG instance that will answer `format=json`. That has to be switched on in the
instance's `settings.yml` — asking for a format that is not listed returns `403`:

```yaml
search:
  formats:
    - html
    - json
```

Check it from the shell before debugging the plugin:

```sh
curl 'http://localhost:8888/search?q=maki&format=json' | head -c 200
```

## Installation

1. Copy the module into maki's config dir:

   ```sh
   mkdir -p ~/.config/maki/lua
   cp init.lua ~/.config/maki/lua/websearch.lua
   ```

2. Grant `net` in `~/.config/maki/plugin.toml`, creating the file if needed:

   ```toml
   [permissions]
   net = true
   ```

   This manifest gates **every** Lua file in `~/.config/maki`, including other modules
   under `lua/`. A missing manifest denies everything; there is no per-module grant.

3. In `~/.config/maki/init.lua`, turn the builtin off, allowlist the instance, and load
   the module:

   ```lua
   maki.setup({
       net = {
           allowed_private_hosts = { "localhost:8888" },
       },
       plugins = {
           websearch = { enabled = false },
       },
   })

   require("websearch")
   ```

   Both lines matter. `plugins.websearch = { enabled = false }` is what hands the
   `websearch` tool name to this plugin — with the builtin still enabled the load fails
   with `plugin ... attempted to shadow existing tool 'websearch'`. The allowlist is what
   lets `maki.net` reach a box on your own network at all; see
   [Network](#why-the-allowlist-is-needed).

4. Restart maki, or reload the config.

Verify the override took effect:

```sh
maki prompt --tools | grep -q SearXNG && echo "override active"   # no output = builtin still owns it
```

## Configuration

| Setting | Default | How |
|---------|---------|-----|
| Instance URL | `http://localhost:8888` | `SEARXNG_URL` environment variable |
| Request timeout | 10s `fast` / 30s `deep` | `PROFILES` in `init.lua` |
| Result count | 8 per call | `num_results` tool argument |
| Language | instance default | `language` tool argument |

`SEARXNG_URL` is read from the environment maki starts in, per search:

```sh
SEARXNG_URL=http://searx.lan:8888 maki
```

Anything other than `localhost:8888` needs a matching entry in
`net.allowed_private_hosts`, and a public HTTPS instance needs neither the allowlist nor
the plain-`http` exception.

## Usage

| Argument | Type | Notes |
|----------|------|-------|
| `query` | string | Required. |
| `num_results` | integer | Defaults to 8. SearXNG returns far more; the plugin trims. |
| `language` | string | SearXNG language code, e.g. `en`, `de`, `zh-CN`. Omit for the instance default. |
| `profile` | string | `fast` (default) or `deep`. See [Profiles](#profiles). |

`categories` is always sent explicitly and `pageno` is pinned to 1, so there is no paging and
no image categories. Output is truncated by `agent.max_output_lines` /
`agent.max_output_bytes` like any other tool.

## Profiles

`profile` chooses the engine set, and with it the request timeout.

| Profile | Sent as | Timeout | What runs |
|---------|---------|---------|-----------|
| `fast` (default) | `categories=general` | 10s | bing, duckduckgo, google cse, mojeek, seznam, wikipedia, wikidata, yahoo, yandex. About a second when warm. |
| `deep` | `categories=deep` | 30s | arxiv, brave, fynd, google news, qwant, reuters, semantic scholar, startpage, startpage news, wiby. News, academic, browser-backed. |

Use `deep` when a `fast` search came back thin, or when the query needs news, academic
literature, or obscure coverage. Otherwise stay on `fast`: `deep` costs 3–25s, and its engines
are the ones most likely to fail.

* **The browser solver is an instance-side opt-in.** Several `deep` engines (startpage,
  startpage news, qwant) sit behind scraping protection and only answer when the instance has a
  browser-solving plugin configured. Without it they simply show up as failed.
* **Failed engines self-suspend.** SearXNG parks an engine for 30–120s after it errors, so
  consecutive `deep` searches report a shifting `[unresponsive engines]` note. Repeated notes
  are expected on `deep`, not a plugin fault.

**`language` biases ranking, it does not translate.** Searching `latest news today` with
`language=zh-CN` returns CNN; searching `上海 天气 预警` returns Shanghai government and
Chinese weather sites. If you want results in a language, query in that language and treat
`language` as a nudge.

## Notes

* **Why the allowlist is needed.** `maki.net` upgrades `http://` to `https://` and blocks
  private, loopback and metadata addresses to stop the model from redirecting it. Listing a
  host in `net.allowed_private_hosts` exempts it from both, since a service on your LAN
  usually has no certificate. Every redirect hop is checked again against that list.
* **Permissions.** The tool declares `permission = "net"` with `permission_scopes =
  "query"`, mirroring the builtin, so it goes through the normal network permission prompt
  and each prompt names the query. `permission_scopes` without `permission` is a hard
  registration error, so the pair is not optional.
* **No shell.** Requests go through `maki.net`, so the plugin needs neither `curl` nor the
  `run` permission.
* **Degraded results are reported.** When engines fail, SearXNG fills in
  `unresponsive_engines` and the plugin appends it to the output:

  ```
  [unresponsive engines] qwant: timeout, startpage: Suspended: CAPTCHA
  ```

  Fewer engines means a narrower, less relevant result pool, which is usually the real
  explanation when results look unrelated to the query. `Suspended: CAPTCHA` means that
  engine is blocked and needs an engine config or proxy change on the instance — the plugin
  cannot fix it. The note is suppressed when every engine answers, so it costs nothing when
  the instance is healthy.
* **Failures** — transport errors, non-2xx (with a 200-byte body preview), and unparseable
  JSON each come back as a tool error rather than an empty result. A SearXNG instance that
  stalls on upstream engines will surface as a timeout once the profile's budget (10s `fast`,
  30s `deep`) is spent.
