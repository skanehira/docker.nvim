--- Subscription to docker events.
---
--- A single job receives all of the container / image / volume / network events.
--- A chunk of `on_stdout` can be cut in the middle of a line, so the incomplete remainder is kept
--- and concatenated with the next chunk before parsing.
--- On a disconnect it resubscribes with a growing wait time, and after the fixed number of attempts
--- it gives up and prompts for a manual refresh.
local jobs = require("docker.handlers.jobs")

local M = {}

---@class docker.Event
---@field type string    "container" | "image" | "volume" | "network"
---@field action string  "create" | "start" | "stop" | "die" | "destroy" and so on
---@field id string      ID of the target. For a volume, Actor.ID holds the volume name
---@field time integer   Timestamp with second precision

---@class docker.EventSubscription
---@field stop fun()               Intentional stop
---@field is_alive fun(): boolean

--- Wait time before resubscribing (milliseconds). Tried up to 5 times.
local RETRY_DELAYS = { 1000, 2000, 4000, 8000, 16000 }

---@type (fun(cmd: string[], handlers: table): integer|nil)|nil
local starter = nil

---@type (fun(delay: integer, callback: fun()))|nil
local waiter = nil

--- Swap point for tests. Passing nil restores the real job start.
---@param fn (fun(cmd: string[], handlers: table): integer|nil)|nil
function M._set_starter(fn)
  starter = fn
end

--- Swap point for tests. Passing nil restores the real waiting.
---@param fn (fun(delay: integer, callback: fun()))|nil
function M._set_waiter(fn)
  waiter = fn
end

--- Converts one line of JSON emitted by docker into a `docker.Event`.
--- The timestamp uses `time`, which has second precision. `timeNano` is not used because
--- `vim.json.decode` turns it into a floating point number and the low digits are lost.
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

--- Assembles chunks into lines and parses them. It returns no event until a line is complete.
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

--- The real job start.
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

--- Subscribes to events. On a disconnect it automatically tries to resubscribe.
---@param opts { since: string|nil, on_event: fun(ev: docker.Event), on_disconnect: fun(intentional: boolean)|nil, on_reconnect: fun()|nil, on_giveup: fun()|nil }
---@return docker.EventSubscription
function M.subscribe(opts)
  -- An intentional stop and a termination caused from the outside produce the same exit code.
  -- We raise a flag beforehand to tell them apart.
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
        -- Chunks that arrive after the stop are not delivered.
        if stopping or not alive then
          return
        end
        for _, event in ipairs(decoder:push(chunk)) do
          -- The arrival of an event is the proof of recovery. The job merely having started is not
          -- enough (jobstart succeeds even when the daemon is down).
          attempt = 0
          -- The starting point for resubscribing. What was missed while waiting is reconciled by the
          -- full refetch in on_reconnect.
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
      -- Once resubscribed, fill in what was missed while waiting with a full refetch.
      if is_retry and opts.on_reconnect then
        opts.on_reconnect()
      end
      return true
    end

    alive = false
    return false
  end

  --- Resubscription after a disconnect. Tried up to the fixed number of times with a growing wait time.
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
    -- Silently dropping the fact that it could not start would make it look subscribed while it is not.
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
