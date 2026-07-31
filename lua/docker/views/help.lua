--- Help view. Lists the keys and actions that are active in a given view.
---
--- It is stacked above the list with `zindex`, so closing it keeps the content and the
--- cursor position of the layer below.
local keymaps = require("docker.views.keymaps")
local tbl = require("docker.ui.table")
local window = require("docker.ui.window")

local M = {}

--- The help is placed in front of the list.
local ZINDEX = 200

--- Build the rows of keys and actions that are active for the view type.
---@param view_type string
---@return string[]
function M.build(view_type)
  local rows = {}
  for _, row in ipairs(keymaps.describe_view(view_type)) do
    table.insert(rows, { row.key, row.action })
  end

  local widths = tbl.compute_widths({ "", "" }, rows)
  local lines = {}
  for _, row in ipairs(rows) do
    table.insert(lines, tbl.format_row(row, widths))
  end
  return lines
end

--- Open the help.
---@param view_type string
---@return docker.Window
function M.open(view_type)
  local handle = window.open({
    title = ("Help (%s)"):format(view_type),
    zindex = ZINDEX,
  })
  window.set_lines(handle, M.build(view_type))
  return handle
end

return M
