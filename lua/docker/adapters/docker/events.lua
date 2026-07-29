--- docker events の購読。
---
--- 単一のジョブで container / image / volume / network すべてのイベントを受け取る。
--- `on_stdout` のチャンクは行の途中で切れることがあるため、未完了分を保持して
--- 次のチャンクと連結してから解析する。
local jobs = require("docker.handlers.jobs")

local M = {}

---@class docker.Event
---@field type string    "container" | "image" | "volume" | "network"
---@field action string  "create" | "start" | "stop" | "die" | "destroy" など
---@field id string      対象の ID。volume の場合は Actor.ID にボリューム名が入る
---@field time integer   秒精度の時刻

---@class docker.EventSubscription
---@field stop fun()               意図的な停止
---@field is_alive fun(): boolean

---@type (fun(cmd: string[], handlers: table): integer|nil)|nil
local starter = nil

--- テスト用の差し替え口。nil を渡すと実際のジョブ起動に戻る。
---@param fn (fun(cmd: string[], handlers: table): integer|nil)|nil
function M._set_starter(fn)
  starter = fn
end

--- docker が出す 1 行の JSON を `docker.Event` へ変換する。
--- 時刻は秒精度の `time` を使う。`timeNano` は `vim.json.decode` で
--- 浮動小数点化され下位桁が落ちるため使わない。
---@param raw table
---@return docker.Event|nil
local function to_event(raw)
  if type(raw) ~= "table" or type(raw.Actor) ~= "table" then
    return nil
  end
  local id = raw.Actor.ID
  if type(id) ~= "string" or id == "" then
    return nil
  end
  return {
    type = raw.Type,
    action = raw.Action,
    id = id,
    time = raw.time,
  }
end

---@class docker.EventDecoder
---@field push fun(self: docker.EventDecoder, chunk: string): docker.Event[]

--- チャンクを行に組み立てて解析する。行が揃うまではイベントを返さない。
---@return docker.EventDecoder
function M.new_decoder()
  return {
    _buffer = "",
    push = function(self, chunk)
      self._buffer = self._buffer .. (chunk or "")

      local found = {}
      while true do
        local newline = self._buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = self._buffer:sub(1, newline - 1)
        self._buffer = self._buffer:sub(newline + 1)

        if line:match("%S") then
          local ok, raw = pcall(vim.json.decode, line)
          if ok then
            local event = to_event(raw)
            if event then
              table.insert(found, event)
            end
          end
        end
      end
      return found
    end,
  }
end

--- 実際のジョブ起動。
---@param cmd string[]
---@param handlers table
---@return integer|nil
local function default_starter(cmd, handlers)
  return vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if data then
        handlers.on_stdout(table.concat(data, "\n"))
      end
    end,
    on_exit = function(_, code)
      handlers.on_exit(code)
    end,
  })
end

--- イベントを購読する。
---@param opts { since: string|nil, on_event: fun(ev: docker.Event), on_disconnect: fun(intentional: boolean)|nil }
---@return docker.EventSubscription
function M.subscribe(opts)
  local cmd = { "docker", "events", "--format", "{{json .}}" }
  if opts.since then
    table.insert(cmd, "--since")
    table.insert(cmd, opts.since)
  end

  local decoder = M.new_decoder()
  -- 意図的な停止と外部要因の終了は同じ終了コードになる。先にフラグを立てて区別する。
  local stopping = false
  local alive = true
  local job_id

  local start = starter or default_starter
  job_id = start(cmd, {
    on_stdout = function(chunk)
      for _, event in ipairs(decoder:push(chunk)) do
        opts.on_event(event)
      end
    end,
    on_exit = function()
      alive = false
      if job_id then
        jobs.unregister(job_id)
      end
      if opts.on_disconnect then
        opts.on_disconnect(stopping)
      end
    end,
  })

  if type(job_id) == "number" and job_id > 0 then
    jobs.register(job_id)
  else
    alive = false
  end

  return {
    stop = function()
      if not alive then
        return
      end
      stopping = true
      alive = false
      if job_id then
        jobs.unregister(job_id)
        pcall(vim.fn.jobstop, job_id)
      end
    end,
    is_alive = function()
      return alive
    end,
  }
end

return M
