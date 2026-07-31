--- Resolve the keymaps for a view type.
---
--- The view-specific keys are layered on top of the common keys. The same key can be
--- bound to a different action per view type (BR-015).
local config = require("docker.config")

local M = {}

---@param view_type string
---@return table<string, string> key -> action name
function M.resolve(view_type)
  local keymaps = config.get().keymaps
  local resolved = {}

  for action, key in pairs(keymaps.common or {}) do
    resolved[key] = action
  end
  -- When a view-specific binding uses the same key as a common one, the view-specific one wins.
  for action, key in pairs(keymaps[view_type] or {}) do
    resolved[key] = action
  end

  return resolved
end

--- The listing used by the help view. Sorted by key so that the order does not change between runs.
---@param view_type string
---@return { key: string, action: string }[]
function M.describe_view(view_type)
  local resolved = M.resolve(view_type)

  local keys = {}
  for key in pairs(resolved) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local rows = {}
  for _, key in ipairs(keys) do
    table.insert(rows, { key = key, action = resolved[key] })
  end
  return rows
end

return M
