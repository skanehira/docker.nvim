--- 公開ポートの文字列から、ブラウザで開ける URL を組み立てる。
---
--- `docker ps` の PORTS は `0.0.0.0:8080->80/tcp, :::8080->80/tcp` のような形。
--- 待ち受けアドレスが不定 (`0.0.0.0` / `::`) のものはそのままでは接続できないため
--- `localhost` に読み替える。IPv4 と IPv6 で同じポートが 2 回出るので重複は除く。
local M = {}

--- 接続先として使えないアドレス。
local WILDCARDS = { ["0.0.0.0"] = true, ["::"] = true, ["[::]"] = true }

---@param value string|nil
---@return string[] URL の一覧 (ポート番号の昇順、重複なし)
function M.published(value)
  local text = type(value) == "string" and value or ""

  local seen = {}
  local found = {}
  for _, entry in ipairs(vim.split(text, ",", { plain = true, trimempty = true })) do
    -- 公開されているものだけを対象にする (`->` が無い項目はホストへ出ていない)。
    local mapping = vim.trim(entry)
    local host, port, protocol = mapping:match("^(.*):(%d+)%->%d+/(%a+)$")
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
