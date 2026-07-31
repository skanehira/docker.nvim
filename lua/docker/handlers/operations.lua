--- Ledger of in-flight operations.
---
--- At most one operation of the same kind may run against the same target at a time (BR-009).
--- Acceptance is decided here rather than relying on locking on the docker side.
local M = {}

--- target ID -> operation name -> true
---@type table<string, table<string, boolean>>
local running = {}

--- Where changes to the in-flight operations are announced (used to refresh the list's "running" display).
---@type fun()[]
local listeners = {}

--- For tests. Empties the ledger (subscriptions are kept).
function M._reset()
  running = {}
end

--- Called whenever the set of in-flight operations changes.
---@param listener fun()
function M.subscribe(listener)
  table.insert(listeners, listener)
end

local function notify_changed()
  for _, listener in ipairs(listeners) do
    listener()
  end
end

--- Requests the start of an operation. Rejected when the same operation is already in flight.
---@param target_id string
---@param operation string
---@return boolean accepted whether the request was accepted
function M.begin(target_id, operation)
  local per_target = running[target_id]
  if per_target and per_target[operation] then
    return false
  end
  if not per_target then
    per_target = {}
    running[target_id] = per_target
  end
  per_target[operation] = true
  notify_changed()
  return true
end

--- Records the completion of an operation.
---@param target_id string
---@param operation string
function M.finish(target_id, operation)
  local per_target = running[target_id]
  if not per_target then
    return
  end
  per_target[operation] = nil
  if next(per_target) == nil then
    running[target_id] = nil
  end
  notify_changed()
end

---@param target_id string
---@param operation string
---@return boolean
function M.is_running(target_id, operation)
  local per_target = running[target_id]
  return (per_target ~= nil and per_target[operation] == true)
end

--- Whether the target has at least one operation in flight (used for the list's running display).
---@param target_id string
---@return boolean
function M.has_any(target_id)
  return running[target_id] ~= nil
end

return M
