--- docker events の購読。
---
--- 単一のジョブで container / image / volume / network すべてのイベントを受け取る。
--- `on_stdout` のチャンクは行の途中で切れることがあるため、未完了分を保持して
--- 次のチャンクと連結してから解析する。
--- 切断したら待機時間を延ばしながら再購読し、規定回数で諦めて手動更新を促す。
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

--- 再購読の待機時間 (ミリ秒)。最大 5 回まで試す。
local RETRY_DELAYS = { 1000, 2000, 4000, 8000, 16000 }

---@type (fun(cmd: string[], handlers: table): integer|nil)|nil
local starter = nil

---@type (fun(delay: integer, callback: fun()))|nil
local waiter = nil

--- テスト用の差し替え口。nil を渡すと実際のジョブ起動に戻る。
---@param fn (fun(cmd: string[], handlers: table): integer|nil)|nil
function M._set_starter(fn)
  starter = fn
end

--- テスト用の差し替え口。nil を渡すと実際の待機に戻る。
---@param fn (fun(delay: integer, callback: fun()))|nil
function M._set_waiter(fn)
  waiter = fn
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

---@param delay integer
---@param callback fun()
local function default_waiter(delay, callback)
  vim.defer_fn(callback, delay)
end

--- イベントを購読する。切断したら自動で再購読を試みる。
---@param opts { since: string|nil, on_event: fun(ev: docker.Event), on_disconnect: fun(intentional: boolean)|nil, on_reconnect: fun()|nil, on_giveup: fun()|nil }
---@return docker.EventSubscription
function M.subscribe(opts)
  -- 意図的な停止と外部要因の終了は同じ終了コードになる。先にフラグを立てて区別する。
  local stopping = false
  local alive = false
  local attempt = 0
  local since = opts.since
  local job_id = nil

  local connect

  ---@param is_retry boolean
  local function start_once(is_retry)
    local cmd = { "docker", "events", "--format", "{{json .}}" }
    if since then
      table.insert(cmd, "--since")
      table.insert(cmd, since)
    end

    local decoder = M.new_decoder()
    local start = starter or default_starter
    local id = start(cmd, {
      on_stdout = function(chunk)
        -- 停止した後に届いたチャンクは配送しない。
        if stopping or not alive then
          return
        end
        for _, event in ipairs(decoder:push(chunk)) do
          -- イベントが届いたことが復旧の証拠。ジョブが起動できただけでは
          -- (デーモンが落ちていても jobstart は成功するため) 復旧とみなせない。
          attempt = 0
          -- 再購読の起点。待機中に取りこぼした分は on_reconnect の全件再取得で整合させる。
          if type(event.time) == "number" then
            since = tostring(event.time)
          end
          opts.on_event(event)
        end
      end,
      on_exit = function()
        alive = false
        if job_id then
          jobs.unregister(job_id)
          job_id = nil
        end
        if opts.on_disconnect then
          opts.on_disconnect(stopping)
        end
        if not stopping then
          connect()
        end
      end,
    })

    if type(id) == "number" and id > 0 then
      job_id = id
      alive = true
      jobs.register(id)
      -- 再購読できたら、待機中に取りこぼした分を全件再取得で埋める。
      if is_retry and opts.on_reconnect then
        opts.on_reconnect()
      end
      return true
    end

    alive = false
    return false
  end

  --- 切断からの再購読。待機時間を延ばしながら規定回数まで試す。
  connect = function()
    attempt = attempt + 1
    local delay = RETRY_DELAYS[attempt]
    if not delay then
      if opts.on_giveup then
        opts.on_giveup()
      end
      return
    end

    local wait = waiter or default_waiter
    wait(delay, function()
      if stopping then
        return
      end
      start_once(true)
    end)
  end

  if not start_once(false) then
    -- 起動できなかったことを黙って捨てると、購読していないのに購読中に見える。
    if opts.on_disconnect then
      opts.on_disconnect(false)
    end
  end

  return {
    stop = function()
      stopping = true
      alive = false
      if job_id then
        jobs.unregister(job_id)
        pcall(vim.fn.jobstop, job_id)
        job_id = nil
      end
    end,
    is_alive = function()
      return alive
    end,
  }
end

return M
