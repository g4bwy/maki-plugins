local DEFAULT_SEARXNG_URL = "http://localhost:8888"
local DEFAULT_NUM_RESULTS = 8
local REQUEST_TIMEOUT_SECS = 30

local truncate = require("maki.truncate")
local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")

local opts = maki.api.register_options(output_limits.extend({}))

local function web_view_opts(ctx)
  local tol = ctx:tool_output_lines()
  return { max_lines = (tol and tol.web) or 3, keep = "head" }
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
  name = "websearch2",
  kind = "fetch",
  description = "Search the web for real-time information using SearXNG.\n\n"
    .. "Today's date is "
    .. os.date("%Y-%m-%d")
    .. ".\n\n"
    .. "- Use for current events, documentation, APIs, or anything not in local files.\n"
    .. "- Prefer specific, targeted queries over broad ones.\n"
    .. "- Results include page titles, URLs, and content snippets.",

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query", required = true },
      num_results = { type = "integer", description = "Number of results to return (default 8)" },
    },
  },
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

    local num_results = input.num_results or DEFAULT_NUM_RESULTS
    local base_url = maki.uv.os_getenv("SEARXNG_URL") or DEFAULT_SEARXNG_URL

    local encoded_query = query:gsub(" ", "+")
    local url = string.format(
      "%s/search?q=%s&format=json&categories=general&pageno=1",
      base_url, encoded_query
    )

    local max_lines, max_bytes = output_limits.resolve(opts, ctx)

    local job_id = maki.fn.jobstart("curl -s '" .. url .. "'", {
      timeout = REQUEST_TIMEOUT_SECS * 1000,
    })
    if not job_id then
      return { llm_output = "error: failed to start curl", is_error = true }
    end

    local result = maki.fn.jobwait(job_id, REQUEST_TIMEOUT_SECS * 1000)
    if not result then
      return { llm_output = "error: curl timed out", is_error = true }
    end

    if result.exit_code ~= 0 then
      return { llm_output = "error: curl failed with exit code " .. tostring(result.exit_code), is_error = true }
    end

    local body = result.stdout or ""
    local data, parse_err = maki.json.decode(body:gsub("[\n\r]", ""))
    if not data then
      return { llm_output = "error: failed to parse response: " .. tostring(parse_err), is_error = true }
    end

    local results = data.results
    if not results or #results == 0 then
      return { llm_output = "No search results found" }
    end

    if #results > num_results then
      local trimmed = {}
      for i = 1, num_results do
        trimmed[i] = results[i]
      end
      results = trimmed
    end

    local text = format_results(results)
    local llm_output = truncate(text, max_lines, max_bytes)

    return {
      llm_output = llm_output,
      body = ToolView.restore(text, web_view_opts(ctx)),
    }
  end,
})
