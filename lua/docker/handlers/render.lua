--- Coalescing and debouncing of render requests.
---
--- `docker events` carries events for the whole daemon (operations from other processes get mixed in).
--- Rendering without coalescing spins uselessly on every bulk change such as `docker compose up`.
local M = {}

--- Wait time. The value was settled by the measurements taken in phase 4.
--- The goal is 1 second from receiving an event to reflecting it (G9). The breakdown is
--- "debounce 100ms + refetching the target 20-60ms + rendering 2ms", which leaves about 850ms of headroom.
M.DELAY_MS = 100

---@class docker.RenderTimer
---@field stop fun()

---@type (fun(delay: integer, callback: fun()): docker.RenderTimer)|nil
local timer_factory = nil

--- key -> pending timer
---@type table<string, docker.RenderTimer>
local pending = {}

--- Injection point for tests. Passing nil restores the real timer.
---@param factory (fun(delay: integer, callback: fun()): docker.RenderTimer)|nil
function M._set_timer_factory(factory)
  timer_factory = factory
end

--- For tests. Discards the pending requests.
function M._reset()
  for key, timer in pairs(pending) do
    timer.stop()
    pending[key] = nil
  end
  pending = {}
end

---@param delay integer
---@param callback fun()
---@return docker.RenderTimer
local function default_timer(delay, callback)
  -- The callback of `vim.defer_fn` runs on the main loop.
  -- Cancellation is done with a flag rather than by stopping the timer (one pending timer
  -- just fires uselessly, and with a wait as short as 100ms there is no real harm).
  local cancelled = false
  vim.defer_fn(function()
    if not cancelled then
      callback()
    end
  end, delay)
  return {
    stop = function()
      cancelled = true
    end,
  }
end

--- Requests a render. Consecutive requests with the same key are coalesced into one.
--- When coalesced, the draw passed last is the one executed (so that the newest state is drawn).
---@param key string
---@param draw fun()
function M.request(key, draw)
  M.cancel(key)

  local create = timer_factory or default_timer
  pending[key] = create(M.DELAY_MS, function()
    pending[key] = nil
    draw()
  end)
end

--- Cancels the pending render request.
---@param key string
function M.cancel(key)
  local timer = pending[key]
  if timer then
    timer.stop()
    pending[key] = nil
  end
end

return M
