--- The resource store. Holds a list per kind and tells subscribers about changes.
---
--- The store does not know about the views (Observer). The subscriber side projects the drawing
--- from the state.
local M = {}

--- kind -> the array of items (keeps the order they were fetched in)
---@type table<string, table[]>
local items_by_kind = {}

---@type table<integer, fun(kind: string)>
local listeners = {}
local next_listener_id = 1

--- For tests. Returns the store and the subscribers to their initial state.
function M._reset()
  items_by_kind = {}
  listeners = {}
  next_listener_id = 1
end

---@param kind string
local function notify_listeners(kind)
  -- Take a copy before calling so that the traversal does not break if a subscriber unsubscribes
  -- during the notification.
  local current = {}
  for id, listener in pairs(listeners) do
    current[id] = listener
  end
  for _, listener in pairs(current) do
    listener(kind)
  end
end

---@param kind string
---@return table[]
local function bucket(kind)
  local existing = items_by_kind[kind]
  if not existing then
    existing = {}
    items_by_kind[kind] = existing
  end
  return existing
end

---@param list table[]
---@param id string
---@return integer|nil
local function index_of(list, id)
  for index, item in ipairs(list) do
    if item.id == id then
      return index
    end
  end
  return nil
end

--- Replaces the whole content of a kind with the result of a list fetch.
---@param kind string
---@param items table[]
function M.replace_all(kind, items)
  items_by_kind[kind] = vim.deepcopy(items)
  notify_listeners(kind)
end

--- Adds or updates one item. The same ID never appears twice within one kind (INV-1).
---@param kind string
---@param item table
function M.upsert(kind, item)
  local list = bucket(kind)
  local index = index_of(list, item.id)
  if index then
    list[index] = vim.deepcopy(item)
  else
    table.insert(list, vim.deepcopy(item))
  end
  notify_listeners(kind)
end

--- Removes one item. Does nothing and does not notify if it does not exist.
---@param kind string
---@param id string
function M.remove(kind, id)
  local list = bucket(kind)
  local index = index_of(list, id)
  if not index then
    return
  end
  table.remove(list, index)
  notify_listeners(kind)
end

--- Returns the list of a kind. Modifying the returned array does not affect the store.
---@param kind string
---@return table[]
function M.list(kind)
  return vim.deepcopy(items_by_kind[kind] or {})
end

--- Subscribes to state changes.
---@param listener fun(kind: string)
---@return fun() unsubscribe
function M.subscribe(listener)
  local id = next_listener_id
  next_listener_id = next_listener_id + 1
  listeners[id] = listener
  return function()
    listeners[id] = nil
  end
end

return M
