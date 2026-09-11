local DEFAULT_SEARXNG_URL = "http://localhost:8888"
local DEFAULT_NUM_RESULTS = 8
local DEFAULT_PROFILE = "fast"
local PROFILES = {
  fast = { categories = "general", timeout_secs = 10 },
  deep = { categories = "deep", timeout_secs = 30 },
}

local truncate = require("maki.truncate")
local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")

local opts = maki.api.register_options(output_limits.extend({}))

local function web_view_opts(ctx)
  local tol = ctx:tool_output_lines()
  return { max_lines = (tol and tol.web) or 3, keep = "head" }
end

local function url_encode(value)
  return (value:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function engine_note(unresponsive)
  if type(unresponsive) ~= "table" then
    return ""
  end
  local parts = {}
  for _, entry in ipairs(unresponsive) do
    if type(entry) == "table" and type(entry[1]) == "string" then
      local reason = entry[2]
      parts[#parts + 1] = type(reason) == "string" and (entry[1] .. ": " .. reason) or entry[1]
    end
  end
  if #parts == 0 then
    return ""
  end
  return "\n\n[unresponsive engines] " .. table.concat(parts, ", ")
end

local function format_results(results)
  local lines = {}
  for i, r in ipairs(results) do
    local parts = { "#" .. i .. " " .. (r.title or "Untitled") }
    if r.url then
      parts[#parts + 1] = r.url
    end
    if r.content then
      parts[#parts + 1] = r.content
    end
    lines[#lines + 1] = table.concat(parts, "\n")
  end
  return table.concat(lines, "\n\n")
end

maki.api.register_tool({
  name = "websearch",
  kind = "fetch",
  description = "Search the web for real-time information using SearXNG.\n\n"
    .. "Today's date is "
    .. os.date("%Y-%m-%d")
    .. ".\n\n"
    .. "- Use for current events, documentation, APIs, or anything not in local files.\n"
    .. "- Prefer specific, targeted queries over broad ones.\n"
    .. "- Results include page titles, URLs, and content snippets.\n"
    .. "- `profile` picks the engine set. `fast` (default) answers in about a second and is "
    .. "right for nearly every query. `deep` adds news, academic and browser-backed engines, "
    .. "can take 25 seconds, and regularly reports failed engines; use it when a fast search "
    .. "came back thin, or when the query needs obscure sources or broad coverage.",

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query", required = true },
      num_results = { type = "integer", description = "Number of results to return (default 8)" },
      language = {
        type = "string",
        description = "Restrict results to a language: SearXNG code, e.g. \"en\", \"de\", \"zh-CN\". "
          .. "Omit to use the SearXNG instance's configured default.",
      },
      profile = {
        type = "string",
        enum = { "fast", "deep" },
        description = "Engine set. \"fast\" (default): ~1 s, general web engines. "
          .. "\"deep\": slower (up to ~25 s) and broader — news, academic and "
          .. "browser-backed engines. Pick it for coverage or obscure queries.",
      },
    },
  },
  permission = "net",
  permission_scopes = "query",
  audiences = { "main", "research_sub", "general_sub", "interpreter" },

  header = function(input)
    return input.query
  end,

  restore = function(_input, output, _is_error, ctx)
    return ToolView.restore(output, web_view_opts(ctx))
  end,

  handler = function(input, ctx)
    local query = input.query
    if not query then
      return { llm_output = "error: query is required", is_error = true }
    end

    local profile = PROFILES[input.profile or DEFAULT_PROFILE]
    local num_results = input.num_results or DEFAULT_NUM_RESULTS
    local base_url = (maki.uv.os_getenv("SEARXNG_URL") or DEFAULT_SEARXNG_URL):gsub("/$", "")

    local url = string.format(
      "%s/search?q=%s&format=json&categories=%s&pageno=1",
      base_url, url_encode(query), profile.categories
    )
    if input.language then
      url = url .. "&language=" .. url_encode(input.language)
    end

    local max_lines, max_bytes = output_limits.resolve(opts, ctx)

    local resp, err = maki.net.request(url, { timeout = profile.timeout_secs })
    if not resp then
      return { llm_output = "error: " .. tostring(err), is_error = true }
    end

    if resp.status < 200 or resp.status >= 300 then
      return {
        llm_output = "error: HTTP " .. tostring(resp.status) .. ": " .. resp.body:sub(1, 200),
        is_error = true,
      }
    end

    local data, parse_err = maki.json.decode(resp.body)
    if not data then
      return { llm_output = "error: failed to parse response: " .. tostring(parse_err), is_error = true }
    end

    local note = engine_note(data.unresponsive_engines)

    local results = data.results
    if not results or #results == 0 then
      return { llm_output = "No search results found" .. note }
    end

    if #results > num_results then
      local trimmed = {}
      for i = 1, num_results do
        trimmed[i] = results[i]
      end
      results = trimmed
    end

    local text = format_results(results)

    return {
      llm_output = truncate(text, max_lines, max_bytes) .. note,
      body = ToolView.restore(text .. note, web_view_opts(ctx)),
    }
  end,
})
