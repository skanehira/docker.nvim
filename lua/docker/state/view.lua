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

---@param count integer
---@param cursor integer
---@return integer
local function clamp_cursor(count, cursor)
  if count == 0 then
    return 1
  end
  return math.max(1, math.min(cursor, count))
end

---@param kind string
---@return docker.ViewState
function M.new(kind)
  return { kind = kind, items = {}, cursor = 1, filter = "" }
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
  }
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
