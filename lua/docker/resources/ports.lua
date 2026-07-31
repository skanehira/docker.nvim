--- Builds URLs that can be opened in a browser from the published ports string.
---
--- The PORTS column of `docker ps` looks like `0.0.0.0:8080->80/tcp, :::8080->80/tcp`.
--- Entries whose listening address is unspecified (`0.0.0.0` / `::`) cannot be connected to as
--- they are, so they are read as `localhost`. The same port appears twice for IPv4 and IPv6, so
--- duplicates are removed.
local M = {}

--- Addresses that cannot be used as a connection target.
local WILDCARDS = { ["0.0.0.0"] = true, ["::"] = true, ["[::]"] = true }

---@param value string|nil
---@return string[] the list of URLs (ascending by port number, without duplicates)
function M.published(value)
  local text = type(value) == "string" and value or ""

  local seen = {}
  local found = {}
  for _, entry in ipairs(vim.split(text, ",", { plain = true, trimempty = true })) do
    -- Only published entries are considered (an entry without `->` is not exposed on the host).
    local mapping = vim.trim(entry)
    -- Besides `0.0.0.0:8080->80/tcp`, range publishing such as
    -- `0.0.0.0:8000-8002->8000-8002/tcp` is also handled (the head of the range represents it).
    local host, port, protocol = mapping:match("^(.*):(%d+)%-?%d*%->[%d%-]+/(%a+)$")
    if host and protocol == "tcp" then
      if WILDCARDS[host] then
        host = "localhost"
      end
      local url = ("http://%s:%s"):format(host, port)
      if not seen[url] then
        seen[url] = true
        table.insert(found, { url = url, port = tonumber(port) })
      end
    end
  end

  table.sort(found, function(a, b)
    return a.port < b.port
  end)

  local urls = {}
  for _, item in ipairs(found) do
    table.insert(urls, item.url)
  end
  return urls
end

return M
