--- Creation and update of the view state.
---
--- An update always creates a new value (immutable update). The drawing is done with the state as
--- the single source of truth, so if it were rewritten midway the drawing and the cursor would
--- fall out of sync.
local M = {}

---@class docker.ViewState
---@field kind string     the resource kind
---@field items table[]   the resources being displayed
---@field cursor integer  the cursor line (1-based)
---@field filter string   the filtering term (all items when empty)
---@field collapsed table<string, boolean> group keys that are folded

---@param count integer
---@param cursor integer
---@return integer
local function clamp_cursor(count, cursor)
  if count == 0 then
    return 1
  end
  return math.max(1, math.min(cursor, count))
end

---@param state docker.ViewState
---@return table<string, boolean>
local function copy_collapsed(state)
  return vim.deepcopy(state.collapsed or {})
end

---@param kind string
---@return docker.ViewState
function M.new(kind)
  return { kind = kind, items = {}, cursor = 1, filter = "", collapsed = {} }
end

--- Swaps the resources being displayed. The cursor is kept, but clamped if it falls out of range.
---@param state docker.ViewState
---@param items table[]
---@return docker.ViewState
function M.with_items(state, items)
  return {
    kind = state.kind,
    items = vim.deepcopy(items),
    cursor = clamp_cursor(#items, state.cursor),
    filter = state.filter or "",
    collapsed = copy_collapsed(state),
  }
end

--- Changes the cursor line. A value out of range is clamped.
---@param state docker.ViewState
---@param cursor integer
---@return docker.ViewState
function M.with_cursor(state, cursor)
  return {
    kind = state.kind,
    items = vim.deepcopy(state.items),
    cursor = clamp_cursor(#state.items, cursor),
    filter = state.filter or "",
    collapsed = copy_collapsed(state),
  }
end

--- Swaps the filtering term. The cursor goes back to the top (because the row correspondence changes).
---@param state docker.ViewState
---@param filter string
---@return docker.ViewState
function M.with_filter(state, filter)
  return {
    kind = state.kind,
    items = vim.deepcopy(state.items),
    cursor = 1,
    filter = filter or "",
    collapsed = copy_collapsed(state),
  }
end

--- Swaps the folded groups. The keys that are present are folded.
---@param state docker.ViewState
---@param collapsed table<string, boolean>
---@return docker.ViewState
function M.with_collapsed(state, collapsed)
  return {
    kind = state.kind,
    items = vim.deepcopy(state.items),
    cursor = state.cursor,
    filter = state.filter or "",
    collapsed = vim.deepcopy(collapsed or {}),
  }
end

--- Flips the fold state of a group.
---@param state docker.ViewState
---@param key string
---@return docker.ViewState
function M.toggle_collapsed(state, key)
  local collapsed = copy_collapsed(state)
  if collapsed[key] then
    collapsed[key] = nil
  else
    collapsed[key] = true
  end
  return M.with_collapsed(state, collapsed)
end

--- Whether the group is folded.
---@param state docker.ViewState
---@param key string
---@return boolean
function M.is_collapsed(state, key)
  return (state.collapsed or {})[key] == true
end

--- The items after the filtering has been applied.
--- An item is kept if it partially matches any of the values used for display (case-insensitive).
---@param state docker.ViewState
---@param def docker.ResourceDefinition
---@return table[]
function M.visible_items(state, def)
  local filter = state.filter or ""
  if filter == "" then
    return state.items
  end

  local needle = filter:lower()
  local matched = {}
  for _, item in ipairs(state.items) do
    for _, column in ipairs(def.columns) do
      if tostring(column.value(item)):lower():find(needle, 1, true) then
        table.insert(matched, item)
        break
      end
    end
  end
  return matched
end

--- The resource on the cursor line. nil when there are 0 items.
---@param state docker.ViewState
---@return table|nil
function M.selected(state)
  return state.items[state.cursor]
end

return M
