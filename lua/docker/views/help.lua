--- ヘルプビュー。そのビューで有効なキーとアクションを一覧する。
---
--- 一覧の上に `zindex` で重ねる。閉じたときに下層の内容とカーソル位置が残る。
local keymaps = require("docker.views.keymaps")
local tbl = require("docker.ui.table")
local window = require("docker.ui.window")

local M = {}

--- ヘルプは一覧より前面に置く。
local ZINDEX = 200

--- ビュー種別で有効なキーとアクションの行を作る。
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

--- ヘルプを開く。
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
